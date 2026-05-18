package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

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
	cfg, err := loadConfig()
	if err != nil {
		log.Fatal(err)
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
			log.Fatal(err)
		}
	case err := <-errs:
		if !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	}
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
