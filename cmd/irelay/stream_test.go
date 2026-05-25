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

func TestStreamReasoningContentProducesReasoningOutputItem(t *testing.T) {
	cfg := config{thinking: true}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		writeChatCompletionChunk(t, w, map[string]any{
			"content":          "",
			"reasoning_content": "让我思考一下。\n用户想要",
		})
		writeChatCompletionChunk(t, w, map[string]any{
			"content":          "",
			"reasoning_content": "运行一个命令。",
		})
		writeChatCompletionChunk(t, w, map[string]any{
			"content":          "好的，我来运行。",
			"reasoning_content": "",
		})
		fmt.Fprint(w, "data: [DONE]\n\n")
	}))
	defer upstream.Close()

	resp := streamResponsesWithCfg(t, upstream.URL, cfg)
	events := parseSSEEvents(t, resp.Body.String())

	added := eventsOfType(events, "response.output_item.added")
	if len(added) != 2 {
		t.Fatalf("output_item.added count = %d, want 2 (reasoning + message)", len(added))
	}
	if added[0]["output_index"] != float64(0) {
		t.Fatalf("first added output_index = %v, want 0", added[0]["output_index"])
	}
	item0 := added[0]["item"].(map[string]any)
	if item0["type"] != "reasoning" {
		t.Fatalf("first item type = %v, want reasoning", item0["type"])
	}
	item1 := added[1]["item"].(map[string]any)
	if item1["type"] != "message" {
		t.Fatalf("second item type = %v, want message", item1["type"])
	}

	rsDeltas := eventsOfType(events, "response.reasoning_text.delta")
	if len(rsDeltas) != 2 {
		t.Fatalf("reasoning_text.delta count = %d, want 2", len(rsDeltas))
	}
	if rsDeltas[0]["delta"] != "让我思考一下。\n用户想要" {
		t.Fatalf("first reasoning delta = %v", rsDeltas[0]["delta"])
	}
	if rsDeltas[1]["delta"] != "运行一个命令。" {
		t.Fatalf("second reasoning delta = %v", rsDeltas[1]["delta"])
	}

	rsDone := firstEventOfType(t, events, "response.reasoning_text.done")
	if rsDone["text"] != "让我思考一下。\n用户想要运行一个命令。" {
		t.Fatalf("reasoning_text.done text = %v", rsDone["text"])
	}

	completed := firstEventOfType(t, events, "response.completed")
	response := completed["response"].(map[string]any)
	output := response["output"].([]any)
	if len(output) != 2 {
		t.Fatalf("completed output length = %d, want 2", len(output))
	}
	if output[0].(map[string]any)["type"] != "reasoning" {
		t.Fatalf("completed output[0].type = %v, want reasoning", output[0])
	}
	if output[1].(map[string]any)["type"] != "message" {
		t.Fatalf("completed output[1].type = %v, want message", output[1])
	}
	if response["output_text"] != "好的，我来运行。" {
		t.Fatalf("output_text = %v, want 好的，我来运行。", response["output_text"])
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
	return streamResponsesWithCfg(t, upstreamURL, config{thinking: false})
}

func streamResponsesWithCfg(t *testing.T, upstreamURL string, cfg config) *httptest.ResponseRecorder {
	t.Helper()
	parsed, err := url.Parse(upstreamURL)
	if err != nil {
		t.Fatalf("parse upstream URL: %v", err)
	}

	cfg.upstream = parsed
	cfg.apiKey = "test-key"
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
