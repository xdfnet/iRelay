BINARY := irelay
CMD := ./cmd/irelay
VERSION := $(shell grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' package.json | head -1 | sed 's/.*: *"\(.*\)"/\1/')

.PHONY: build test release clean help

help:
	@echo "iRelay $(VERSION)"
	@echo ""
	@echo "  make build      # 编译"
	@echo "  make test       # 测试"
	@echo "  make release    # 发布"
	@echo "  make clean      # 清理"

build:
	go build -ldflags="-s -w -X main.version=$(VERSION)" -o bin/$(BINARY) $(CMD)

test:
	go test ./...

release: test
	npm publish --access public

clean:
	rm -rf bin
