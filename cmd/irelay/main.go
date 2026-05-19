package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

const appVersion = "0.2.0"
const defaultPort = "8787"
const defaultUpstream = "https://api.deepseek.com"
const defaultTraceDir = "/tmp/irelay-trace"

type config struct {
	port     string
	upstream *url.URL
	apiKey   string
	trace    *tracer
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
		fmt.Fprintf(stdout, "iRelay v%s\n", appVersion)
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
	}

	fmt.Fprintf(stderr, "unknown command: %s\n\n", args[0])
	printHelp(stderr)
	return 1
}

func printHelp(w io.Writer) {
	fmt.Fprintf(w, `iRelay v%s

Usage:
  irelay                         Start the local bridge server
  irelay serve                   Start the local bridge server
  irelay setup                   Configure Codex to use iRelay
  irelay on                      Enable iRelay as Codex default
  irelay off                     Disable iRelay without deleting config or keys
  irelay status                  Show whether Codex currently uses iRelay
  irelay doctor                  Check local iRelay/Codex readiness
  irelay version                 Print version

`, appVersion)
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

func loadConfig() (config, error) {
	rawUpstream := strings.TrimRight(defaultUpstream, "/")
	apiKey := strings.TrimSpace(os.Getenv("DEEPSEEK_API_KEY"))
	if apiKey == "" {
		return config{}, errors.New("DEEPSEEK_API_KEY is required")
	}

	upstream, err := url.Parse(rawUpstream)
	if err != nil {
		return config{}, err
	}
	if upstream.Scheme == "" || upstream.Host == "" {
		return config{}, errors.New("DEEPSEEK_BASE_URL must include scheme and host")
	}

	return config{
		port:     defaultPort,
		upstream: upstream,
		apiKey:   apiKey,
		trace:    newTracerFromEnv(),
	}, nil
}
