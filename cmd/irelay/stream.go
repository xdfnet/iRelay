package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"sort"
	"strings"
	"time"
)

func (cfg config) streamChatAsResponses(w http.ResponseWriter, r *http.Request, payload map[string]any, model string) {
	started := time.Now()
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
	deepseekEvents := []map[string]any{}

	upstreamModel := model
	var lastUsage map[string]any
	var streamErr error

	rsID := ""
	rsOutputIndex := 0
	rsContent := ""
	rsStarted := false

	outputItems := map[int]any{}

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
						deepseekEvents = append(deepseekEvents, event)
						if m, _ := event["model"].(string); m != "" {
							upstreamModel = m
						}
						if u, _ := event["usage"].(map[string]any); u != nil {
							lastUsage = u
						}
						delta := firstChoiceDelta(event)

						// reasoning_content delta
						if cfg.thinking {
							if reasoningText := anyToString(delta["reasoning_content"]); reasoningText != "" {
								if !rsStarted {
									rsStarted = true
									rsID = "rs_" + randomID()
									rsOutputIndex = nextOutputIndex
									nextOutputIndex++
									writeSSE(w, "response.output_item.added", map[string]any{
										"type":         "response.output_item.added",
										"output_index": rsOutputIndex,
										"item": map[string]any{
											"id":      rsID,
											"type":    "reasoning",
											"status":  "in_progress",
											"content": []any{},
										},
									})
									writeSSE(w, "response.content_part.added", map[string]any{
										"type":          "response.content_part.added",
										"item_id":       rsID,
										"output_index":  rsOutputIndex,
										"content_index": 0,
										"part": map[string]any{
											"type":        "reasoning_text",
											"text":        "",
											"annotations": []any{},
										},
									})
								}
								rsContent += reasoningText
								writeSSE(w, "response.reasoning_text.delta", map[string]any{
									"type":          "response.reasoning_text.delta",
									"item_id":       rsID,
									"output_index":  rsOutputIndex,
									"content_index": 0,
									"delta":         reasoningText,
								})
							}
						}

						// text content delta
						if text := anyToString(delta["content"]); text != "" {
							if !textStarted {
								// finalize reasoning before text starts
								if cfg.thinking && rsStarted {
									rsStarted = false
									writeSSE(w, "response.reasoning_text.done", map[string]any{
										"type":          "response.reasoning_text.done",
										"item_id":       rsID,
										"output_index":  rsOutputIndex,
										"content_index": 0,
										"text":          rsContent,
									})
									writeSSE(w, "response.content_part.done", map[string]any{
										"type":          "response.content_part.done",
										"item_id":       rsID,
										"output_index":  rsOutputIndex,
										"content_index": 0,
										"part": map[string]any{
											"type":        "reasoning_text",
											"text":        rsContent,
											"annotations": []any{},
										},
									})
									writeSSE(w, "response.output_item.done", map[string]any{
										"type":         "response.output_item.done",
										"output_index": rsOutputIndex,
										"item": map[string]any{
											"id":     rsID,
											"type":   "reasoning",
											"status": "completed",
											"content": []any{map[string]any{
												"type":        "reasoning_text",
												"text":        rsContent,
												"annotations": []any{},
											}},
										},
									})
									outputItems[rsOutputIndex] = map[string]any{
										"id":     rsID,
										"type":   "reasoning",
										"status": "completed",
										"content": []any{map[string]any{
											"type":        "reasoning_text",
											"text":        rsContent,
											"annotations": []any{},
										}},
									}
								}
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

						// tool_call deltas
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
				streamErr = err
			}
			break
		}
	}
	close(done)
	cfg.trace.writeJSON("deepseek-stream-response", deepseekEvents)

	if streamErr != nil {
		writeSSE(w, "response.failed", map[string]any{
			"type": "response.failed",
			"response": map[string]any{
				"id":     responseID,
				"status": "failed",
				"error":  map[string]any{"message": streamErr.Error()},
			},
		})
		log.Printf("POST /v1/responses model=%s status=failed duration=%s", upstreamModel, time.Since(started))
		return
	}

//	outputItems := map[int]any{}

	// reasoning output item (only if text never started to finalize it)
	if cfg.thinking && rsStarted {
		rsStarted = false
		writeSSE(w, "response.reasoning_text.done", map[string]any{
			"type":          "response.reasoning_text.done",
			"item_id":       rsID,
			"output_index":  rsOutputIndex,
			"content_index": 0,
			"text":          rsContent,
		})
		writeSSE(w, "response.content_part.done", map[string]any{
			"type":          "response.content_part.done",
			"item_id":       rsID,
			"output_index":  rsOutputIndex,
			"content_index": 0,
			"part": map[string]any{
				"type":        "reasoning_text",
				"text":        rsContent,
				"annotations": []any{},
			},
		})
		writeSSE(w, "response.output_item.done", map[string]any{
			"type":         "response.output_item.done",
			"output_index": rsOutputIndex,
			"item": map[string]any{
				"id":     rsID,
				"type":   "reasoning",
				"status": "completed",
				"content": []any{map[string]any{
					"type":        "reasoning_text",
					"text":        rsContent,
					"annotations": []any{},
				}},
			},
		})
		outputItems[rsOutputIndex] = map[string]any{
			"id":     rsID,
			"type":   "reasoning",
			"status": "completed",
			"content": []any{map[string]any{
				"type":        "reasoning_text",
				"text":        rsContent,
				"annotations": []any{},
			}},
		}
	}

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

	completed := map[string]any{
		"type": "response.completed",
		"response": map[string]any{
			"id":          responseID,
			"object":      "response",
			"created_at":  time.Now().Unix(),
			"status":      "completed",
			"model":       upstreamModel,
			"output":      output,
			"output_text": accumulated,
		},
	}
	if lastUsage != nil {
		completed["response"].(map[string]any)["usage"] = map[string]any{
			"input_tokens":  lastUsage["prompt_tokens"],
			"output_tokens": lastUsage["completion_tokens"],
			"total_tokens":  lastUsage["total_tokens"],
		}
	}
	cfg.trace.writeJSON("irelay-stream-response", completed)
	writeSSE(w, "response.completed", completed)
	log.Printf("POST /v1/responses model=%s status=completed duration=%s", upstreamModel, time.Since(started))
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
