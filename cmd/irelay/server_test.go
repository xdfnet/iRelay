package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestTracerWritesJSONWhenEnabled(t *testing.T) {
	dir := t.TempDir()
	tr := &tracer{enabled: true, dir: dir}

	tr.writeJSON("sample", map[string]any{"ok": true})

	path := filepath.Join(dir, "001-sample.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read trace file: %v", err)
	}
	var body map[string]any
	if err := json.Unmarshal(data, &body); err != nil {
		t.Fatalf("trace file is not valid JSON: %v", err)
	}
	if body["ok"] != true {
		t.Fatalf("trace body = %#v", body)
	}
}

func TestTracerDoesNotWriteWhenDisabled(t *testing.T) {
	dir := t.TempDir()
	tr := &tracer{enabled: false, dir: dir}

	tr.writeJSON("sample", map[string]any{"ok": true})

	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("read temp dir: %v", err)
	}
	if len(entries) != 0 {
		t.Fatalf("trace wrote files while disabled: %v", entries)
	}
}
