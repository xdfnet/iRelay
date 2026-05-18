package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func TestHandleModelsReturnsBothCodexModels(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	rec := httptest.NewRecorder()

	handleModels(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}

	var body struct {
		Data   []map[string]any `json:"data"`
		Models []map[string]any `json:"models"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("models response is invalid JSON: %v", err)
	}

	if len(body.Data) != 2 {
		t.Fatalf("data length = %d, want 2", len(body.Data))
	}
	if len(body.Models) != 2 {
		t.Fatalf("models length = %d, want 2", len(body.Models))
	}

	got := []string{body.Models[0]["id"].(string), body.Models[1]["id"].(string)}
	want := []string{defaultModel, fallbackModel}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("model id %d = %q, want %q", i, got[i], want[i])
		}
	}
}

func TestResponsesToChatPayloadStringInput(t *testing.T) {
	maxTokens := 256
	temperature := 0.2
	body := responsesRequest{
		Model:           defaultModel,
		Instructions:    "你要简洁。",
		Input:           "只回答 OK",
		MaxOutputTokens: &maxTokens,
		Temperature:     &temperature,
	}

	payload, err := responsesToChatPayload(body)
	if err != nil {
		t.Fatalf("responsesToChatPayload returned error: %v", err)
	}

	if payload["model"] != defaultModel {
		t.Fatalf("model = %v, want %s", payload["model"], defaultModel)
	}
	if payload["max_tokens"] != maxTokens {
		t.Fatalf("max_tokens = %v, want %d", payload["max_tokens"], maxTokens)
	}
	if payload["temperature"] != temperature {
		t.Fatalf("temperature = %v, want %v", payload["temperature"], temperature)
	}

	thinking, ok := payload["thinking"].(map[string]string)
	if !ok {
		t.Fatalf("thinking has type %T, want map[string]string", payload["thinking"])
	}
	if thinking["type"] != "disabled" {
		t.Fatalf("thinking.type = %q, want disabled", thinking["type"])
	}

	messages := payload["messages"].([]chatMessage)
	if len(messages) != 2 {
		t.Fatalf("messages length = %d, want 2", len(messages))
	}
	if messages[0].Role != "system" || messages[0].Content != "你要简洁。" {
		t.Fatalf("system message = %#v", messages[0])
	}
	if messages[1].Role != "user" || messages[1].Content != "只回答 OK" {
		t.Fatalf("user message = %#v", messages[1])
	}
}

func TestResponsesToChatPayloadFunctionRoundTripItems(t *testing.T) {
	body := responsesRequest{
		Model: "unknown-model",
		Input: []any{
			map[string]any{
				"type": "message",
				"role": "user",
				"content": []any{
					map[string]any{"type": "input_text", "text": "运行 pwd"},
				},
			},
			map[string]any{
				"type":      "function_call",
				"call_id":   "call_123",
				"name":      "shell",
				"arguments": `{"cmd":"pwd"}`,
			},
			map[string]any{
				"type":    "function_call_output",
				"call_id": "call_123",
				"output":  "/Users/admin/iCode/iRelay",
			},
		},
		Tools: []responseTool{
			{
				Type:        "function",
				Name:        "shell",
				Description: "Run a shell command",
				Parameters: map[string]any{
					"type": "object",
				},
			},
		},
	}

	payload, err := responsesToChatPayload(body)
	if err != nil {
		t.Fatalf("responsesToChatPayload returned error: %v", err)
	}

	if payload["model"] != fallbackModel {
		t.Fatalf("unknown model fallback = %v, want %s", payload["model"], fallbackModel)
	}

	messages := payload["messages"].([]chatMessage)
	if len(messages) != 3 {
		t.Fatalf("messages length = %d, want 3", len(messages))
	}
	if messages[0].Role != "user" || messages[0].Content != "运行 pwd" {
		t.Fatalf("message[0] = %#v", messages[0])
	}
	if len(messages[1].ToolCalls) != 1 {
		t.Fatalf("message[1].ToolCalls length = %d, want 1", len(messages[1].ToolCalls))
	}
	if messages[1].ToolCalls[0].ID != "call_123" || messages[1].ToolCalls[0].Function.Name != "shell" {
		t.Fatalf("tool call = %#v", messages[1].ToolCalls[0])
	}
	if messages[2].Role != "tool" || messages[2].ToolCallID != "call_123" || messages[2].Content != "/Users/admin/iCode/iRelay" {
		t.Fatalf("tool output = %#v", messages[2])
	}

	tools := payload["tools"].([]map[string]any)
	if len(tools) != 1 {
		t.Fatalf("tools length = %d, want 1", len(tools))
	}
	fn := tools[0]["function"].(map[string]any)
	if fn["name"] != "shell" {
		t.Fatalf("tool function name = %v, want shell", fn["name"])
	}
}

func TestChatCompletionToResponseIncludesTextAndToolCalls(t *testing.T) {
	chat := map[string]any{
		"model": "deepseek-v4-pro",
		"choices": []any{
			map[string]any{
				"message": map[string]any{
					"content": "完成",
					"tool_calls": []any{
						map[string]any{
							"id": "call_abc",
							"function": map[string]any{
								"name":      "shell",
								"arguments": `{"cmd":"pwd"}`,
							},
						},
					},
				},
			},
		},
		"usage": map[string]any{
			"prompt_tokens":     float64(10),
			"completion_tokens": float64(3),
			"total_tokens":      float64(13),
		},
	}

	resp := chatCompletionToResponse(chat, defaultModel)

	if resp["object"] != "response" || resp["status"] != "completed" {
		t.Fatalf("response metadata = %#v", resp)
	}
	if resp["output_text"] != "完成" {
		t.Fatalf("output_text = %v, want 完成", resp["output_text"])
	}

	output := resp["output"].([]any)
	if len(output) != 2 {
		t.Fatalf("output length = %d, want 2", len(output))
	}

	call := output[1].(map[string]any)
	if call["type"] != "function_call" || call["call_id"] != "call_abc" || call["name"] != "shell" {
		t.Fatalf("function_call output = %#v", call)
	}

	usage := resp["usage"].(map[string]any)
	if usage["total_tokens"] != float64(13) {
		t.Fatalf("usage.total_tokens = %v, want 13", usage["total_tokens"])
	}
}

func TestStreamToolCallWithoutTextUsesFirstOutputIndex(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		writeChatCompletionChunk(t, w, map[string]any{
			"tool_calls": []any{
				map[string]any{
					"index": float64(0),
					"id":    "call_tool",
					"type":  "function",
					"function": map[string]any{
						"name":      "shell",
						"arguments": `{"cmd":"`,
					},
				},
			},
		})
		writeChatCompletionChunk(t, w, map[string]any{
			"tool_calls": []any{
				map[string]any{
					"index": float64(0),
					"function": map[string]any{
						"arguments": `pwd"}`,
					},
				},
			},
		})
		fmt.Fprint(w, "data: [DONE]\n\n")
	}))
	defer upstream.Close()

	resp := streamResponsesFromUpstream(t, upstream.URL)
	events := parseSSEEvents(t, resp.Body.String())

	added := firstEventOfType(t, events, "response.output_item.added")
	if added["output_index"] != float64(0) {
		t.Fatalf("added output_index = %v, want 0", added["output_index"])
	}

	done := firstEventOfType(t, events, "response.function_call_arguments.done")
	if done["output_index"] != float64(0) {
		t.Fatalf("done output_index = %v, want 0", done["output_index"])
	}
	if done["call_id"] != "call_tool" || done["name"] != "shell" || done["arguments"] != `{"cmd":"pwd"}` {
		t.Fatalf("function_call_arguments.done = %#v", done)
	}

	completed := firstEventOfType(t, events, "response.completed")
	response := completed["response"].(map[string]any)
	output := response["output"].([]any)
	if len(output) != 1 {
		t.Fatalf("completed output length = %d, want 1", len(output))
	}
	item := output[0].(map[string]any)
	if item["type"] != "function_call" || item["call_id"] != "call_tool" {
		t.Fatalf("completed output[0] = %#v", item)
	}
}

func TestStreamMultipleToolCallsCompleteInOutputIndexOrder(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		writeChatCompletionChunk(t, w, map[string]any{
			"tool_calls": []any{
				map[string]any{
					"index": float64(1),
					"id":    "call_second_seen_first",
					"type":  "function",
					"function": map[string]any{
						"name":      "second",
						"arguments": `{"value":2}`,
					},
				},
				map[string]any{
					"index": float64(0),
					"id":    "call_first_seen_second",
					"type":  "function",
					"function": map[string]any{
						"name":      "first",
						"arguments": `{"value":1}`,
					},
				},
			},
		})
		fmt.Fprint(w, "data: [DONE]\n\n")
	}))
	defer upstream.Close()

	resp := streamResponsesFromUpstream(t, upstream.URL)
	events := parseSSEEvents(t, resp.Body.String())
	doneEvents := eventsOfType(events, "response.output_item.done")
	if len(doneEvents) != 2 {
		t.Fatalf("output_item.done event count = %d, want 2", len(doneEvents))
	}
	for i, event := range doneEvents {
		if event["output_index"] != float64(i) {
			t.Fatalf("done event %d output_index = %v, want %d", i, event["output_index"], i)
		}
	}

	completed := firstEventOfType(t, events, "response.completed")
	response := completed["response"].(map[string]any)
	output := response["output"].([]any)
	if len(output) != 2 {
		t.Fatalf("completed output length = %d, want 2", len(output))
	}
	first := output[0].(map[string]any)
	second := output[1].(map[string]any)
	if first["call_id"] != "call_second_seen_first" || second["call_id"] != "call_first_seen_second" {
		t.Fatalf("completed output order = %#v", output)
	}
}

func writeChatCompletionChunk(t *testing.T, w http.ResponseWriter, delta map[string]any) {
	t.Helper()
	data, err := json.Marshal(map[string]any{
		"choices": []any{
			map[string]any{
				"delta": delta,
			},
		},
	})
	if err != nil {
		t.Fatalf("marshal chunk: %v", err)
	}
	fmt.Fprintf(w, "data: %s\n\n", data)
}

func streamResponsesFromUpstream(t *testing.T, upstreamURL string) *httptest.ResponseRecorder {
	t.Helper()
	parsed, err := url.Parse(upstreamURL)
	if err != nil {
		t.Fatalf("parse upstream URL: %v", err)
	}

	cfg := config{upstream: parsed, apiKey: "test-key"}
	req := httptest.NewRequest(http.MethodPost, "/v1/responses", nil)
	rec := httptest.NewRecorder()

	cfg.streamChatAsResponses(rec, req, map[string]any{"stream": true}, defaultModel)
	if rec.Code != http.StatusOK {
		t.Fatalf("stream status = %d, body = %s", rec.Code, rec.Body.String())
	}
	return rec
}

func parseSSEEvents(t *testing.T, stream string) []map[string]any {
	t.Helper()
	blocks := strings.Split(strings.TrimSpace(stream), "\n\n")
	events := make([]map[string]any, 0, len(blocks))
	for _, block := range blocks {
		var eventName string
		var dataLine string
		for _, line := range strings.Split(block, "\n") {
			if strings.HasPrefix(line, "event: ") {
				eventName = strings.TrimPrefix(line, "event: ")
			}
			if strings.HasPrefix(line, "data: ") {
				dataLine = strings.TrimPrefix(line, "data: ")
			}
		}
		if dataLine == "" {
			continue
		}
		var event map[string]any
		if err := json.Unmarshal([]byte(dataLine), &event); err != nil {
			t.Fatalf("unmarshal SSE data %q: %v", dataLine, err)
		}
		if eventName != "" {
			event["event"] = eventName
		}
		events = append(events, event)
	}
	return events
}

func firstEventOfType(t *testing.T, events []map[string]any, eventType string) map[string]any {
	t.Helper()
	matches := eventsOfType(events, eventType)
	if len(matches) == 0 {
		t.Fatalf("missing event type %q in %#v", eventType, events)
	}
	return matches[0]
}

func eventsOfType(events []map[string]any, eventType string) []map[string]any {
	matches := []map[string]any{}
	for _, event := range events {
		if event["type"] == eventType {
			matches = append(matches, event)
		}
	}
	return matches
}
