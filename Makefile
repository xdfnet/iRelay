BINARY := irelay
CMD := ./cmd/irelay
INSTALL_DIR ?= $(HOME)/.local/bin
PREFIX ?=

.PHONY: build install uninstall test clean

build:
	go build -o bin/$(BINARY) $(CMD)

install:
	@if [ -n "$(PREFIX)" ]; then \
		install_dir="$(PREFIX)/bin"; \
	else \
		install_dir="$(INSTALL_DIR)"; \
	fi; \
	mkdir -p "$$install_dir"; \
	go build -o "$$install_dir/$(BINARY)" $(CMD); \
	echo "Installed $(BINARY) to $$install_dir/$(BINARY)"

uninstall:
	@if [ -n "$(PREFIX)" ]; then \
		install_dir="$(PREFIX)/bin"; \
	else \
		install_dir="$(INSTALL_DIR)"; \
	fi; \
	rm -f "$$install_dir/$(BINARY)"; \
	echo "Removed $$install_dir/$(BINARY)"

test:
	go test ./...

clean:
	rm -rf bin

.PHONY: setup-codex
setup-codex:
	@codex_config=$${CODEX_CONFIG:-"$(HOME)/.codex/config.toml"}; \
	config_dir=$$(dirname "$$codex_config"); \
	mkdir -p "$$config_dir"; \
	if grep -q '^\[model_providers\.irelay\]' "$$codex_config" 2>/dev/null; then \
		echo "iRelay already configured in $$codex_config"; \
	else \
		echo '' >> "$$codex_config"; \
		echo 'model_provider = "irelay"' >> "$$codex_config"; \
		echo 'model = "deepseek-v4-pro"' >> "$$codex_config"; \
		echo '' >> "$$codex_config"; \
		echo '[model_providers.irelay]' >> "$$codex_config"; \
		echo 'name = "iRelay"' >> "$$codex_config"; \
		echo 'base_url = "http://localhost:8787/v1"' >> "$$codex_config"; \
		echo 'env_key = "IRELAY_API_KEY"' >> "$$codex_config"; \
		echo 'wire_api = "responses"' >> "$$codex_config"; \
		echo "Codex configured to use iRelay at $$codex_config"; \
	fi; \
	if ! grep -q 'IRELAY_API_KEY' "$$HOME/.zshrc" 2>/dev/null; then \
		echo 'export IRELAY_API_KEY=1' >> "$$HOME/.zshrc"; \
		echo "Added IRELAY_API_KEY to ~/.zshrc"; \
	else \
		echo "IRELAY_API_KEY already in ~/.zshrc"; \
	fi
