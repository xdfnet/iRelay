package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
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
