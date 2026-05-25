package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

var version = "dev"
const defaultPort = "8787"
const defaultUpstream = "https://api.deepseek.com"
const defaultTraceDir = "/tmp/irelay-trace"

type config struct {
	port       string
	upstream   *url.URL
	apiKey     string
	thinking   bool
	trace      *tracer
	httpClient *http.Client
}

func main() {
	os.Exit(runCLI(os.Args[1:], os.Stdout, os.Stderr))
}

func runCLI(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		return serve(stderr)
	}

	switch args[0] {
	case "serve":
		return serve(stderr)
	case "-v", "--version", "version":
		fmt.Fprintf(stdout, "iRelay v%s\n", version)
		return 0
	case "-h", "--help", "help":
		printHelp(stdout)
		return 0
	case "setup":
		if err := setupCodex(os.Stdin, stdout); err != nil {
			fmt.Fprintf(stderr, "setup failed: %v\n", err)
			return 1
		}
		fmt.Fprintln(stdout, "Codex configured to use iRelay.")
		return 0
	case "on":
		if err := switchCodex(true); err != nil {
			fmt.Fprintf(stderr, "on failed: %v\n", err)
			return 1
		}
		fmt.Fprintln(stdout, "iRelay enabled for Codex.")
		return 0
	case "off":
		if err := switchCodex(false); err != nil {
			fmt.Fprintf(stderr, "off failed: %v\n", err)
			return 1
		}
		fmt.Fprintln(stdout, "iRelay disabled for Codex.")
		return 0
	case "status":
		if err := printCodexStatus(stdout); err != nil {
			fmt.Fprintf(stderr, "status failed: %v\n", err)
			return 1
		}
		return 0
	case "doctor":
		if err := runDoctor(stdout); err != nil {
			fmt.Fprintf(stderr, "doctor failed: %v\n", err)
			return 1
		}
		return 0
	case "restart":
		return restartService(stderr)
	case "update":
		return updateService(stdout, stderr)
	}

	fmt.Fprintf(stderr, "unknown command: %s\n\n", args[0])
	printHelp(stderr)
	return 1
}

func printHelp(w io.Writer) {
	fmt.Fprintf(w, `iRelay v%s

Usage:
  irelay serve                   Start server
  irelay status                  Service status
  irelay restart                 Restart service
  irelay setup                   Configure Codex to use iRelay
  irelay on                      Enable iRelay as Codex default
  irelay off                     Disable iRelay without deleting config or keys
  irelay doctor                  Check local iRelay/Codex readiness
  irelay version                 Print version

`, version)
}

func serve(logOutput io.Writer) int {
	log.SetOutput(logOutput)
	cfg, err := loadConfig()
	if err != nil {
		log.Print(err)
		return 1
	}

	server := &http.Server{
		Addr:              ":" + cfg.port,
		Handler:           newMux(cfg),
		ReadHeaderTimeout: 10 * time.Second,
	}

	errs := make(chan error, 1)
	go func() {
		log.Printf("iRelay listening on http://localhost:%s", cfg.port)
		log.Printf("Serving Codex Responses API through %s/chat/completions", strings.TrimRight(cfg.upstream.String(), "/"))
		errs <- server.ListenAndServe()
	}()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	select {
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdownCtx); err != nil {
			log.Print(err)
			return 1
		}
	case err := <-errs:
		if !errors.Is(err, http.ErrServerClosed) {
			log.Print(err)
			return 1
		}
	}
	return 0
}

func restartService(stderr io.Writer) int {
	if _, err := os.Stat(binaryPath()); os.IsNotExist(err) {
		fmt.Fprintln(stderr, "iRelay 未安装，请先运行: npm install -g @xdfnet/irelay")
		return 1
	}
	if err := ensurePlist(); err != nil {
		fmt.Fprintf(stderr, "plist 写入失败: %v\n", err)
		return 1
	}
	plist := plistPath()
	if err := exec.Command("launchctl", "unload", plist).Run(); err != nil {
		fmt.Fprintf(stderr, "failed to unload service: %v\n", err)
	}
	if err := exec.Command("launchctl", "load", "-w", plist).Run(); err != nil {
		fmt.Fprintf(stderr, "failed to load service: %v\n", err)
		return 1
	}
	if err := waitForHealth(); err != nil {
		fmt.Fprintln(stderr, "⚠️  服务已重启但健康检查未通过，请检查日志")
		fmt.Fprintf(stderr, "   less %s\n", filepath.Join(mustConfigDir(), "irelay_error.log"))
		return 1
	}
	fmt.Fprintln(stderr, "✅ iRelay 已重启")
	return 0
}

func mustConfigDir() string {
	dir, _ := configDir()
	return dir
}

func updateService(stdout, stderr io.Writer) int {
	fmt.Fprintln(stdout, "正在检查更新...")
	cmd := exec.Command("npm", "install", "-g", "@xdfnet/irelay")
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	if err := cmd.Run(); err != nil {
		fmt.Fprintf(stderr, "npm install 失败: %v\n", err)
		return 1
	}
	fmt.Fprintln(stdout, "✅ 二进制已更新")
	return restartService(stderr)
}

func loadConfig() (config, error) {
	fileCfg, err := loadFileConfig()
	if err != nil {
		return config{}, fmt.Errorf("读取配置失败: %w，编辑 ~/.config/irelay/config.json", err)
	}
	if fileCfg.APIKey == "" {
		return config{}, errors.New("apiKey 未设置，编辑 ~/.config/irelay/config.json")
	}

	rawUpstream := strings.TrimRight(fileCfg.Upstream, "/")
	if rawUpstream == "" {
		rawUpstream = defaultUpstream
	}

	upstream, err := url.Parse(rawUpstream)
	if err != nil {
		return config{}, err
	}
	if upstream.Scheme == "" || upstream.Host == "" {
		return config{}, errors.New("upstream URL must include scheme and host")
	}

	thinking := false
	if fileCfg.Thinking != nil {
		thinking = *fileCfg.Thinking
	}

	return config{
		port:       defaultPort,
		upstream:   upstream,
		apiKey:     fileCfg.APIKey,
		thinking:   thinking,
		trace:      newTracerFromEnv(),
		httpClient: &http.Client{Transport: newTransport()},
	}, nil
}

type fileConfig struct {
	APIKey   string `json:"apiKey"`
	Upstream string `json:"upstream"`
	Thinking *bool  `json:"thinking"`
}

func loadFileConfig() (*fileConfig, error) {
	home, _ := os.UserHomeDir()
	cfgPath := filepath.Join(home, ".config", "irelay", "config.json")
	data, err := os.ReadFile(cfgPath)
	if err != nil {
		return nil, err
	}
	var cfg fileConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, err
	}
	return &cfg, nil
}
