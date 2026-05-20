package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestConfigureCodexTOMLAddsTopLevelProviderAndBlock(t *testing.T) {
	got := configureCodexTOML(`[mcp_servers.openaiDeveloperDocs]
url = "https://developers.openai.com/mcp"
`)

	if !strings.HasPrefix(got, "model_provider = \"irelay\"\nmodel = \"deepseek-v4-pro\"\n") {
		t.Fatalf("config starts with %q, want top-level iRelay provider", got)
	}
	if !strings.Contains(got, "[model_providers.irelay]") {
		t.Fatalf("config missing iRelay provider block:\n%s", got)
	}
}

func TestConfigureCodexTOMLRemovesTopLevelModelKeys(t *testing.T) {
	got := configureCodexTOML(`model_provider = "openai"
model = "gpt-5.4"

[mcp_servers.openaiDeveloperDocs]
url = "https://developers.openai.com/mcp"
`)

	if strings.Count(got, `model_provider = "irelay"`) != 1 {
		t.Fatalf("top-level provider was not replaced exactly once:\n%s", got)
	}
	if strings.Contains(got, `model_provider = "openai"`) || strings.Contains(got, `model = "gpt-5.4"`) {
		t.Fatalf("old top-level model keys were not removed:\n%s", got)
	}
}

func TestConfigureCodexTOMLPreservesNestedModelKeys(t *testing.T) {
	got := configureCodexTOML(`[mcp_servers.openaiDeveloperDocs]
url = "https://developers.openai.com/mcp"
model_provider = "irelay"
model = "deepseek-v4-pro"
`)

	mcpStart := strings.Index(got, "[mcp_servers.openaiDeveloperDocs]")
	mcpBlock := got[mcpStart:]
	if nextTable := strings.Index(mcpBlock[len("[mcp_servers.openaiDeveloperDocs]"):], "\n["); nextTable >= 0 {
		mcpBlock = mcpBlock[:len("[mcp_servers.openaiDeveloperDocs]")+nextTable]
	}
	if !strings.Contains(mcpBlock, `model_provider = "irelay"`) || !strings.Contains(mcpBlock, `model = "deepseek-v4-pro"`) {
		t.Fatalf("nested model keys were not preserved:\n%s", got)
	}
}

func TestConfigureCodexTOMLPreservesProfileModelKeys(t *testing.T) {
	got := configureCodexTOML(`[profiles.deep-review]
model_provider = "openai"
model = "gpt-5.4"
`)

	if !strings.Contains(got, "[profiles.deep-review]\nmodel_provider = \"openai\"\nmodel = \"gpt-5.4\"") {
		t.Fatalf("profile model keys were not preserved:\n%s", got)
	}
}

func TestRunCLIHelpAndVersion(t *testing.T) {
	var out strings.Builder
	if code := runCLI([]string{"--version"}, &out, &strings.Builder{}); code != 0 {
		t.Fatalf("runCLI version exit = %d, want 0", code)
	}
	if !strings.Contains(out.String(), "iRelay v"+appVersion) {
		t.Fatalf("version output = %q", out.String())
	}

	out.Reset()
	if code := runCLI([]string{"help"}, &out, &strings.Builder{}); code != 0 {
		t.Fatalf("runCLI help exit = %d, want 0", code)
	}
	if !strings.Contains(out.String(), "irelay setup") ||
		!strings.Contains(out.String(), "irelay on") ||
		!strings.Contains(out.String(), "irelay off") ||
		!strings.Contains(out.String(), "irelay status") ||
		!strings.Contains(out.String(), "doctor") {
		t.Fatalf("help output missing commands:\n%s", out.String())
	}
}

func TestSetupCodexPromptsAndWritesDeepSeekKey(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CODEX_CONFIG", filepath.Join(home, ".codex", "config.toml"))

	var out strings.Builder
	if err := setupCodex(strings.NewReader("sk-test'key\n"), &out); err != nil {
		t.Fatalf("setupCodex returned error: %v", err)
	}

	zshrc, err := os.ReadFile(filepath.Join(home, ".zshrc"))
	if err != nil {
		t.Fatalf("read .zshrc: %v", err)
	}
	text := string(zshrc)
	if !strings.Contains(text, "export IRELAY_API_KEY=1") {
		t.Fatalf(".zshrc missing IRELAY_API_KEY:\n%s", text)
	}
	if !strings.Contains(text, `export DEEPSEEK_API_KEY='sk-test'"'"'key'`) {
		t.Fatalf(".zshrc missing quoted DEEPSEEK_API_KEY:\n%s", text)
	}
	if !strings.Contains(out.String(), "DeepSeek API Key") {
		t.Fatalf("prompt output = %q", out.String())
	}
}

func TestShellQuote(t *testing.T) {
	got := shellQuote("sk-test'key")
	want := `'sk-test'"'"'key'`
	if got != want {
		t.Fatalf("shellQuote = %q, want %q", got, want)
	}
}

func TestDisableCodexTOMLPreservesProviderAndProfiles(t *testing.T) {
	got := disableCodexTOML(`model_provider = "irelay"
model = "deepseek-v4-pro"

[profiles.deep-review]
model_provider = "openai"
model = "gpt-5.4"

[model_providers.irelay]
name = "iRelay"
`)

	if strings.Contains(got, "\nmodel_provider = \"irelay\"") || strings.HasPrefix(got, "model_provider = \"irelay\"") {
		t.Fatalf("top-level provider was not removed:\n%s", got)
	}
	if strings.Contains(got, "\nmodel = \"deepseek-v4-pro\"") || strings.HasPrefix(got, "model = \"deepseek-v4-pro\"") {
		t.Fatalf("top-level model was not removed:\n%s", got)
	}
	if !strings.Contains(got, "[profiles.deep-review]\nmodel_provider = \"openai\"\nmodel = \"gpt-5.4\"") {
		t.Fatalf("profile model keys were not preserved:\n%s", got)
	}
	if !strings.Contains(got, "[model_providers.irelay]\nname = \"iRelay\"") {
		t.Fatalf("provider block was not preserved:\n%s", got)
	}
}

func TestSwitchCodexOnOffStatus(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CODEX_CONFIG", filepath.Join(home, ".codex", "config.toml"))

	if err := switchCodex(true); err != nil {
		t.Fatalf("switch on: %v", err)
	}
	raw, err := os.ReadFile(filepath.Join(home, ".codex", "config.toml"))
	if err != nil {
		t.Fatalf("read config: %v", err)
	}
	if !isCodexIrelayEnabled(string(raw)) {
		t.Fatalf("iRelay should be enabled:\n%s", string(raw))
	}

	var out strings.Builder
	if err := printCodexStatus(&out); err != nil {
		t.Fatalf("status on: %v", err)
	}
	if !strings.Contains(out.String(), "iRelay: on") {
		t.Fatalf("status output = %q", out.String())
	}

	if err := switchCodex(false); err != nil {
		t.Fatalf("switch off: %v", err)
	}
	raw, err = os.ReadFile(filepath.Join(home, ".codex", "config.toml"))
	if err != nil {
		t.Fatalf("read config: %v", err)
	}
	if isCodexIrelayEnabled(string(raw)) {
		t.Fatalf("iRelay should be disabled:\n%s", string(raw))
	}
	if !strings.Contains(string(raw), "[model_providers.irelay]") {
		t.Fatalf("off should preserve provider block:\n%s", string(raw))
	}
}

func TestRunDoctorChecksCodexTopLevelModel(t *testing.T) {
	home := t.TempDir()
	configPath := filepath.Join(home, ".codex", "config.toml")
	t.Setenv("HOME", home)
	t.Setenv("CODEX_CONFIG", configPath)
	t.Setenv("DEEPSEEK_API_KEY", "sk-test")
	t.Setenv("IRELAY_API_KEY", "1")

	if err := os.MkdirAll(filepath.Dir(configPath), 0o700); err != nil {
		t.Fatalf("mkdir config dir: %v", err)
	}
	if err := os.WriteFile(configPath, []byte(`[profiles.deep-review]
model_provider = "irelay"
model = "deepseek-v4-pro"

[model_providers.irelay]
name = "iRelay"
`), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}

	var out strings.Builder
	if err := runDoctor(&out); err != nil {
		t.Fatalf("runDoctor returned error: %v", err)
	}
	text := out.String()
	if !strings.Contains(text, "Codex provider: missing") || !strings.Contains(text, "Codex model: missing") {
		t.Fatalf("doctor should only accept top-level Codex model settings:\n%s", text)
	}
	if !strings.Contains(text, "iRelay provider block: ok") {
		t.Fatalf("doctor should still find provider block:\n%s", text)
	}
	if !strings.Contains(text, "Next steps:") || !strings.Contains(text, "- Run: irelay on") {
		t.Fatalf("doctor should suggest enabling iRelay:\n%s", text)
	}
}

func TestRunDoctorSuggestsSetupWhenConfigMissing(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CODEX_CONFIG", filepath.Join(home, ".codex", "config.toml"))
	t.Setenv("DEEPSEEK_API_KEY", "sk-test")
	t.Setenv("IRELAY_API_KEY", "1")

	var out strings.Builder
	if err := runDoctor(&out); err != nil {
		t.Fatalf("runDoctor returned error: %v", err)
	}
	text := out.String()
	if !strings.Contains(text, "Codex config: missing") {
		t.Fatalf("doctor should report missing config:\n%s", text)
	}
	if !strings.Contains(text, "Next steps:") || !strings.Contains(text, "- Run: irelay setup") {
		t.Fatalf("doctor should suggest setup:\n%s", text)
	}
}
