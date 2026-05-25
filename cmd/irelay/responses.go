package main

import (
	"encoding/json"
	"errors"
	"log"
	"strings"
	"time"
)

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

func responsesToChatPayload(body responsesRequest, thinking bool) (map[string]any, error) {
	messages, err := responsesInputToMessages(body)
	if err != nil {
		return nil, err
	}

	payload := map[string]any{
		"model":    body.modelOrDefault(),
		"messages": messages,
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

		if !thinking {
			applyDeepSeekChatTweaks(payload)
		}
		return payload, nil
}

func applyDeepSeekChatTweaks(payload map[string]any) {
	payload["thinking"] = map[string]any{"type": "disabled"}
}

func (body responsesRequest) modelOrDefault() string {
	if body.Model == defaultModel || body.Model == fallbackModel {
		return body.Model
	}
	if body.Model == "" {
		return defaultModel
	}
	log.Printf("unknown model %q, fallback to %s", body.Model, fallbackModel)
	return fallbackModel
}

func instructionsToText(val any) string {
	switch v := val.(type) {
	case string:
		return v
	case []any:
		return contentToText(v)
	default:
		return anyToString(val)
	}
}

func responsesInputToMessages(body responsesRequest) ([]chatMessage, error) {
	var messages []chatMessage
	if text := instructionsToText(body.Instructions); text != "" {
		messages = append(messages, chatMessage{Role: "system", Content: text})
	}

	switch input := body.Input.(type) {
	case string:
		messages = append(messages, chatMessage{Role: "user", Content: input})
	case []any:
		i := 0
		for i < len(input) {
			item, ok := input[i].(map[string]any)
			if !ok {
				i++
				continue
			}
			if anyToString(item["type"]) == "function_call" {
				toolCalls := collectFunctionCalls(input, &i)
				if len(messages) > 0 && messages[len(messages)-1].Role == "assistant" {
					messages[len(messages)-1].ToolCalls = append(messages[len(messages)-1].ToolCalls, toolCalls...)
				} else {
					messages = append(messages, chatMessage{Role: "assistant", Content: "", ToolCalls: toolCalls})
				}
			} else {
				i++
				message, ok := responseItemToChatMessage(item)
				if ok {
					messages = append(messages, message)
				}
			}
		}
	case nil:
		return nil, errors.New("`input` is required")
	default:
		return nil, errors.New("`input` must be a string or an array")
	}

	messages = ensureToolAfterAssistant(messages)
	return messages, nil
}

func collectFunctionCalls(input []any, i *int) []toolCall {
	var toolCalls []toolCall
	for *i < len(input) {
		item, ok := input[*i].(map[string]any)
		if !ok || anyToString(item["type"]) != "function_call" {
			break
		}
		callID := firstNonEmpty(anyToString(item["call_id"]), anyToString(item["id"]), "call_"+randomID())
		toolCalls = append(toolCalls, toolCall{
			ID:   callID,
			Type: "function",
			Function: functionCall{
				Name:      anyToString(item["name"]),
				Arguments: firstNonEmpty(anyToString(item["arguments"]), "{}"),
			},
		})
		*i++
	}
	return toolCalls
}

func responseItemToChatMessage(item map[string]any) (chatMessage, bool) {
	itemType := anyToString(item["type"])
	role := normalizeRole(anyToString(item["role"]))

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

func chatCompletionToResponse(chat map[string]any, model string, thinking bool) map[string]any {
	message := firstChoiceMessage(chat)
	text := anyToString(message["content"])
	output := []any{}

	if thinking {
		if reasoningText := anyToString(message["reasoning_content"]); reasoningText != "" {
			output = append(output, map[string]any{
				"id":     "rs_" + randomID(),
				"type":   "reasoning",
				"status": "completed",
				"content": []any{map[string]any{
					"type":        "reasoning_text",
					"text":        reasoningText,
					"annotations": []any{},
				}},
			})
		}
	}

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

// ensureToolAfterAssistant re-orders messages so that every assistant message
// with tool_calls is immediately followed by the corresponding tool messages.
// DeepSeek requires this; Codex sometimes injects system messages in between.
func ensureToolAfterAssistant(messages []chatMessage) []chatMessage {
	reordered := make([]chatMessage, 0, len(messages))
	i := 0
	for i < len(messages) {
		msg := messages[i]
		if msg.Role == "assistant" && len(msg.ToolCalls) > 0 {
			expectedSet := make(map[string]bool)
			for _, tc := range msg.ToolCalls {
				expectedSet[tc.ID] = true
			}
			var toolMsgs []chatMessage
			var nonToolMsgs []chatMessage
			j := i + 1
			for j < len(messages) && len(expectedSet) > 0 {
				nxt := messages[j]
				if nxt.Role == "tool" && expectedSet[nxt.ToolCallID] {
					delete(expectedSet, nxt.ToolCallID)
					toolMsgs = append(toolMsgs, nxt)
				} else if nxt.Role == "system" {
					nonToolMsgs = append(nonToolMsgs, nxt)
				} else {
					break
				}
				j++
			}
			reordered = append(reordered, nonToolMsgs...)
			reordered = append(reordered, msg)
			reordered = append(reordered, toolMsgs...)
			i = j
		} else {
			reordered = append(reordered, msg)
			i++
		}
	}
	return reordered
}
