package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
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

const plistContentTmpl = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.irelay</string>
    <key>ProgramArguments</key>
    <array>
        <string>%s</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>%s</string>
    <key>StandardErrorPath</key>
    <string>%s</string>
</dict>
</plist>
`

func setupCodex(input io.Reader, output io.Writer) error {
	if err := ensureConfig(output); err != nil {
		return err
	}
	if err := ensurePlist(); err != nil {
		return err
	}
	fmt.Fprintln(output, "✅ iRelay 服务已配置")

	if err := startService(); err != nil {
		fmt.Fprintf(output, "⚠️  服务启动失败: %v\n", err)
		fmt.Fprintln(output, "   请稍后手动运行: irelay restart")
	} else if err := waitForHealth(); err != nil {
		fmt.Fprintf(output, "⚠️  服务启动中，请稍后检查 irelay status\n")
	} else {
		fmt.Fprintln(output, "✅ iRelay 服务已启动")
	}

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
	if err := os.WriteFile(configPath, []byte(configureCodexTOML(string(raw))), 0o600); err != nil {
		return err
	}
	fmt.Fprintln(output, "✅ Codex 已配置为使用 iRelay")

	home, err := os.UserHomeDir()
	if err != nil {
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

func configDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".config", "irelay"), nil
}

func binaryPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "bin", "irelay")
}

func plistPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "LaunchAgents", "com.user.irelay.plist")
}

func ensureConfig(output io.Writer) error {
	dir, err := configDir()
	if err != nil {
		return err
	}
	path := filepath.Join(dir, "config.json")
	if _, err := os.Stat(path); err == nil {
		return nil
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	cfg := fmt.Sprintf(`{
    "apiKey": "%s",
    "upstream": "https://api.deepseek.com"
}
`, os.Getenv("DEEPSEEK_API_KEY"))
	if err := os.WriteFile(path, []byte(cfg), 0o600); err != nil {
		return err
	}
	fmt.Fprintf(output, "✅ 配置文件已创建: %s\n", path)
	if os.Getenv("DEEPSEEK_API_KEY") == "" {
		fmt.Fprintf(output, "⚠️  请编辑 %s 填入 apiKey\n", path)
	}
	return nil
}

func ensurePlist() error {
	bin := binaryPath()
	dir, err := configDir()
	if err != nil {
		return err
	}
	plist := plistPath()
	if err := os.MkdirAll(filepath.Dir(plist), 0o700); err != nil {
		return err
	}
	content := fmt.Sprintf(plistContentTmpl, bin,
		filepath.Join(dir, "irelay.log"),
		filepath.Join(dir, "irelay_error.log"))
	return os.WriteFile(plist, []byte(content), 0o600)
}

func startService() error {
	plist := plistPath()
	_ = exec.Command("launchctl", "unload", plist).Run()
	return exec.Command("launchctl", "load", "-w", plist).Run()
}

func waitForHealth() error {
	client := &http.Client{Timeout: 1 * time.Second}
	for range 30 {
		resp, err := client.Get("http://localhost:8787/health")
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return nil
			}
		}
		time.Sleep(200 * time.Millisecond)
	}
	return errors.New("health check timeout")
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
		if currentTable == "" && isCodexModelKey(trimmed) {
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
	fmt.Fprintf(w, "iRelay v%s\n", version)
	var actions []string
	if !reportEnv(w, "DEEPSEEK_API_KEY") {
		actions = appendDoctorAction(actions, "Run: irelay setup")
	}
	if !reportEnv(w, "IRELAY_API_KEY") {
		actions = appendDoctorAction(actions, "Run: irelay setup")
	}

	_, configPath, err := codexConfigPath()
	if err != nil {
		return err
	}
	raw, err := os.ReadFile(configPath)
	if err != nil {
		fmt.Fprintf(w, "Codex config: missing (%s)\n", configPath)
		actions = appendDoctorAction(actions, "Run: irelay setup")
	} else {
		content := string(raw)
		providerOK := hasTopLevelAssignment(content, "model_provider", "irelay")
		modelOK := hasTopLevelAssignment(content, "model", "deepseek-v4-pro")
		providerBlockOK := hasTable(content, "model_providers.irelay")
		fmt.Fprintf(w, "Codex config: %s\n", configPath)
		fmt.Fprintf(w, "Codex provider: %s\n", statusLine(providerOK))
		fmt.Fprintf(w, "Codex model: %s\n", statusLine(modelOK))
		fmt.Fprintf(w, "iRelay provider block: %s\n", statusLine(providerBlockOK))
		if !providerBlockOK {
			actions = appendDoctorAction(actions, "Run: irelay setup")
		} else if !providerOK || !modelOK {
			actions = appendDoctorAction(actions, "Run: irelay on")
		}
	}

	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Get("http://localhost:8787/health")
	if err != nil {
		fmt.Fprintf(w, "Server health: unavailable (%v)\n", err)
		actions = appendDoctorAction(actions, "Run: irelay serve")
		printDoctorActions(w, actions)
		return nil
	}
	defer resp.Body.Close()
	fmt.Fprintf(w, "Server health: HTTP %d\n", resp.StatusCode)
	if resp.StatusCode != http.StatusOK {
		actions = appendDoctorAction(actions, "Check: irelay serve logs")
	}
	printDoctorActions(w, actions)
	return nil
}

func reportEnv(w io.Writer, name string) bool {
	_, ok := os.LookupEnv(name)
	fmt.Fprintf(w, "%s: %s\n", name, statusLine(ok))
	return ok
}

func appendDoctorAction(actions []string, action string) []string {
	for _, existing := range actions {
		if existing == action {
			return actions
		}
	}
	return append(actions, action)
}

func printDoctorActions(w io.Writer, actions []string) {
	if len(actions) == 0 {
		return
	}
	fmt.Fprintln(w, "\nNext steps:")
	for _, action := range actions {
		fmt.Fprintf(w, "- %s\n", action)
	}
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
