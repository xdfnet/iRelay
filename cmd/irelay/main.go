package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"sort"
	"strings"
	"syscall"
	"time"
)

const defaultPort = "8787"
const defaultUpstream = "https://api.deepseek.com"
const defaultModel = "deepseek-v4-pro"
const fallbackModel = "deepseek-v4-flash"

func main() {
	cfg, err := loadConfig()
	if err != nil {
		log.Fatal(err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", health)
	mux.HandleFunc("/v1/models", handleModels)
	mux.HandleFunc("/v1/responses", cfg.handleResponses)

	server := &http.Server{
		Addr:              ":" + cfg.port,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}

	errs := make(chan error, 1)
	go func() {
		log.Printf("iRelay listening on http://localhost:%s", cfg.port)
		log.Printf("Serving Codex Responses API through %s/chat/completions", strings.TrimRight(cfg.upstream.String(), "/"))
		errs <- server.ListenAndServe()
	}()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	select {
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdownCtx); err != nil {
			log.Fatal(err)
		}
	case err := <-errs:
		if !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	}
}

type config struct {
	port     string
	upstream *url.URL
	apiKey   string
}

func loadConfig() (config, error) {
	rawUpstream := strings.TrimRight(defaultUpstream, "/")
	apiKey := strings.TrimSpace(os.Getenv("DEEPSEEK_API_KEY"))
	if apiKey == "" {
		return config{}, errors.New("DEEPSEEK_API_KEY is required")
	}

	upstream, err := url.Parse(rawUpstream)
	if err != nil {
		return config{}, err
	}
	if upstream.Scheme == "" || upstream.Host == "" {
		return config{}, errors.New("DEEPSEEK_BASE_URL must include scheme and host")
	}

	return config{
		port:     defaultPort,
		upstream: upstream,
		apiKey:   apiKey,
	}, nil
}

func health(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(map[string]bool{"ok": true})
}

func handleModels(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		jsonError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	models := []any{
		modelInfo(defaultModel, "DeepSeek V4 Pro through local iRelay.", 0),
		modelInfo(fallbackModel, "DeepSeek V4 Flash through local iRelay.", 1),
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"object": "list",
		"data":   models,
		"models": models,
	})
}

func modelInfo(id string, description string, priority int) map[string]any {
	return map[string]any{
		"id":                               id,
		"slug":                             id,
		"name":                             id,
		"display_name":                     id,
		"object":                           "model",
		"created":                          0,
		"owned_by":                         "deepseek",
		"provider":                         "deepseek",
		"description":                      description,
		"default_reasoning_level":          "none",
		"supported_reasoning_levels":       []any{},
		"shell_type":                       "shell_command",
		"visibility":                       "list",
		"supported_in_api":                 true,
		"priority":                         priority,
		"base_instructions":                "",
		"supports_reasoning_summaries":     false,
		"default_reasoning_summary":        "none",
		"support_verbosity":                false,
		"default_verbosity":                "low",
		"apply_patch_tool_type":            "freeform",
		"supports_parallel_tool_calls":     true,
		"supports_image_detail_original":   false,
		"context_window":                   1000000,
		"max_context_window":               1000000,
		"effective_context_window_percent": 95,
		"experimental_supported_tools":     []any{},
		"input_modalities":                 []string{"text"},
		"supports_search_tool":             false,
		"truncation_policy": map[string]any{
			"mode":  "tokens",
			"limit": 1000000,
		},
		"model_messages": map[string]any{
			"instructions_template": "{{ personality }}",
			"instructions_variables": map[string]string{
				"personality_default":   "",
				"personality_pragmatic": "",
				"personality_friendly":  "",
			},
		},
	}
}

type responsesRequest struct {
	Model           string         `json:"model"`
	Instructions    any            `json:"instructions"`
	Input           any            `json:"input"`
	Stream          bool           `json:"stream"`
	Tools           []responseTool `json:"tools"`
	Temperature     *float64       `json:"temperature"`
	TopP            *float64       `json:"top_p"`
	MaxOutputTokens *int           `json:"max_output_tokens"`
}

type responseTool struct {
	Type        string `json:"type"`
	Name        string `json:"name"`
	Description string `json:"description"`
	Parameters  any    `json:"parameters"`
}

type chatMessage struct {
	Role       string     `json:"role"`
	Content    string     `json:"content"`
	ToolCallID string     `json:"tool_call_id,omitempty"`
	ToolCalls  []toolCall `json:"tool_calls,omitempty"`
}

type toolCall struct {
	ID       string       `json:"id"`
	Type     string       `json:"type"`
	Function functionCall `json:"function"`
}

type functionCall struct {
	Name      string `json:"name"`
	Arguments string `json:"arguments"`
}

func (cfg config) handleResponses(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		jsonError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	var body responsesRequest
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		jsonError(w, http.StatusBadRequest, "request body must be valid JSON")
		return
	}

	reqBytes, _ := json.Marshal(body)
	log.Printf("[CODEX→IRELAY] %s", string(reqBytes))

	payload, err := responsesToChatPayload(body)
	if err != nil {
		jsonError(w, http.StatusBadRequest, err.Error())
		return
	}

	if body.Stream {
		payload["stream"] = true
		cfg.streamChatAsResponses(w, r, payload, body.modelOrDefault())
		return
	}

	payload["stream"] = false
	payloadBytes, _ := json.Marshal(payload)
	log.Printf("[IRELAY→DEEPSEEK] %s", string(payloadBytes))

	upstream, err := cfg.deepseekChat(r.Context(), payload)
	if err != nil {
		jsonError(w, http.StatusBadGateway, err.Error())
		return
	}
	defer upstream.Body.Close()

	if upstream.StatusCode < 200 || upstream.StatusCode >= 300 {
		relayUpstreamError(w, upstream)
		return
	}

	var chat map[string]any
	if err := json.NewDecoder(upstream.Body).Decode(&chat); err != nil {
		jsonError(w, http.StatusBadGateway, "upstream returned invalid JSON")
		return
	}

	chatBytes, _ := json.Marshal(chat)
	log.Printf("[DEEPSEEK→IRELAY] %s", string(chatBytes))

	resp := chatCompletionToResponse(chat, body.modelOrDefault())
	respBytes, _ := json.Marshal(resp)
	log.Printf("[IRELAY→CODEX] %s", string(respBytes))

	writeJSON(w, http.StatusOK, resp)
}

func responsesToChatPayload(body responsesRequest) (map[string]any, error) {
	messages, err := responsesInputToMessages(body)
	if err != nil {
		return nil, err
	}

	payload := map[string]any{
		"model":    body.modelOrDefault(),
		"messages": messages,
		"thinking": map[string]string{"type": "disabled"},
	}
	if body.Temperature != nil {
		payload["temperature"] = *body.Temperature
	}
	if body.TopP != nil {
		payload["top_p"] = *body.TopP
	}
	if body.MaxOutputTokens != nil {
		payload["max_tokens"] = *body.MaxOutputTokens
	}
	if tools := responsesToolsToChatTools(body.Tools); len(tools) > 0 {
		payload["tools"] = tools
	}

	return payload, nil
}

func (body responsesRequest) modelOrDefault() string {
	if body.Model == defaultModel || body.Model == fallbackModel {
		return body.Model
	}
	if body.Model != "" {
		log.Printf("unknown model %q, fallback to %s", body.Model, fallbackModel)
	}
	return fallbackModel
}

func responsesInputToMessages(body responsesRequest) ([]chatMessage, error) {
	var messages []chatMessage
	if text := anyToString(body.Instructions); text != "" {
		messages = append(messages, chatMessage{Role: "system", Content: text})
	}

	switch input := body.Input.(type) {
	case string:
		messages = append(messages, chatMessage{Role: "user", Content: input})
	case []any:
		for _, raw := range input {
			item, ok := raw.(map[string]any)
			if !ok {
				continue
			}
			message, ok := responseItemToChatMessage(item)
			if ok {
				messages = append(messages, message)
			}
		}
	case nil:
		return nil, errors.New("`input` is required")
	default:
		return nil, errors.New("`input` must be a string or an array")
	}

	return messages, nil
}

func responseItemToChatMessage(item map[string]any) (chatMessage, bool) {
	itemType := anyToString(item["type"])
	role := normalizeRole(anyToString(item["role"]))

	if itemType == "function_call" {
		callID := firstNonEmpty(anyToString(item["call_id"]), anyToString(item["id"]), "call_"+randomID())
		return chatMessage{
			Role:    "assistant",
			Content: "",
			ToolCalls: []toolCall{{
				ID:   callID,
				Type: "function",
				Function: functionCall{
					Name:      anyToString(item["name"]),
					Arguments: firstNonEmpty(anyToString(item["arguments"]), "{}"),
				},
			}},
		}, true
	}

	if itemType == "function_call_output" {
		return chatMessage{
			Role:       "tool",
			ToolCallID: anyToString(item["call_id"]),
			Content:    contentToText(item["output"]),
		}, true
	}

	if itemType == "input_text" {
		return chatMessage{Role: "user", Content: anyToString(item["text"])}, true
	}

	if _, ok := item["content"]; ok {
		if role == "" {
			role = "user"
		}
		return chatMessage{Role: role, Content: contentToText(item["content"])}, true
	}

	if text := anyToString(item["text"]); text != "" {
		if role == "" {
			role = "user"
		}
		return chatMessage{Role: role, Content: text}, true
	}

	return chatMessage{}, false
}

func normalizeRole(role string) string {
	switch role {
	case "assistant", "system", "tool":
		return role
	case "developer":
		return "system"
	default:
		return "user"
	}
}

func contentToText(content any) string {
	switch value := content.(type) {
	case string:
		return value
	case []any:
		parts := make([]string, 0, len(value))
		for _, raw := range value {
			switch part := raw.(type) {
			case string:
				parts = append(parts, part)
			case map[string]any:
				partType := anyToString(part["type"])
				if partType == "input_text" || partType == "output_text" || partType == "text" {
					if text := anyToString(part["text"]); text != "" {
						parts = append(parts, text)
					}
				}
			}
		}
		return strings.Join(parts, "\n")
	default:
		if content == nil {
			return ""
		}
		data, _ := json.Marshal(content)
		log.Printf("contentToText: unknown type %T, rendered as %s", content, string(data))
		return string(data)
	}
}

func responsesToolsToChatTools(tools []responseTool) []map[string]any {
	converted := make([]map[string]any, 0, len(tools))
	for _, tool := range tools {
		if tool.Type != "function" {
			continue
		}
		parameters := tool.Parameters
		if parameters == nil {
			parameters = map[string]any{"type": "object", "properties": map[string]any{}}
		}
		converted = append(converted, map[string]any{
			"type": "function",
			"function": map[string]any{
				"name":        tool.Name,
				"description": tool.Description,
				"parameters":  parameters,
			},
		})
	}
	return converted
}

func newTransport() *http.Transport {
	return &http.Transport{
		Proxy: http.ProxyFromEnvironment,
		DialContext: (&net.Dialer{
			Timeout:   10 * time.Second,
			KeepAlive: 30 * time.Second,
		}).DialContext,
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          100,
		MaxIdleConnsPerHost:   20,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
	}
}

func (cfg config) deepseekChat(ctx context.Context, payload map[string]any) (*http.Response, error) {
	data, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}

	target := *cfg.upstream
	target.Path = singleJoiningSlash(target.Path, "/chat/completions")

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, target.String(), bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	if cfg.apiKey != "" {
		req.Header.Set("Authorization", "Bearer "+cfg.apiKey)
	}

	client := &http.Client{Transport: newTransport()}
	return client.Do(req)
}

func chatCompletionToResponse(chat map[string]any, model string) map[string]any {
	message := firstChoiceMessage(chat)
	text := anyToString(message["content"])
	output := []any{}

	if text != "" {
		output = append(output, map[string]any{
			"id":     "msg_" + randomID(),
			"type":   "message",
			"status": "completed",
			"role":   "assistant",
			"content": []any{map[string]any{
				"type":        "output_text",
				"text":        text,
				"annotations": []any{},
			}},
		})
	}

	if calls, ok := message["tool_calls"].([]any); ok {
		for _, raw := range calls {
			call, ok := raw.(map[string]any)
			if !ok {
				continue
			}
			fn, _ := call["function"].(map[string]any)
			callID := firstNonEmpty(anyToString(call["id"]), "call_"+randomID())
			output = append(output, map[string]any{
				"id":        callID,
				"type":      "function_call",
				"status":    "completed",
				"call_id":   callID,
				"name":      anyToString(fn["name"]),
				"arguments": firstNonEmpty(anyToString(fn["arguments"]), "{}"),
			})
		}
	}

	response := map[string]any{
		"id":          "resp_" + randomID(),
		"object":      "response",
		"created_at":  time.Now().Unix(),
		"status":      "completed",
		"model":       firstNonEmpty(anyToString(chat["model"]), model),
		"output":      output,
		"output_text": text,
	}

	if usage, ok := chat["usage"].(map[string]any); ok {
		response["usage"] = map[string]any{
			"input_tokens":  usage["prompt_tokens"],
			"output_tokens": usage["completion_tokens"],
			"total_tokens":  usage["total_tokens"],
		}
	}

	return response
}

func (cfg config) streamChatAsResponses(w http.ResponseWriter, r *http.Request, payload map[string]any, model string) {
	payloadBytes, _ := json.Marshal(payload)
	log.Printf("[IRELAY→DEEPSEEK:STREAM] %s", string(payloadBytes))

	upstream, err := cfg.deepseekChat(r.Context(), payload)
	if err != nil {
		jsonError(w, http.StatusBadGateway, err.Error())
		return
	}
	defer upstream.Body.Close()

	if upstream.StatusCode < 200 || upstream.StatusCode >= 300 {
		relayUpstreamError(w, upstream)
		return
	}

	w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache, no-transform")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)

	responseID := "resp_" + randomID()
	writeSSE(w, "response.created", map[string]any{
		"type": "response.created",
		"response": map[string]any{
			"id":         responseID,
			"object":     "response",
			"created_at": time.Now().Unix(),
			"status":     "in_progress",
			"model":      model,
			"output":     []any{},
		},
	})

	reader := bufio.NewReader(upstream.Body)
	messageID := ""
	messageOutputIndex := -1
	textStarted := false
	accumulated := ""
	toolCalls := map[int]*streamToolCall{}
	nextOutputIndex := 0

	done := make(chan struct{})
	go func() {
		select {
		case <-r.Context().Done():
			upstream.Body.Close()
		case <-done:
		}
	}()

	for {
		line, err := reader.ReadString('\n')
		if line != "" {
			trimmed := strings.TrimSpace(line)
			if strings.HasPrefix(trimmed, "data:") {
				data := strings.TrimSpace(strings.TrimPrefix(trimmed, "data:"))
				if data != "" && data != "[DONE]" {
					var event map[string]any
					if err := json.Unmarshal([]byte(data), &event); err == nil {
						log.Printf("[DEEPSEEK→IRELAY:STREAM] %s", data)
						delta := firstChoiceDelta(event)
						if text := anyToString(delta["content"]); text != "" {
							if !textStarted {
								textStarted = true
								messageID = "msg_" + randomID()
								messageOutputIndex = nextOutputIndex
								nextOutputIndex++
								writeSSE(w, "response.output_item.added", map[string]any{
									"type":         "response.output_item.added",
									"output_index": messageOutputIndex,
									"item": map[string]any{
										"id":      messageID,
										"type":    "message",
										"status":  "in_progress",
										"role":    "assistant",
										"content": []any{},
									},
								})
								writeSSE(w, "response.content_part.added", map[string]any{
									"type":          "response.content_part.added",
									"item_id":       messageID,
									"output_index":  messageOutputIndex,
									"content_index": 0,
									"part": map[string]any{
										"type":        "output_text",
										"text":        "",
										"annotations": []any{},
									},
								})
							}

							accumulated += text
							writeSSE(w, "response.output_text.delta", map[string]any{
								"type":          "response.output_text.delta",
								"item_id":       messageID,
								"output_index":  messageOutputIndex,
								"content_index": 0,
								"delta":         text,
							})
						}

						for _, call := range streamToolDeltas(delta) {
							if _, ok := toolCalls[call.Index]; !ok {
								itemID := firstNonEmpty(call.ID, "call_"+randomID())
								toolCalls[call.Index] = &streamToolCall{
									ID:          itemID,
									CallID:      itemID,
									OutputIndex: nextOutputIndex,
									Name:        call.Name,
								}
								nextOutputIndex++
								writeSSE(w, "response.output_item.added", map[string]any{
									"type":         "response.output_item.added",
									"output_index": toolCalls[call.Index].OutputIndex,
									"item": map[string]any{
										"id":        itemID,
										"type":      "function_call",
										"status":    "in_progress",
										"call_id":   itemID,
										"name":      call.Name,
										"arguments": "",
									},
								})
							}

							current := toolCalls[call.Index]
							if call.ID != "" {
								current.CallID = call.ID
							}
							if call.Name != "" {
								current.Name = call.Name
							}
							if call.Arguments != "" {
								current.Arguments += call.Arguments
								writeSSE(w, "response.function_call_arguments.delta", map[string]any{
									"type":         "response.function_call_arguments.delta",
									"item_id":      current.ID,
									"output_index": current.OutputIndex,
									"delta":        call.Arguments,
								})
							}
						}
					}
				}
			}
		}
		if err != nil {
			if !errors.Is(err, io.EOF) {
				log.Printf("stream read error: %v", err)
			}
			break
		}
	}
	close(done)

	outputItems := map[int]any{}

	if textStarted {
		messageItem := map[string]any{
			"id":     messageID,
			"type":   "message",
			"status": "completed",
			"role":   "assistant",
			"content": []any{map[string]any{
				"type":        "output_text",
				"text":        accumulated,
				"annotations": []any{},
			}},
		}
		writeSSE(w, "response.output_text.done", map[string]any{
			"type":          "response.output_text.done",
			"item_id":       messageID,
			"output_index":  messageOutputIndex,
			"content_index": 0,
			"text":          accumulated,
		})
		writeSSE(w, "response.content_part.done", map[string]any{
			"type":          "response.content_part.done",
			"item_id":       messageID,
			"output_index":  messageOutputIndex,
			"content_index": 0,
			"part":          messageItem["content"].([]any)[0],
		})
		writeSSE(w, "response.output_item.done", map[string]any{
			"type":         "response.output_item.done",
			"output_index": messageOutputIndex,
			"item":         messageItem,
		})
		outputItems[messageOutputIndex] = messageItem
	}

	for _, call := range sortedStreamToolCalls(toolCalls) {
		writeSSE(w, "response.function_call_arguments.done", map[string]any{
			"type":         "response.function_call_arguments.done",
			"call_id":      call.CallID,
			"item_id":      call.ID,
			"name":         call.Name,
			"output_index": call.OutputIndex,
			"arguments":    call.Arguments,
		})
		callItem := map[string]any{
			"id":        call.ID,
			"type":      "function_call",
			"status":    "completed",
			"call_id":   call.CallID,
			"name":      call.Name,
			"arguments": call.Arguments,
		}
		writeSSE(w, "response.output_item.done", map[string]any{
			"type":         "response.output_item.done",
			"output_index": call.OutputIndex,
			"item":         callItem,
		})
		outputItems[call.OutputIndex] = callItem
	}
	output := sortedOutputItems(outputItems)

	writeSSE(w, "response.completed", map[string]any{
		"type": "response.completed",
		"response": map[string]any{
			"id":          responseID,
			"object":      "response",
			"created_at":  time.Now().Unix(),
			"status":      "completed",
			"model":       model,
			"output":      output,
			"output_text": accumulated,
		},
	})
}

type streamToolCall struct {
	ID          string
	CallID      string
	OutputIndex int
	Name        string
	Arguments   string
}

type streamToolDelta struct {
	Index     int
	ID        string
	Name      string
	Arguments string
}

func sortedStreamToolCalls(calls map[int]*streamToolCall) []*streamToolCall {
	sorted := make([]*streamToolCall, 0, len(calls))
	for _, call := range calls {
		sorted = append(sorted, call)
	}
	sort.Slice(sorted, func(i, j int) bool {
		return sorted[i].OutputIndex < sorted[j].OutputIndex
	})
	return sorted
}

func sortedOutputItems(items map[int]any) []any {
	indexes := make([]int, 0, len(items))
	for index := range items {
		indexes = append(indexes, index)
	}
	sort.Ints(indexes)

	output := make([]any, 0, len(indexes))
	for _, index := range indexes {
		output = append(output, items[index])
	}
	return output
}

func firstChoiceMessage(chat map[string]any) map[string]any {
	choices, _ := chat["choices"].([]any)
	if len(choices) == 0 {
		return map[string]any{}
	}
	choice, _ := choices[0].(map[string]any)
	message, _ := choice["message"].(map[string]any)
	return message
}

func firstChoiceDelta(event map[string]any) map[string]any {
	choices, _ := event["choices"].([]any)
	if len(choices) == 0 {
		return map[string]any{}
	}
	choice, _ := choices[0].(map[string]any)
	delta, _ := choice["delta"].(map[string]any)
	return delta
}

func streamToolDeltas(delta map[string]any) []streamToolDelta {
	rawCalls, _ := delta["tool_calls"].([]any)
	calls := make([]streamToolDelta, 0, len(rawCalls))
	for _, raw := range rawCalls {
		call, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		fn, _ := call["function"].(map[string]any)
		calls = append(calls, streamToolDelta{
			Index:     anyToInt(call["index"]),
			ID:        anyToString(call["id"]),
			Name:      anyToString(fn["name"]),
			Arguments: anyToString(fn["arguments"]),
		})
	}
	return calls
}

func writeSSE(w http.ResponseWriter, eventName string, data any) {
	encoded, _ := json.Marshal(data)
	fmt.Fprintf(w, "event: %s\n", eventName)
	fmt.Fprintf(w, "data: %s\n\n", encoded)
	if flusher, ok := w.(http.Flusher); ok {
		flusher.Flush()
	}
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func jsonError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]any{
		"error": map[string]any{
			"message": message,
			"type":    "server_error",
		},
	})
}

func relayUpstreamError(w http.ResponseWriter, upstream *http.Response) {
	if contentType := upstream.Header.Get("Content-Type"); contentType != "" {
		w.Header().Set("Content-Type", contentType)
	}
	w.WriteHeader(upstream.StatusCode)
	_, _ = io.Copy(w, upstream.Body)
}

func anyToString(value any) string {
	switch v := value.(type) {
	case string:
		return v
	case fmt.Stringer:
		return v.String()
	default:
		return ""
	}
}

func anyToInt(value any) int {
	switch v := value.(type) {
	case int:
		return v
	case float64:
		return int(v)
	default:
		return 0
	}
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

func randomID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return fmt.Sprintf("%d", time.Now().UnixNano())
	}
	return hex.EncodeToString(b[:])
}

func singleJoiningSlash(a, b string) string {
	aSlash := strings.HasSuffix(a, "/")
	bSlash := strings.HasPrefix(b, "/")
	switch {
	case aSlash && bSlash:
		return a + b[1:]
	case !aSlash && !bSlash:
		return a + "/" + b
	default:
		return a + b
	}
}
