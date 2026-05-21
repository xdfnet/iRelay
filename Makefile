BINARY := irelay
CMD := ./cmd/irelay

.PHONY: build test release clean help

help:
	@echo "iRelay"
	@echo ""
	@echo "  make build      # 编译"
	@echo "  make test       # 测试"
	@echo "  make release    # 发布"
	@echo "  make clean      # 清理"

build:
	go build -o bin/$(BINARY) $(CMD)

test:
	go test ./...

release: test
	npm publish --access public

clean:
	rm -rf bin
