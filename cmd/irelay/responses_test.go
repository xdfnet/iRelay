package main

import "testing"

func msgStr(messages []map[string]any, i int, key string) string {
	s, _ := messages[i][key].(string)
	return s
}
func msgBool(messages []map[string]any, i int, key string) bool {
	b, _ := messages[i][key].(bool)
	return b
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

	payload, err := responsesToChatPayload(body, false)
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

	messages := payload["messages"].([]map[string]any)
	if len(messages) != 2 {
		t.Fatalf("messages length = %d, want 2", len(messages))
	}
	if msgStr(messages, 0, "role") != "system" || msgStr(messages, 0, "content") != "你要简洁。" {
		t.Fatalf("system message = %#v", messages[0])
	}
	if msgStr(messages, 1, "role") != "user" || msgStr(messages, 1, "content") != "只回答 OK" {
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

	payload, err := responsesToChatPayload(body, false)
	if err != nil {
		t.Fatalf("responsesToChatPayload returned error: %v", err)
	}

	if payload["model"] != fallbackModel {
		t.Fatalf("unknown model fallback = %v, want %s", payload["model"], fallbackModel)
	}

	messages := payload["messages"].([]map[string]any)
	if len(messages) != 3 {
		t.Fatalf("messages length = %d, want 3", len(messages))
	}
	if msgStr(messages, 0, "role") != "user" || msgStr(messages, 0, "content") != "运行 pwd" {
		t.Fatalf("message[0] = %#v", messages[0])
	}
	tc, _ := messages[1]["tool_calls"].([]any)
	if len(tc) != 1 {
		t.Fatalf("message[1].tool_calls length = %d, want 1", len(tc))
	}
	tc0 := tc[0].(map[string]any)
	if tc0["id"] != "call_123" || tc0["function"].(map[string]any)["name"] != "shell" {
		t.Fatalf("tool call = %#v", tc0)
	}
	if msgStr(messages, 2, "role") != "tool" || msgStr(messages, 2, "tool_call_id") != "call_123" || msgStr(messages, 2, "content") != "/Users/admin/iCode/iRelay" {
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

	resp := chatCompletionToResponse(chat, defaultModel, false)

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

	msg := output[0].(map[string]any)
	if msg["type"] != "message" {
		t.Fatalf("message output = %#v", msg)
	}

	usage := resp["usage"].(map[string]any)
	if usage["total_tokens"] != float64(13) {
		t.Fatalf("usage.total_tokens = %v, want 13", usage["total_tokens"])
	}
}

func TestResponsesToChatPayloadMergesParallelFunctionCalls(t *testing.T) {
	body := responsesRequest{
		Model: defaultModel,
		Input: []any{
			map[string]any{
				"type": "message",
				"role": "user",
				"content": []any{
					map[string]any{"type": "input_text", "text": "运行 ls 和 pwd"},
				},
			},
			map[string]any{
				"type":      "function_call",
				"call_id":   "call_1",
				"name":      "shell",
				"arguments": `{"cmd":"ls"}`,
			},
			map[string]any{
				"type":      "function_call",
				"call_id":   "call_2",
				"name":      "shell",
				"arguments": `{"cmd":"pwd"}`,
			},
			map[string]any{
				"type":    "function_call_output",
				"call_id": "call_1",
				"output":  "file1 file2",
			},
			map[string]any{
				"type":    "function_call_output",
				"call_id": "call_2",
				"output":  "/home/user",
			},
		},
	}

	payload, err := responsesToChatPayload(body, false)
	if err != nil {
		t.Fatalf("responsesToChatPayload returned error: %v", err)
	}

	messages := payload["messages"].([]map[string]any)
	if len(messages) != 4 {
		t.Fatalf("messages length = %d, want 4", len(messages))
	}

	if msgStr(messages, 0, "role") != "user" || msgStr(messages, 0, "content") != "运行 ls 和 pwd" {
		t.Fatalf("message[0] = %#v", messages[0])
	}

	if msgStr(messages, 1, "role") != "assistant" {
		t.Fatalf("message[1].role = %s, want assistant", msgStr(messages, 1, "role"))
	}
	tc, _ := messages[1]["tool_calls"].([]any)
	if len(tc) != 2 {
		t.Fatalf("message[1].tool_calls length = %d, want 2", len(tc))
	}
	tc0 := tc[0].(map[string]any)
	if tc0["id"] != "call_1" || tc0["function"].(map[string]any)["name"] != "shell" || tc0["function"].(map[string]any)["arguments"] != `{"cmd":"ls"}` {
		t.Fatalf("tool call 0 = %#v", tc0)
	}
	tc1 := tc[1].(map[string]any)
	if tc1["id"] != "call_2" || tc1["function"].(map[string]any)["name"] != "shell" || tc1["function"].(map[string]any)["arguments"] != `{"cmd":"pwd"}` {
		t.Fatalf("tool call 1 = %#v", tc1)
	}

	if msgStr(messages, 2, "role") != "tool" || msgStr(messages, 2, "tool_call_id") != "call_1" || msgStr(messages, 2, "content") != "file1 file2" {
		t.Fatalf("tool output 0 = %#v", messages[2])
	}
}

func TestResponsesToChatPayloadMergeAssistantTextAndFunctionCall(t *testing.T) {
	body := responsesRequest{
		Model: defaultModel,
		Input: []any{
			map[string]any{
				"type": "message",
				"role": "user",
				"content": []any{
					map[string]any{"type": "input_text", "text": "代码审核"},
				},
			},
			map[string]any{
				"type": "message",
				"role": "assistant",
				"content": []any{
					map[string]any{"type": "output_text", "text": "让我检查文件..."},
				},
			},
			map[string]any{
				"type":      "function_call",
				"call_id":   "call_read",
				"name":      "Read",
				"arguments": `{"file":"main.go"}`,
			},
			map[string]any{
				"type":    "function_call_output",
				"call_id": "call_read",
				"output":  "package main...",
			},
		},
	}

	payload, err := responsesToChatPayload(body, false)
	if err != nil {
		t.Fatalf("responsesToChatPayload returned error: %v", err)
	}

	messages := payload["messages"].([]map[string]any)
	if len(messages) != 3 {
		t.Fatalf("messages length = %d, want 3", len(messages))
	}

	if msgStr(messages, 0, "role") != "user" || msgStr(messages, 0, "content") != "代码审核" {
		t.Fatalf("message[0] = %#v", messages[0])
	}

	if msgStr(messages, 1, "role") != "assistant" {
		t.Fatalf("message[1].role = %s, want assistant", msgStr(messages, 1, "role"))
	}
	if msgStr(messages, 1, "content") != "让我检查文件..." {
		t.Fatalf("message[1].content = %q, want 让我检查文件...", msgStr(messages, 1, "content"))
	}
	tc, _ := messages[1]["tool_calls"].([]any)
	if len(tc) != 1 {
		t.Fatalf("message[1].tool_calls length = %d, want 1", len(tc))
	}
	if tc[0].(map[string]any)["function"].(map[string]any)["name"] != "Read" {
		t.Fatalf("tool call name = %s", tc[0].(map[string]any)["function"].(map[string]any)["name"])
	}

	if msgStr(messages, 2, "role") != "tool" || msgStr(messages, 2, "tool_call_id") != "call_read" || msgStr(messages, 2, "content") != "package main..." {
		t.Fatalf("tool output = %#v", messages[2])
	}
}

func TestApplyDeepSeekChatTweaksDisablesThinking(t *testing.T) {
	payload := map[string]any{
		"messages":   []map[string]any{{"role": "user", "content": "hi"}},
		"tools":      []map[string]any{{"type": "function"}},
		"max_tokens": 128,
	}

	applyDeepSeekChatTweaks(payload)

	if payload["messages"] == nil || payload["tools"] == nil || payload["max_tokens"] != 128 {
		t.Fatalf("payload fields were not preserved: %#v", payload)
	}
	thinking, ok := payload["thinking"].(map[string]any)
	if !ok || thinking["type"] != "disabled" {
		t.Fatalf("thinking should be disabled, got %#v", payload["thinking"])
	}
}

func TestChatCompletionToResponseIncludesReasoningWhenThinkingEnabled(t *testing.T) {
	chat := map[string]any{
		"model": "deepseek-v4-pro",
		"choices": []any{
			map[string]any{
				"message": map[string]any{
					"reasoning_content": "先理解问题。",
					"content":           "好的，我来运行。",
				},
			},
		},
	}

	resp := chatCompletionToResponse(chat, defaultModel, true)

	output := resp["output"].([]any)
	if len(output) != 2 {
		t.Fatalf("output length = %d, want 2 (reasoning + message)", len(output))
	}

	rs := output[0].(map[string]any)
	if rs["type"] != "reasoning" {
		t.Fatalf("output[0].type = %v, want reasoning", rs["type"])
	}
	content := rs["content"].([]any)
	if len(content) != 1 {
		t.Fatalf("reasoning content length = %d, want 1", len(content))
	}
	part := content[0].(map[string]any)
	if part["type"] != "reasoning_text" || part["text"] != "先理解问题。" {
		t.Fatalf("reasoning part = %#v", part)
	}

	if resp["output_text"] != "好的，我来运行。" {
		t.Fatalf("output_text = %v, want 好的，我来运行。", resp["output_text"])
	}
}

func TestChatCompletionToResponseNoReasoningWhenThinkingDisabled(t *testing.T) {
	chat := map[string]any{
		"model": "deepseek-v4-pro",
		"choices": []any{
			map[string]any{
				"message": map[string]any{
					"reasoning_content": "should be ignored",
					"content":           "only text",
				},
			},
		},
	}

	resp := chatCompletionToResponse(chat, defaultModel, false)

	output := resp["output"].([]any)
	if len(output) != 1 {
		t.Fatalf("output length = %d, want 1 (only message)", len(output))
	}
	if output[0].(map[string]any)["type"] != "message" {
		t.Fatalf("output[0].type = %v, want message", output[0])
	}
}

func TestResponsesToChatPayloadPreservesInputText(t *testing.T) {
	body := responsesRequest{
		Model: defaultModel,
		Input: []any{
			map[string]any{
				"type": "message",
				"role": "user",
				"content": []any{
					map[string]any{
						"type": "input_text",
						"text": "visible",
					},
				},
			},
		},
	}

	payload, err := responsesToChatPayload(body, false)
	if err != nil {
		t.Fatalf("responsesToChatPayload returned error: %v", err)
	}

	messages := payload["messages"].([]map[string]any)
	if len(messages) != 1 || msgStr(messages, 0, "content") != "visible" {
		t.Fatalf("messages = %#v, want visible text only", messages)
	}
}
