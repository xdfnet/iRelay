package main

import "net/http"

const defaultModel = "deepseek-v4-pro"
const fallbackModel = "deepseek-v4-flash"

func (cfg config) handleModels(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		jsonError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	models := []any{
		modelInfo(defaultModel, "DeepSeek V4 Pro through local iRelay.", 0, cfg.thinking),
		modelInfo(fallbackModel, "DeepSeek V4 Flash through local iRelay.", 1, cfg.thinking),
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"object": "list",
		"data":   models,
		"models": models,
	})
}

func modelInfo(id string, desc string, priority int, thinking bool) map[string]any {
	reasoningLevel := "none"
	if thinking {
		reasoningLevel = "medium"
	}
	return map[string]any{
		"id":                               id,
		"slug":                             id,
		"name":                             id,
		"display_name":                     id,
		"object":                           "model",
		"created":                          0,
		"owned_by":                         "deepseek",
		"provider":                         "deepseek",
		"description":                      desc,
		"supported_reasoning_levels": []any{
			map[string]any{"effort": "none", "description": ""},
			map[string]any{"effort": "low", "description": ""},
			map[string]any{"effort": "medium", "description": ""},
			map[string]any{"effort": "high", "description": ""},
		},
		"default_reasoning_level":          reasoningLevel,
		"supports_reasoning_summaries":     false,
		"shell_type":                       "shell_command",
		"visibility":                       "list",
		"supported_in_api":                 true,
		"priority":                         priority,
		"base_instructions":                "",
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
