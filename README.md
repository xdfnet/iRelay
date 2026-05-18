# iRelay

iRelay 是一个给个人本机使用的 Codex → DeepSeek 中转服务。

它只服务 Codex：

- `GET /health`：本地健康检查
- `GET /v1/models`：返回 Codex 需要的模型元数据
- `POST /v1/responses`：接收 Codex Responses API 请求，并转为 DeepSeek `/chat/completions`

## 特性

- 纯 Go 标准库实现，无第三方依赖
- 支持 Codex Responses API 基础文本链路
- 支持 Codex function tools 多轮调用
- 支持流式输出和 function call 事件转换
- 固定关闭 DeepSeek thinking，避免工具回传时要求 `reasoning_content`
- 未知模型自动 fallback 到 `deepseek-v4-flash`，节省费用
- DeepSeek API Key 从 `DEEPSEEK_API_KEY` 环境变量读取

## 安装

```bash
make install
```

默认安装到：

```txt
~/.local/bin/irelay
```

如果 `~/.local/bin` 不在 `PATH`，加入 shell 配置：

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## 运行

开发运行：

```bash
go run ./cmd/irelay
```

安装后运行：

```bash
irelay
```

默认监听：

```txt
http://localhost:8787
```

健康检查：

```bash
curl http://localhost:8787/health
```

模型列表：

```bash
curl http://localhost:8787/v1/models
```

当前返回：

- `deepseek-v4-pro`（默认）
- `deepseek-v4-flash`（fallback 目标，当 Codex 使用其他模型名时自动切换）

## Codex 使用

临时使用：

```bash
IRELAY_API_KEY=local codex exec --skip-git-repo-check \
  -c 'model_providers.irelay={name="iRelay",base_url="http://localhost:8787/v1",env_key="IRELAY_API_KEY",wire_api="responses"}' \
  -c model_provider=irelay \
  --model deepseek-v4-pro \
  "只回答 OK"
```

工具调用验证：

```bash
IRELAY_API_KEY=local codex exec --skip-git-repo-check \
  -c 'model_providers.irelay={name="iRelay",base_url="http://localhost:8787/v1",env_key="IRELAY_API_KEY",wire_api="responses"}' \
  -c model_provider=irelay \
  --model deepseek-v4-pro \
  "用工具运行 pwd，然后只回答命令输出"
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

之后运行：

```bash
IRELAY_API_KEY=local codex
```

环境变量持久化（只需一次）：

```bash
echo 'export DEEPSEEK_API_KEY="你的 DeepSeek API Key"' >> ~/.zshrc
echo 'export IRELAY_API_KEY=1' >> ~/.zshrc
```

之后直接 `codex` 即可，无需每次设置环境变量。

## 自启动

当前使用用户级 `launchd`：

```txt
~/Library/LaunchAgents/com.local.irelay.plist
```

服务启动命令：

```txt
~/.local/bin/irelay
```

重载服务：

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

卸载本地二进制：

```bash
make uninstall
```

## 边界

- 只支持 Codex 需要的 `/v1/models` 和 `/v1/responses`
- 不再提供通用 `/v1/chat/completions` 透传
- 图片、音频、文件和 hosted tools 没有做兼容
- Responses API 是轻量兼容层，不是完整复刻
- 流式响应支持客户端断开时自动取消上游连接
- `contentToText` 遇到未知类型会输出 debug 日志，便于扩展多模态
