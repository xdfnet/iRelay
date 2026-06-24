# iRelay 架构文档

> 版本 2.1.0 · macOS 菜单栏应用 · Zero external dependencies

---

## 概述

**iRelay** 是一个运行在 macOS 菜单栏的中继代理。它把 **Codex 的 Responses API** 转换成 **OpenAI Chat Completions API**，通过 **DeepSeek** 提供推理服务。

请求流程：

```text
Codex ──responses API──→ iRelay (localhost:8787/v1) ──chat API──→ DeepSeek
```

同时提供 `/v1/chat/completions` 直通接口，允许绕过协议转换直接调用 DeepSeek。

HTTP 服务器和中继逻辑全部基于 Apple `Network` + `Foundation` 框架手写，零第三方库。

---

## 分层架构

```text
┌──────────────────────────────────────────────┐
│               UI Layer (SwiftUI)               │
│  iRelayApp  MenuBarView  ApiKeyConfigWindow   │
└──────────────────────┬────────────────────────┘
                       │ @StateObject / @ObservedObject
                       ▼
┌──────────────────────────────────────────────┐
│              State Layer (RelayState)          │
│  apiKey · model · thinkingEnabled · port(8787)│
│  模型列表缓存 · 服务生命周期                   │
│  UserDefaults 持久化 · Codex 配置同步          │
└─────────┬──────────────────┬──────────────────┘
          │ owns             │ owns
          ▼                  ▼
┌────────────────────┐  ┌───────────────────────┐
│   RelayHandler      │  │  CodexConfigManager   │
│   协议转换引擎       │  │  TOML 读写器          │
│   (持有 ChatClient) │  │  ↓ owns               │
│   ↓ owns            │  │  CodexAppPatcher      │
│   ChatClient        │  │  桌面 App 适配器      │
└────────────────────┘  └───────────────────────┘
          │
          ▼
┌────────────────────┐
│   HTTPServer        │
│  手写 HTTP/1.1     │
│  (Network.framework)│
└────────────────────┘
```

### 模块结构

```text
📦 iRelayCore (library, testable)
├── Core/
│   ├── ChatClient.swift     # 通用 Chat Completions API 客户端
│   ├── HTTPServer.swift     # 零依赖 HTTP/1.1 服务器
│   └── RelayHandler.swift   # 协议转换引擎 + SSE 流式转换
├── Models/
│   ├── ProviderConfig.swift # 提供商配置 + ThinkingMode + 预设工厂
│   └── RelayConfig.swift    # ModelInfo 数据模型
└── Services/
    └── Logger.swift          # 异步文件日志

📦 iRelay (executable, depends on iRelayCore)
├── iRelayApp.swift           # @main 入口 + API Key 配置窗口
├── MenuBarView.swift         # 菜单栏 UI（模型/模式/配置/退出）
├── Models/
│   └── RelayState.swift      # 全局状态（直接持有 apiKey/model/thinking）
└── Services/
    ├── CodexConfigManager.swift  # ~/.codex/config.toml 管理
    └── CodexAppPatcher.swift # Codex 桌面 App 白名单补丁

📦 iRelayTests (test target)
└── RelayHandlerTests.swift   # 26 个协议转换单元测试
```

---

## 核心流程

### 1. 启动时序

```text
App启动
  │
  ├─ RelayState.init()
  │   ├─ 从 UserDefaults 恢复 apiKey / model / thinkingEnabled / codexEnabled
  │   └─ turnOn(model:)
  │       ├─ 使用固定 upstream = "https://api.deepseek.com"
  │       ├─ 创建 ChatClient (apiKey + upstream)
  │       ├─ 创建 RelayHandler (注入 .deepSeek ProviderConfig)
  │       ├─ 创建 HTTPServer, 注册路由
  │       │   ├─ GET  /health
  │       │   ├─ GET  /v1/models          (透传 DeepSeek)
  │       │   ├─ POST /v1/responses       (协议转换)
  │       │   └─ POST /v1/chat/completions (直通透传)
  │       └─ 启动 NWListener (端口: 8787)
  │
  └─ 挂载 MenuBarExtra, 显示菜单栏图标
```

配置和补丁在以下时机触发：

```text
用户保存 API Key
  └─ saveApiKey(key) → 更新 apiKey → turnOff()+turnOn()
      └─ syncCodexConfig() → CodexConfigManager.enable(model:port:)

用户切换模型
  └─ selectModel(id) → syncCodexConfig() → enable()
      ├─ 写入 ~/.codex/config.toml
      ├─ 写入 ~/.codex/irelay-models.json (DeepSeek 模型列表)
      └─ 备份 app.asar → 打补丁

用户切换思考模式
  └─ setThinking(enabled)
      ├─ 更新 handler.provider.thinkingMode
      └─ 更新 UserDefaults

用户关闭 iRelay 模型提供
  └─ disableCodex() → disable()
      ├─ 恢复 app.asar → 删备份
      ├─ 清 config.toml 中 iRelay 配置
      └─ 删 irelay-models.json
```

### 2. 请求处理流程

#### POST /v1/responses — 协议转换

```text
Codex CLI                          iRelay                              DeepSeek
    │                                │                                      │
    │  POST /v1/responses            │                                      │
    ├───────────────────────────────→│                                      │
    │                                │                                      │
    │                                ├─ RelayHandler.handleResponses()      │
    │                                │   ├─ 解析 responses 请求体           │
    │                                │   ├─ responsesToChatPayload()        │
    │                                │   │   └─ 所有参数透传 + 类型映射     │
    │                                │   │      工具定义展平                │
    │                                │   │      thinking/reasoning 按        │
    │                                │   │      ProviderConfig 注入          │
    │                                │   │                                  │
    │                                │   ├─ 流式?                          │
    │                                │   │  ├─ Yes → handleStream()         │
    │                                │   │  │   ├─ SSE: response.created    │
    │                                │   │  │   ├─ SSE: response.metadata   │
    │                                │   │  │   ├─ POST /chat/completions ──→│
    │                                │   │  │   │   (stream=true)           │
    │                                │   │  │   ├─ ← SSE ←─────────────────│
    │                                │   │  │   │   (逐帧转换 delta         │
    │                                │   │  │   │    → reason/工具/文本)     │
    │                                │   │  │   └─ SSE: response.completed  │
    │                                │   │  │       (含 end_turn + usage)
    │                                │   │  │                                │
    │                                │   │  └─ No → handleNonStream()       │
    │                                │   │      ├─ POST /chat/completions ──→│
    │                                │   │      ├─ ← JSON ←─────────────────│
    │                                │   │      └─ chatCompletionToResponse()│
    │                                │   │          → JSON 200             │
    │                                │                                      │
    │  ← 流式 SSE / 非流式 JSON ─────┼──────────────────────────────────────│
    │                                │                                      │
```

#### POST /v1/chat/completions — 直通透传

```text
客户端                               iRelay                              DeepSeek
    │                                │                                      │
    │  POST /v1/chat/completions     │                                      │
    ├───────────────────────────────→│                                      │
    │                                │                                      │
    │                                ├─ RelayHandler.handleChatCompletions()│
    │                                │   ├─ 解析 JSON 请求体                │
    │                                │   ├─ 流式?                          │
    │                                │   │  ├─ Yes → 逐帧透传 SSE data:    │
    │                                │   │  │   └─ POST /chat/completions ──→│
    │                                │   │  │       (stream=true)           │
    │                                │   │  │   ← 原始 SSE ←───────────────│
    │                                │   │  └─ → data: [DONE] → 关闭       │
    │                                │   │                                  │
    │                                │   │  └─ No → 原生 JSON 透传         │
    │                                │   │      └─ POST /chat/completions ──→│
    │                                │   │      ← JSON ←───────────────────│
    │                                │   │      → 原样 JSON 200            │
    │                                │                                      │
    │  ← 原始 SSE / 原始 JSON ──────┼──────────────────────────────────────│
    │                                │                                      │
```

---

## 协议转换

### 请求（Responses API → Chat API）

| Responses 字段 | Chat API 字段 | 行为 |
|---|---|---|
| `model` | `model` | 透传 |
| `instructions` | `messages[0].role=system` | |
| `input` | `messages` | 按 type 拆解（见下表） |
| `tools[].name/.description/.parameters` | `tools[].function.name/.../...` | 展平嵌套 |
| `temperature` | `temperature` | 透传 |
| `top_p` | `top_p` | 透传 |
| `max_output_tokens` | `max_tokens` | |
| `stream` | `stream` + `stream_options.include_usage` | |
| `tool_choice` | `tool_choice` | 按 `provider.supportsToolChoice` 开关 |
| `parallel_tool_calls` | `parallel_tool_calls` | 透传 |
| `reasoning.effort` | `reasoning_effort` | 仅 DeepSeek 模式 |
| — | `thinking.type=enabled` | DeepSeek 推理模式 |

### Input 类型映射

| Responses `type` | Chat Message | 字段来源 |
|---|---|---|
| `message` (user) | `{role:"user", content:"..."}` | `item.content[]` → `contentToText` |
| `message` (assistant) | `{role:"assistant", content:"..."}` | 同上 |
| `function_call` | `{role:"assistant", tool_calls:[...]}` | `item.name` / `item.arguments` **顶层字段** |
| `function_call_output` | `{role:"tool", tool_call_id, content}` | `item.call_id` / `item.output` |
| `reasoning` | 暂存，附加到下条 assistant | `item.content` |
| `input_text` | `{role:"user", content:"..."}` | `item.text` |

### 工具定义转换

```json
// Responses API 格式
{"type":"function", "name":"Edit", "description":"Edits files", "parameters":{...}}

// 转 Chat API
{"type":"function", "function":{"name":"Edit", "description":"Edits files", "parameters":{...}}}
```

### 响应（Chat API SSE → Responses API SSE）

| SSE 事件 | 触发条件 |
|---|---|
| `response.created` | 流开始 |
| `response.metadata` | 紧随 created，带 `x-codex-turn-state` / `openai-model` |
| `response.output_item.added` | reasoning / message / function_call item 开始 |
| `response.content_part.added` | reasoning_text / output_text part 开始 |
| `response.reasoning_text.delta` | `delta.reasoning_content`（按 `provider.reasoningField`） |
| `response.output_text.delta` | `delta.content` |
| `response.function_call_arguments.delta` | `delta.tool_calls[].function.arguments` |
| `response.output_text.done` | 文本流结束 |
| `response.content_part.done` | part 完成 |
| `response.function_call_arguments.done` | tool_call 流结束 |
| `response.output_item.done` | item 完成 |
| `response.completed` | 流结束，含 `usage` + `end_turn` |
| `response.failed` | 异常 |

### usage 格式

```json
{
  "input_tokens": 100,
  "output_tokens": 200,
  "total_tokens": 300,
  "input_tokens_details": {"cached_tokens": 0},
  "output_tokens_details": {"reasoning_tokens": 0}
}
```

### 协议覆盖矩阵

| 功能 | 状态 | 说明 |
|------|:----:|------|
| `model` / `instructions` / `input` | ✅ | |
| `tools` / `tool_choice` / `parallel_tool_calls` | ✅ | |
| `stream` / `temperature` / `top_p` / `max_output_tokens` | ✅ | |
| `reasoning.effort` / `thinking` | ✅ | 按 ProviderConfig 注入 |
| `end_turn` | ✅ | 流结束前发 output_item + completed 携带 |
| `response.metadata` | ✅ | 带 turn_state / model |
| SSE 完整事件流 | ✅ | 11 种事件全部覆盖 |
| `usage` 明细 | ✅ | `input_tokens_details` / `output_tokens_details` |
| `text` (verbosity / format) | ❌ | Chat API 不支持 |
| `store` / `service_tier` / `include` | ❌ | OpenAI 平台独有 |
| `prompt_cache_key` | ❌ | DeepSeek 不支持 |
| `previous_response_id` | ❌ | 仅 WebSocket 增量会话需要 |
| `custom_tool_call` input type | ❌ | Codex 极少通过 HTTP 发送 |

---

## ProviderConfig

iRelay 当前固定使用 DeepSeek（硬编码于 `RelayState.turnOn()`），但 `ProviderConfig` 模型层仍保留多预设（`.deepSeek` / `.openAI` / `.custom()` 工厂），方便未来扩展：

| 字段 | 值 |
|---|---|
| `baseURL` | `https://api.deepseek.com` |
| `thinkingMode` | `.deepseekStyle`（注入 `thinking.type=enabled`） |
| `reasoningField` | `reasoning_content`（SSE delta 中的推理字段） |
| `supportsToolChoice` | `false` |
| `defaultModel` | `deepseek-v4-pro` |

---

## 持久化

| 存储位置 | 内容 | 读写时机 |
|---|---|---|
| `UserDefaults` key `irelay_apiKey` | DeepSeek API Key | 配置窗口保存时 |
| `UserDefaults` key `irelay_model` | 当前模型 ID | 切换模型时 |
| `UserDefaults` key `irelay_thinking` | 思考模式开关 | 切换模式时 |
| `UserDefaults` key `irelay_codexEnabled` | Codex 集成开关 | 开关模型时 |
| `UserDefaults` key `irelay_models` | 模型列表缓存 | 拉取模型列表后 |
| `~/.codex/config.toml` | Codex 中继配置 | 切模型/存 Key 时写，关模型时清 |
| `~/.codex/irelay-models.json` | 模型目录（固定 DeepSeek） | 同上 |
| `/Applications/Codex.app/.../app.asar` | Codex 桌面 App 前端包 | 存 Key/切模型时备份+补丁 |
| `~/.config/irelay/irelay.log` | 运行日志 | 每行日志异步追加 |

---

## 测试

26 个单元测试覆盖协议转换核心路径：

| 测试组 | 数量 | 覆盖 |
|---|---|---|
| `responsesToChatPayload` | 5 | 基础、thinking 开/关、tool_choice 透传 |
| `chatCompletionToResponse` | 3 | 纯文本、tool_calls、reasoning |
| `collectFunctionCalls` | 2 | **Responses 格式 + Chat 格式 fallback** |
| `parseInput` | 5 | 纯文本、system prompt、null、工具历史、reasoning |
| `contentToText` | 3 | string、nil、数组 |
| `convertTools` | 2 | 基础、过滤非 function |
| `ensureToolAfterAssistant` | 1 | 消息重排 |
| `responseItemToMessage` | 2 | function_call_output、input_text |
| `ProviderConfig` | 3 | DeepSeek、OpenAI、custom 预设 |

运行：`swift test`

---

## 关键设计决策

### 零外部依赖

全部基于 Apple 内置框架：
- **`Network.framework`** — NWListener / NWConnection，替代 Vapor
- **`Foundation`** — URLSession + JSONSerialization
- **`SwiftUI`** — MenuBarExtra

### 手写 HTTP 解析

NWConnection 是传输层 API。项目用约 200 行手写了 HTTP/1.1 请求解析，只支持必要子集：
- GET / POST
- Content-Length 请求体
- 纯文本响应（JSON / SSE）

### 协议转换的设计取舍

**转换在 RelayHandler，不在 ChatClient**：
- `ChatClient` — 只懂 Chat API，不管格式
- `RelayHandler` — 只做格式转换，不管 HTTP 传输

**Streaming 适配策略**：DeepSeek 的 SSE stream 通过 `AsyncThrowingStream` 变成异步序列，逐帧消费、逐帧转换、逐帧推送。不缓冲整个响应。

**提供商适配用标志位，不搞协议**：Chat API 之间的差异很小，3-4 个字段就能描述。

---

## 限制

1. **API Key 明文存储** — UserDefaults，非钥匙串
2. **HTTP 解析有限** — 不支持 `Transfer-Encoding: chunked`
3. **单请求队列** — 无连接池
4. **WebSocket 不支持** — Codex 强制 HTTP fallback
5. **asar 补丁依赖 bundle 字符串** — Codex 更新后表达式可能变化

## 协议适配历史

### 2026-06-24：v2.1.5 数据流闪烁指示
- 新增 `activeRequestCount` 追踪活跃请求
- `RelayHandler` 添加 `onRequestActive`/`onRequestInactive` 回调，覆盖所有请求路径
- 菜单栏图标在有数据流时闪烁（`circle.fill` ↔ `circle` 交替），无请求时静态实心
- 关闭服务时自动归零请求计数

### 2026-06-15：v2.1.0 简化重构 — 纯 DeepSeek + 固定端口 + Chat 透传

- 移除多提供商架构：删除 `ProviderStore`，`RelayState` 直接持有 `apiKey`/`model`/`thinkingEnabled`
- 移除端口配置：端口固定 `8787`，删除 `PortConfigWindow`
- 新增 `/v1/chat/completions` 直通接口：流式透传 SSE `data:` 行，非流式原样 JSON
- UI 精简：去掉提供商管理和端口配置菜单，仅保留模型/模式/Key/退出
- `CodexConfigManager.enable()` 签名简化：`(provider:port:)` → `(model:port:)`
- `setThinking` 通过更新 `handler.provider.thinkingMode` 动态生效，无需重启服务
- Logger 日志格式优化：消息显示 `(N chars): preview` 而非完整内容

### 2026-06-15：v2.0.0 多提供商通用化
- 新增 `ProviderConfig` / `ProviderStore`，支持任意 Chat API 提供商
- `DeepSeekClient` → `ChatClient`
- `RelayHandler` 注入 `ProviderConfig`：thinking/reasoning 动态化
- 端口可配置
- UI 增加提供商管理、端口配置

### 2026-06-15：修复 `collectFunctionCalls` 字段路径
`item["function"]["name"]` → `item["name"]`，Responses API 中 name/arguments 在顶层。

### 2026-06-15：三个协议补丁
- usage 补 `input_tokens_details` / `output_tokens_details`
- 加 `response.metadata` SSE 事件
- `reasoning.effort` 透传
