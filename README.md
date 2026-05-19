# iRelay

[![Version](https://img.shields.io/badge/version-v1.2.0-0f766e)](./package.json)
[![Go](https://img.shields.io/badge/Go-1.26-00ADD8)](./go.mod)
[![License](https://img.shields.io/badge/license-MIT-blue)](./LICENSE)
[![Dependencies](https://img.shields.io/badge/dependencies-zero-success)](./go.mod)

> 小而稳的 Codex → DeepSeek 本机中转服务。

iRelay 是一个极简本机服务，让 Codex 通过 OpenAI Responses API 形态使用 DeepSeek。只暴露 Codex 需要的最小接口，不做控制台、不做数据库、不做多供应商平台。

```txt
Codex Responses → iRelay → DeepSeek Chat Completions
```

| 项目 | 内容 |
|------|------|
| 当前版本 | `v1.2.0` |
| 默认地址 | `http://localhost:8787` |
| 依赖 | Go 标准库，零第三方依赖 |
| 开源协议 | MIT |

## 功能

- 纯 Go 标准库，零第三方依赖
- 支持 `/v1/models`、`/v1/responses`（普通 + 流式）
- Codex function tools 完整支持，含多轮工具结果
- DeepSeek 流式工具调用 → Responses SSE 事件转换
- 固定关闭 DeepSeek thinking，避免 Codex 不兼容 reasoning_content 回传
- 未知模型名自动 fallback 到 `deepseek-v4-flash`
- 可选本机 trace 调试

## 不做什么

iRelay 刻意保持小而稳。不做多 provider 路由、不做 Anthropic 兼容、不提供 `/v1/chat/completions` 透传、不兼容 hosted tools/图片/音频/文件/web search、不引入数据库或管理后台。

## 接口

| 路径 | 说明 |
|------|------|
| `GET /health` | 健康检查 |
| `GET /v1/models` | Codex 模型元数据 |
| `POST /v1/responses` | Responses 兼容接口 |

默认地址：`http://localhost:8787`

## 模型

- `deepseek-v4-pro`
- `deepseek-v4-flash`

未知模型名自动 fallback 到 `deepseek-v4-flash`。

## 快速开始

```bash
# 安装
npm install -g @xdfnet/irelay     # npm
# 或
make install                       # 源码

# 设置 API Key
export DEEPSEEK_API_KEY="你的 DeepSeek API Key"

# 启动
irelay serve

# 验证
irelay --version
curl http://localhost:8787/health
curl http://localhost:8787/v1/models
```

npm 安装会在本机用 Go 编译，需提前安装 Go。

## 配置 Codex

```bash
irelay setup
```

自动写入 `~/.codex/config.toml` 的 irelay provider、设置默认 `model_provider` 和模型、追加环境变量到 `~/.zshrc`。

开关命令：

```bash
irelay on       # 启用 iRelay
irelay off      # 停用 iRelay（只移除顶层配置，保留 provider 定义和密钥）
irelay status   # 查看当前状态
irelay doctor   # 检查环境就绪情况
```

临时使用（不写配置）：

```bash
IRELAY_API_KEY=local codex exec --skip-git-repo-check \
  -c 'model_providers.irelay={name="iRelay",base_url="http://localhost:8787/v1",env_key="IRELAY_API_KEY",wire_api="responses"}' \
  -c model_provider=irelay \
  --model deepseek-v4-pro \
  "只回答 OK"
```

## Trace 调试

```bash
IRELAY_TRACE=1 irelay serve
```

trace 文件写入 `/tmp/irelay-trace/`（可设 `IRELAY_TRACE_DIR` 指定目录）。记录 Codex 请求、DeepSeek 请求/响应和 iRelay 响应的关键 JSON。可能含提示词和工具参数，仅建议本机临时调试。

## launchd

macOS 用户级服务：

```bash
# 重载
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.local.irelay.plist 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.local.irelay.plist
launchctl kickstart -k gui/$(id -u)/com.local.irelay

# 查看
launchctl list | rg irelay
```

## 开发

```bash
make test
make build
make clean
```

代码结构（单 `package main`）：

| 文件 | 职责 |
|------|------|
| `main.go` | 启动、配置加载、CLI 命令 |
| `server.go` | HTTP handlers、DeepSeek 调用、响应序列化 |
| `models.go` | `/v1/models` 元数据 |
| `responses.go` | Responses 请求解析、Chat 格式转换 |
| `stream.go` | DeepSeek SSE → Responses SSE |
| `setup.go` | Codex 配置写入 / on / off / status / doctor |

```bash
make uninstall
```

## 安全提醒

- 保持监听在 localhost，不要暴露到公网
- trace 文件按敏感数据处理
- `DEEPSEEK_API_KEY` 放在 shell 环境里，不要提交到仓库

## License

MIT
