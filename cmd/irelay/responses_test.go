package main

import "testing"

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

func TestApplyDeepSeekChatTweaksDisablesThinkingAndPreservesPayload(t *testing.T) {
	payload := map[string]any{
		"messages":   []chatMessage{{Role: "user", Content: "hi"}},
		"tools":      []map[string]any{{"type": "function"}},
		"max_tokens": 128,
	}

	applyDeepSeekChatTweaks(payload)

	if payload["messages"] == nil || payload["tools"] == nil || payload["max_tokens"] != 128 {
		t.Fatalf("payload fields were not preserved: %#v", payload)
	}
	thinking, ok := payload["thinking"].(map[string]string)
	if !ok || thinking["type"] != "disabled" {
		t.Fatalf("thinking = %#v, want disabled", payload["thinking"])
	}
}

func TestResponsesToChatPayloadStripsReasoningContent(t *testing.T) {
	body := responsesRequest{
		Model: defaultModel,
		Input: []any{
			map[string]any{
				"type":              "message",
				"role":              "user",
				"reasoning_content": "hidden top-level",
				"content": []any{
					map[string]any{
						"type":              "input_text",
						"text":              "visible",
						"reasoning_content": "hidden nested",
					},
				},
			},
		},
	}

	payload, err := responsesToChatPayload(body)
	if err != nil {
		t.Fatalf("responsesToChatPayload returned error: %v", err)
	}

	messages := payload["messages"].([]chatMessage)
	if len(messages) != 1 || messages[0].Content != "visible" {
		t.Fatalf("messages = %#v, want visible text only", messages)
	}
}
