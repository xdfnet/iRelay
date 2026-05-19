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
