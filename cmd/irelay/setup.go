package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const codexProviderBlock = `[model_providers.irelay]
name = "iRelay"
base_url = "http://localhost:8787/v1"
env_key = "IRELAY_API_KEY"
wire_api = "responses"
`

func setupCodex(input io.Reader, output io.Writer) error {
	home, configPath, err := codexConfigPath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(configPath), 0o700); err != nil {
		return err
	}

	raw, err := os.ReadFile(configPath)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	if err := os.WriteFile(configPath, []byte(configureCodexTOML(string(raw))), 0o600); err != nil {
		return err
	}

	zshrcPath := filepath.Join(home, ".zshrc")
	zshrc, err := os.ReadFile(zshrcPath)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	zshrcText := string(zshrc)
	var additions []string
	if !strings.Contains(zshrcText, "IRELAY_API_KEY") {
		additions = append(additions, "export IRELAY_API_KEY=1")
	}
	if !strings.Contains(zshrcText, "DEEPSEEK_API_KEY") {
		key, err := promptDeepSeekAPIKey(input, output)
		if err != nil {
			return err
		}
		if key != "" {
			additions = append(additions, "export DEEPSEEK_API_KEY="+shellQuote(key))
		}
	}
	if len(additions) > 0 {
		f, err := os.OpenFile(zshrcPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
		if err != nil {
			return err
		}
		defer f.Close()
		if len(zshrc) > 0 && !strings.HasSuffix(zshrcText, "\n") {
			if _, err := io.WriteString(f, "\n"); err != nil {
				return err
			}
		}
		for _, line := range additions {
			if _, err := io.WriteString(f, line+"\n"); err != nil {
				return err
			}
		}
	}

	return nil
}

func switchCodex(enable bool) error {
	_, configPath, err := codexConfigPath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(configPath), 0o700); err != nil {
		return err
	}
	raw, err := os.ReadFile(configPath)
	if err != nil && !os.IsNotExist(err) {
		return err
	}

	var next string
	if enable {
		next = configureCodexTOML(string(raw))
	} else {
		next = disableCodexTOML(string(raw))
	}
	return os.WriteFile(configPath, []byte(next), 0o600)
}

func printCodexStatus(w io.Writer) error {
	_, configPath, err := codexConfigPath()
	if err != nil {
		return err
	}
	raw, err := os.ReadFile(configPath)
	if err != nil {
		fmt.Fprintf(w, "Codex config: missing (%s)\n", configPath)
		fmt.Fprintln(w, "iRelay: off")
		return nil
	}
	content := string(raw)
	fmt.Fprintf(w, "Codex config: %s\n", configPath)
	fmt.Fprintf(w, "iRelay: %s\n", onOff(isCodexIrelayEnabled(content)))
	fmt.Fprintf(w, "iRelay provider block: %s\n", statusLine(hasTable(content, "model_providers.irelay")))
	return nil
}

func codexConfigPath() (string, string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", "", err
	}
	configPath := strings.TrimSpace(os.Getenv("CODEX_CONFIG"))
	if configPath == "" {
		configPath = filepath.Join(home, ".codex", "config.toml")
	}
	return home, configPath, nil
}

func promptDeepSeekAPIKey(input io.Reader, output io.Writer) (string, error) {
	fmt.Fprint(output, "DeepSeek API Key (leave empty to skip): ")
	reader := bufio.NewReader(input)
	key, err := reader.ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return "", err
	}
	return strings.TrimSpace(key), nil
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'"
}

func configureCodexTOML(existing string) string {
	body := removeCodexTopLevelModel(existing)
	body = strings.TrimSpace(body)

	var b strings.Builder
	b.WriteString("model_provider = \"irelay\"\n")
	b.WriteString("model = \"deepseek-v4-pro\"\n")
	if body != "" {
		b.WriteString("\n")
		b.WriteString(body)
		b.WriteString("\n")
	}
	if !hasTable(body, "model_providers.irelay") {
		b.WriteString("\n")
		b.WriteString(codexProviderBlock)
	}
	return b.String()
}

func disableCodexTOML(existing string) string {
	body := strings.TrimSpace(removeCodexTopLevelModel(existing))
	if body == "" {
		return ""
	}
	return body + "\n"
}

func removeCodexTopLevelModel(toml string) string {
	lines := strings.Split(toml, "\n")
	out := make([]string, 0, len(lines))
	currentTable := ""

	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "[") && strings.HasSuffix(trimmed, "]") {
			currentTable = strings.Trim(trimmed, "[]")
		}
		if isCodexModelKey(trimmed) && shouldRemoveCodexModelKey(currentTable) {
			continue
		}
		out = append(out, line)
	}

	return strings.Join(out, "\n")
}

func isCodexIrelayEnabled(toml string) bool {
	return hasTopLevelAssignment(toml, "model_provider", "irelay")
}

func hasTopLevelAssignment(toml, key, value string) bool {
	currentTable := ""
	targetPrefix := key + " "
	targetEqual := key + "="
	for _, line := range strings.Split(toml, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "[") && strings.HasSuffix(trimmed, "]") {
			currentTable = strings.Trim(trimmed, "[]")
			continue
		}
		if currentTable != "" {
			continue
		}
		if strings.HasPrefix(trimmed, targetPrefix) || strings.HasPrefix(trimmed, targetEqual) {
			parts := strings.SplitN(trimmed, "=", 2)
			if len(parts) != 2 {
				return false
			}
			return strings.Trim(strings.TrimSpace(parts[1]), `"`) == value
		}
	}
	return false
}

func isCodexModelKey(line string) bool {
	return strings.HasPrefix(line, "model_provider") || strings.HasPrefix(line, "model ")
}

func shouldRemoveCodexModelKey(table string) bool {
	return table == "" || (!strings.HasPrefix(table, "profiles.") && !strings.HasPrefix(table, "model_providers."))
}

func hasTable(toml, table string) bool {
	target := "[" + table + "]"
	for _, line := range strings.Split(toml, "\n") {
		if strings.TrimSpace(line) == target {
			return true
		}
	}
	return false
}

func runDoctor(w io.Writer) error {
	fmt.Fprintf(w, "iRelay v%s\n", appVersion)
	reportEnv(w, "DEEPSEEK_API_KEY")
	reportEnv(w, "IRELAY_API_KEY")

	_, configPath, err := codexConfigPath()
	if err != nil {
		return err
	}
	raw, err := os.ReadFile(configPath)
	if err != nil {
		fmt.Fprintf(w, "Codex config: missing (%s)\n", configPath)
	} else {
		content := string(raw)
		fmt.Fprintf(w, "Codex config: %s\n", configPath)
		fmt.Fprintf(w, "Codex provider: %s\n", statusLine(strings.Contains(content, `model_provider = "irelay"`)))
		fmt.Fprintf(w, "Codex model: %s\n", statusLine(strings.Contains(content, `model = "deepseek-v4-pro"`)))
		fmt.Fprintf(w, "iRelay provider block: %s\n", statusLine(hasTable(content, "model_providers.irelay")))
	}

	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Get("http://localhost:8787/health")
	if err != nil {
		fmt.Fprintf(w, "Server health: unavailable (%v)\n", err)
		return nil
	}
	defer resp.Body.Close()
	fmt.Fprintf(w, "Server health: HTTP %d\n", resp.StatusCode)
	return nil
}

func reportEnv(w io.Writer, name string) {
	_, ok := os.LookupEnv(name)
	fmt.Fprintf(w, "%s: %s\n", name, statusLine(ok))
}

func statusLine(ok bool) string {
	if ok {
		return "ok"
	}
	return "missing"
}

func onOff(ok bool) string {
	if ok {
		return "on"
	}
	return "off"
}
