# iRelay

iRelay 是一个很小的本机中转服务，让 Codex 可以通过 OpenAI Responses API 的形态使用 DeepSeek。

它运行在你的机器上，只暴露 Codex 需要的最小接口，并把请求转发到 DeepSeek Chat Completions。不做控制台、不做数据库、不做多供应商平台，也不引入额外运行时。

## 为什么需要

Codex 使用 Responses API。DeepSeek 使用 Chat Completions。

iRelay 做的事情就是把两边接起来：

```txt
Codex Responses API -> iRelay -> DeepSeek Chat Completions
```

它适合想用 Codex + DeepSeek，但不想运行完整代理平台的人。

## 功能

- 面向 Codex 的极简本机服务
- 纯 Go 标准库实现，无第三方依赖
- 支持 `/v1/models` 和 `/v1/responses`
- 支持普通和流式 Responses 请求
- 支持 Codex function tools 和多轮工具结果
- 将 DeepSeek 流式工具调用转换为 Responses SSE 事件
- 为 Chat Completions 兼容性固定关闭 DeepSeek thinking
- 回放历史前自动移除 `reasoning_content`
- 未知模型名自动 fallback 到 `deepseek-v4-flash`
- 可选本机 trace 文件，方便排查请求/响应转换问题

## 不做什么

iRelay 刻意保持小而稳。

- 不做多 provider 路由
- 不接 Anthropic 兼容上游
- 不提供 `/v1/chat/completions` 透传
- 不兼容 hosted tools、图片、音频、文件或 web search
- 不引入数据库、插件系统、管理后台或配置文件格式

如果你需要完整桥接平台，可以选择那类项目。iRelay 只专注一件事：让 Codex 使用 DeepSeek。

## 接口

- `GET /health`：健康检查
- `GET /v1/models`：返回 Codex 需要的模型元数据
- `POST /v1/responses`：给 Codex 使用的 Responses 兼容接口

默认本机地址：

```txt
http://localhost:8787
```

## 模型

iRelay 暴露：

- `deepseek-v4-pro`
- `deepseek-v4-flash`

未知模型名会自动 fallback 到 `deepseek-v4-flash`。

## 快速开始

安装：

```bash
make install
```

设置 DeepSeek API Key：

```bash
export DEEPSEEK_API_KEY="你的 DeepSeek API Key"
```

运行：

```bash
irelay
```

验证：

```bash
curl http://localhost:8787/health
curl http://localhost:8787/v1/models
```

## 配置 Codex

临时使用：

```bash
IRELAY_API_KEY=local codex exec --skip-git-repo-check \
  -c 'model_providers.irelay={name="iRelay",base_url="http://localhost:8787/v1",env_key="IRELAY_API_KEY",wire_api="responses"}' \
  -c model_provider=irelay \
  --model deepseek-v4-pro \
  "只回答 OK"
```

写入 `~/.codex/config.toml`：

```toml
model_provider = "irelay"
model = "deepseek-v4-pro"

[model_providers.irelay]
name = "iRelay"
base_url = "http://localhost:8787/v1"
env_key = "IRELAY_API_KEY"
wire_api = "responses"
```

持久化环境变量：

```bash
echo 'export DEEPSEEK_API_KEY="你的 DeepSeek API Key"' >> ~/.zshrc
echo 'export IRELAY_API_KEY=1' >> ~/.zshrc
```

之后直接启动 Codex：

```bash
codex
```

## 工具调用验证

用下面命令验证 Codex tool calling 是否能通过 iRelay 正常工作：

```bash
IRELAY_API_KEY=local codex exec --skip-git-repo-check \
  -c 'model_providers.irelay={name="iRelay",base_url="http://localhost:8787/v1",env_key="IRELAY_API_KEY",wire_api="responses"}' \
  -c model_provider=irelay \
  --model deepseek-v4-pro \
  "用工具运行 pwd，然后只回答命令输出"
```

## Trace 调试

trace 默认关闭。

排查转换问题时可以临时开启：

```bash
IRELAY_TRACE=1 go run ./cmd/irelay
```

默认 trace 目录：

```txt
/tmp/irelay-trace
```

也可以指定目录：

```bash
IRELAY_TRACE=1 IRELAY_TRACE_DIR=/tmp/irelay-debug go run ./cmd/irelay
```

trace 文件会记录 Codex 请求、DeepSeek 请求、DeepSeek 响应和 iRelay 响应等关键 JSON。里面可能包含提示词和工具参数，只建议本机临时调试使用。

## 安全提醒

iRelay 是为本机使用设计的。

- 除非明确知道自己在做什么，否则保持监听在 localhost
- 不要直接暴露到公网
- trace 文件按敏感数据处理
- `DEEPSEEK_API_KEY` 放在本机 shell 环境里，不要提交到仓库

## launchd

如果用 macOS 用户级服务运行，plist 通常在：

```txt
~/Library/LaunchAgents/com.local.irelay.plist
```

重载：

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.local.irelay.plist 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.local.irelay.plist
launchctl kickstart -k gui/$(id -u)/com.local.irelay
```

查看状态：

```bash
launchctl list | rg irelay
ps aux | rg '[i]relay'
```

## 开发

```bash
make test
make build
make clean
```

代码保持单 `package main`，只按职责轻量拆文件：

- `main.go`：启动、配置加载、信号关闭
- `server.go`：HTTP handlers、JSON/SSE 响应、DeepSeek HTTP 调用
- `models.go`：`/v1/models` 元数据
- `responses.go`：Responses 请求解析、非流式转换、DeepSeek tweak
- `stream.go`：DeepSeek Chat SSE 到 Responses SSE 转换

卸载：

```bash
make uninstall
```

## License

MIT
