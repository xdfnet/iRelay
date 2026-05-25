package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

func newMux(cfg config) *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", health)
	mux.HandleFunc("/v1/models", cfg.handleModels)
	mux.HandleFunc("/v1/responses", cfg.handleResponses)
	return mux
}

func health(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(map[string]bool{"ok": true})
}

func (cfg config) handleResponses(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		jsonError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	start := time.Now()

	var body responsesRequest
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		jsonError(w, http.StatusBadRequest, "request body must be valid JSON")
		return
	}

	cfg.trace.writeJSON("codex-request", body)

	payload, err := responsesToChatPayload(body, cfg.thinking)
	if err != nil {
		jsonError(w, http.StatusBadRequest, err.Error())
		return
	}

	if body.Stream {
		payload["stream"] = true
		cfg.trace.writeJSON("deepseek-request", payload)
		cfg.streamChatAsResponses(w, r, payload, body.modelOrDefault())
		return
	}

	payload["stream"] = false
	cfg.trace.writeJSON("deepseek-request", payload)

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
	cfg.trace.writeJSON("deepseek-response", chat)

	resp := chatCompletionToResponse(chat, body.modelOrDefault(), cfg.thinking)
	cfg.trace.writeJSON("irelay-response", resp)

	writeJSON(w, http.StatusOK, resp)
	log.Printf("POST /v1/responses model=%s status=%d duration=%s", resp["model"], http.StatusOK, time.Since(start))
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

	client := cfg.httpClient
	if client == nil {
		client = &http.Client{Transport: newTransport()}
	}
	return client.Do(req)
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

type tracer struct {
	enabled bool
	dir     string
	mu      sync.Mutex
	next    int
}

func newTracerFromEnv() *tracer {
	enabled := strings.TrimSpace(os.Getenv("IRELAY_TRACE")) == "1"
	dir := strings.TrimSpace(os.Getenv("IRELAY_TRACE_DIR"))
	if dir == "" {
		dir = defaultTraceDir
	}
	return &tracer{enabled: enabled, dir: dir}
}

func (t *tracer) writeJSON(name string, payload any) {
	if t == nil || !t.enabled {
		return
	}

	data, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		log.Printf("trace marshal %s failed: %v", name, err)
		return
	}

	t.mu.Lock()
	t.next++
	path := filepath.Join(t.dir, fmt.Sprintf("%03d-%s.json", t.next, name))
	t.mu.Unlock()

	if err := os.MkdirAll(t.dir, 0o700); err != nil {
		log.Printf("trace mkdir failed: %v", err)
		return
	}
	if err := os.WriteFile(path, append(data, '\n'), 0o600); err != nil {
		log.Printf("trace write %s failed: %v", path, err)
	}
}
