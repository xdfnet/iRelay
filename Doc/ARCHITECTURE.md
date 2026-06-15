# iRelay 架构文档

> 版本 1.4.0 · macOS 菜单栏应用 · Zero external dependencies

---

## 概述

**iRelay** 是一个运行在 macOS 菜单栏的中继代理。它把 **Codex 的 `responses` API** 转换成 **DeepSeek Chat API**，让 Codex 可以直接使用 DeepSeek 模型（V4 Pro / V4 Flash）。

```
Codex CLI ──responses API──→ iRelay (localhost:8787) ──chat API──→ api.deepseek.com
```

只有一个外部依赖：DeepSeek 的上游 API。HTTP 服务器和中继逻辑全部基于 Apple `Network` + `Foundation` 框架手写，零第三方库。

---

## 分层架构

```
┌─────────────────────────────────────────────────────┐
│                  UI Layer (SwiftUI)                  │
│  iRelayApp  MenuBarView  ApiKeyConfigWindow         │
└────────────────────┬────────────────────────────────┘
                     │ @StateObject / @ObservedObject
                     ▼
┌─────────────────────────────────────────────────────┐
│              State Layer (RelayState)                │
│  状态管理 · 生命周期 · UserDefaults 持久化           │
│  Codex 配置同步 · 模型列表拉取                       │
└─────────┬──────────────────────┬────────────────────┘
          │ owns                 │ owns
          ▼                      ▼
┌──────────────────┐  ┌──────────────────────────┐
│   RelayHandler    │  │   CodexConfigManager     │
│  协议转换引擎     │  │   TOML 读写器             │
│  ↓ owns           │  │   ↓ owns                 │
│   DeepSeekClient  │  │   CodexAppPatcher         │
│                  │  │   桌面 App 适配器          │
│                  │  └──────────────────────────┘
└──────────────────┘
          │
          ▼
┌──────────────────┐
│   HTTPServer      │
│  手写 HTTP/1.1   │
│  (Network.fw)     │
└──────────────────┘
```

### 各层职责

| 层 | 文件 | 职责 |
|---|---|---|
| **UI** | `iRelayApp.swift` | `@main` 入口，创建 `MenuBarExtra`，提供 API Key 配置窗口 |
| **UI** | `MenuBarView.swift` | 菜单栏界面：模型切换、思考模式、关闭/退出 |
| **State** | `RelayState.swift` | 全局状态单例，管理服务生命周期，持久化用户偏好 |
| **Adapter** | `RelayHandler.swift` | **核心引擎**：responses ↔ chat/completions 协议转换 |
| **Client** | `DeepSeekClient.swift` | DeepSeek API HTTP 客户端（流式+非流式） |
| **Server** | `HTTPServer.swift` | 零依赖 HTTP/1.1 服务器（NWListener） |
| **Config** | `CodexConfigManager.swift` | 读写 `~/.codex/config.toml`，写入 `~/.codex/irelay-models.json` |
| **Config** | `CodexAppPatcher.swift` | 修补 Codex 桌面 App 模型白名单过滤 |
| **Logger** | `Logger.swift` | 异步文件日志 |
| **Model** | `RelayConfig.swift` | `ModelInfo` 数据模型 |

---

## 核心流程

### 1. 启动时序

```
App启动
  │
  ├─ RelayState.init()
  │   ├─ 从 UserDefaults 恢复: apiKey / model / thinking / codexEnabled
  │   └─ turnOn(model:)
  │       ├─ 创建 DeepSeekClient (持有 apiKey)
  │       ├─ 创建 RelayHandler (持有 client + thinking)
  │       ├─ 创建 HTTPServer, 注册路由
  │       │   ├─ GET  /health
  │       │   ├─ GET  /v1/models      (透传 upstream)
  │       │   └─ POST /v1/responses
  │       └─ 启动 NWListener (端口 8787)
  │          (不写配置、不拉模型、不动 asar)
  │
  └─ 挂载 MenuBarExtra, 显示菜单栏图标
```

启动后直到用户配 Key 前，服务器只是空转。配置和补丁在以下时机触发：

```
用户输入 API Key
  └─ saveApiKey()
      └─ Task: fetchModels() → 拉取模型 → 存 UserDefaults
         (不写配置、不动 asar，等用户主动选模型)

用户切换模型（启用 iRelay）
  └─ selectModel(id) → codexEnabled = true
      └─ syncCodexConfig() → enable()
          ├─ 写入 ~/.codex/config.toml
          ├─ 写入 ~/.codex/irelay-models.json
          └─ 备份 app.asar → 打补丁

用户关闭 iRelay 模型提供
  └─ disableCodex() → codexEnabled = false
      └─ disable()
          ├─ 恢复 app.asar → 删备份
          ├─ 清 ~/.codex/config.toml 中 iRelay 配置
          └─ 删 ~/.codex/irelay-models.json

退出 App
  └─ turnOff()
      └─ 停服务器（不做其他清理）
```

### 2. 请求处理流程（POST /v1/responses）

```
Codex CLI                          iRelay                              DeepSeek API
    │                                │                                      │
    │  POST /v1/responses            │                                      │
    │  (responses 格式)              │                                      │
    ├───────────────────────────────→│                                      │
    │                                │                                      │
    │                                ├─ RelayHandler.handleResponses()      │
    │                                │   ├─ 解析 responses 请求体           │
    │                                │   ├─ responsesToChatPayload()        │
    │                                │   │   └─ instructions→system message │
    │                                │   │      input→user message          │
    │                                │   │      tools→function tools        │
    │                                │   │      thinking→thinking param     │
    │                                │   │                                  │
    │                                │   ├─ 流式?                          │
    │                                │   │  ├─ Yes → handleStream()         │
    │                                │   │  │   ├─ SSE: response.created    │
    │                                │   │  │   ├─ POST /chat/completions ──→│
    │                                │   │  │   │   (stream=true)           │
    │                                │   │  │   ├─ ← SSE events ←───────────│
    │                                │   │  │   │   (逐帧转换 delta)        │
    │                                │   │  │   └─ SSE: response.completed  │
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

### 3. 协议转换细节

#### 请求转换（Responses API → Chat API）

| Responses 字段 | Chat Completions 字段 | 说明 |
|---|---|---|
| `instructions` | `messages[0].role=system` | |
| `input` (string) | `messages[1].role=user` | |
| `input` (array items) | messages 数组 | 见下方 input 类型映射表 |
| `tools[].name/.description/.parameters` | `tools[].function.name/.../...` | 展平嵌套 |
| `stream=true` | `stream=true` + `stream_options.include_usage=true` | |
| `max_output_tokens` | `max_tokens` | |
| — | `thinking.type=enabled/disabled` | DeepSeek 推理模式 |

#### Input 类型映射

Responses API 的 `input` 数组中的每个 item 按 `type` 字段分类转换：

| Responses `type` | 生成的 Chat Message | 关键字段映射 |
|---|---|---|
| `message` (role=user) | `{role:"user", content:"..."}` | `item.content[]` → 拼接纯文本 |
| `message` (role=assistant) | `{role:"assistant", content:"..."}` | 同上 |
| `function_call` | `{role:"assistant", tool_calls:[...]}` | `item.name` / `item.arguments` **顶层字段** |
| `function_call_output` | `{role:"tool", tool_call_id, content}` | `item.call_id` / `item.output` |
| `reasoning` | 暂存 `pendingReasoning`，附加到下条 assistant | `item.content` |
| `input_text` | `{role:"user", content:"..."}` | `item.text` |

> ⚠️ `function_call` 在 Responses API 中 `name` 和 `arguments` 是**顶层字段**，非嵌套在 `function` 对象里。`collectFunctionCalls()` 曾因此读错，已于 2026-06-15 修复。

#### Tool 定义转换

```json
// Responses API 格式
{"type":"function", "name":"Edit", "description":"...", "parameters":{...}}

// 转 DeepSeek Chat API
{"type":"function", "function":{"name":"Edit", "description":"...", "parameters":{...}}}
```

#### 响应转换（Chat API → Responses API）

| DeepSeek SSE delta | 产生的 SSE 事件 |
|---|---|
| `choices[0].delta.reasoning_content` | `response.reasoning_text.delta` |
| `choices[0].delta.content` | `response.output_text.delta` / `.done` |
| `choices[0].delta.tool_calls[].function.arguments` | `response.function_call_arguments.delta` / `.done` |
| `usage` (流结束) | `response.completed` 中 `usage` 字段 |
| `choices[0].finish_reason`（非流式） | 触发 `chatCompletionToResponse()` 组装完整响应 |

### 4. Codex 配置与模型菜单适配

Codex 有两条模型相关链路：

1. **Rust app-server 模型目录**：读取 `model_catalog_json`，返回 DeepSeek 模型元数据。
2. **桌面前端模型菜单**：读取 app-server 返回值后，还会经过远端 Statsig 白名单过滤。

iRelay 启用时写入：

```toml
model_provider = "iRelay"
model = "deepseek-v4-flash"
model_catalog_json = "/Users/admin/.codex/irelay-models.json"

[model_providers.iRelay]
name = "iRelay"
base_url = "http://127.0.0.1:8787/v1"
wire_api = "responses"
```

`irelay-models.json` 提供完整 `ModelInfo`，包括：

- `slug`
- `display_name`
- `supported_reasoning_levels`
- `default_reasoning_level`
- `shell_type`
- `context_window`
- `truncation_policy`
- `apply_patch_tool_type`

桌面 App 的前端 Statsig 配置可能包含：

```json
{
  "available_models": ["gpt-5.5", "gpt-5.4", "gpt-5.4-mini"],
  "use_hidden_models": true
}
```

启用 `use_hidden_models` 后，前端只显示白名单模型。DeepSeek 不在白名单中时会被过滤，模型菜单显示为空。

`CodexAppPatcher` 会对 `/Applications/Codex.app/Contents/Resources/app.asar` 做等长补丁，将白名单过滤退回为 `hidden=false` 过滤。这样 DeepSeek 仍能显示，且不需要外部 `asar` 工具。首次补丁前会创建：

```text
/Applications/Codex.app/Contents/Resources/app.asar.bak.irelay-auto
```

---

## 关键设计决策

### 为什么零外部依赖？

全部基于 Apple 内置框架：
- **`Network.framework`** — 提供 `NWListener` / `NWConnection`，替代 GCDWebServer 或 Vapor
- **`Foundation`** — `URLSession` 做 HTTP 客户端，`JSONSerialization` 做 JSON 解析
- **`SwiftUI`** — `MenuBarExtra` 提供菜单栏 UI

动机：减少二进制体积，消除 SPM 依赖冲突，方便维护。

### 为什么手写 HTTP 解析？

`NWConnection` 是传输层 API，不提供 HTTP 语义。项目用约 200 行手写了 HTTP/1.1 请求解析（`HTTPServer.parseHTTP`），只支持必要的子集：
- `GET` / `POST`（Codex 只用这两种）
- `Content-Length` 请求体（不支持 `Transfer-Encoding: chunked`）
- 纯文本响应（JSON / SSE）

### 协议转换的设计取舍

**转换发生在 `RelayHandler`**，而非在 `DeepSeekClient` 中。这是一个明确的职责分离：

- `DeepSeekClient` — 只懂 Chat Completions API，不管格式转换
- `RelayHandler` — 只做格式转换，不管 HTTP 传输
- 这样任何一个都可以独立测试

**Streaming 的适配策略**：把 DeepSeek 的 `data: {...}` SSE stream 通过 `AsyncThrowingStream` 变成异步序列，RelayHandler 逐事件消费、逐帧转换、逐帧推送给 Codex。不缓冲整个响应。

### 单文件带来的长函数

`RelayHandler.swift` 约 800 行，`handleStream()` 是其中最长的函数。这是有意为之——整个流式流程是线性叙事（创建 → 逐帧 → 完成），拆成小函数反而让状态机更难跟踪。所有私有辅助方法作为 `private static` 挂在类上，便于测试。

---

## 数据流

### 状态管理

`RelayState` 是**唯一的状态中心**，使用 `@MainActor` 保证 UI 线程安全：

```
User Action                    RelayState                     Side Effects
──────────                    ──────────                     ────────────
输入 API Key  ──→ saveApiKey(key)  ──→ apiKey = key (didSet 存)
                                        client?.apiKey = key
                                        Task: fetchModels()
                                          └─ 拉取成功 → 存 UserDefaults
                                             (不写配置、不动 asar)

选择模型    ──→ selectModel(id)   ──→ model = id (didSet 存)
                                        codexEnabled = true
                                        syncCodexConfig() → enable()
                                        ├─ 写 config.toml
                                        ├─ 写 irelay-models.json
                                        └─ 备份+修补 app.asar

切换思考    ──→ toggleThinking()   ──→ thinkingEnabled = !... (didSet 存)
                                        handler?.thinking = ...

关闭 iRelay ──→ disableCodex()    ──→ codexEnabled = false (didSet 存)
                                        codexConfigManager.disable()
                                        ├─ 恢复 app.asar → 删备份
                                        ├─ 清 config.toml 中 iRelay 配置
                                        └─ 删 irelay-models.json

退出 App    ──→ turnOff()         ──→ stopServer()
```

### 持久化

| 存储位置 | 内容 | 读写时机 |
|---|---|---|
| `UserDefaults` | apiKey / model / thinking / codexEnabled / models | 状态变化时存，`init()` 读 |
| `~/.codex/config.toml` | Codex 中继配置 | 配 Key / 切模型时写，关模型时清 |
| `~/.codex/irelay-models.json` | Codex 静态模型目录 | 配 Key / 切模型时写，关模型时删 |
| `/Applications/Codex.app/Contents/Resources/app.asar` | Codex 桌面 App 前端包 | 配 Key / 切模型时备份+补丁，关模型时恢复 |
| `~/.config/irelay/irelay.log` | 运行日志 | 每行日志异步追加 |

---

## 文件清单

```
Sources/iRelay/
├── iRelayApp.swift          # @main 入口，MenuBarExtra，API Key 配置窗口
├── MenuBarView.swift        # 菜单栏 UI 视图
├── Models/
│   ├── RelayState.swift     # 全局状态管理（~200 行）
│   └── RelayConfig.swift    # ModelInfo 数据模型（~8 行）
├── Services/
│   ├── CodexConfigManager.swift  # TOML 配置读写器（~125 行）
│   ├── CodexAppPatcher.swift     # Codex 桌面 App 白名单补丁器
│   └── Logger.swift              # 异步文件日志（~53 行）
└── Core/
    ├── HTTPServer.swift     # 零依赖 HTTP/1.1 服务器（~215 行）
    ├── RelayHandler.swift   # 协议转换引擎（~800 行）
    └── DeepSeekClient.swift # DeepSeek API 客户端（~113 行）
```

总计约 **1600 行 Swift**。

---

### 5. SSE 事件协议对比

与 OpenAI Responses API 的 SSE 事件集对比，iRelay 支持以下事件（✓ = 支持，— = 不适用）：

| 事件 | iRelay | 说明 |
|------|:------:|------|
| `response.created` | ✓ | |
| `response.output_item.added` | ✓ | |
| `response.output_item.done` | ✓ | |
| `response.content_part.added` | ✓ | |
| `response.content_part.done` | ✓ | |
| `response.output_text.delta` / `.done` | ✓ | |
| `response.reasoning_text.delta` / `.done` | ✓ | |
| `response.function_call_arguments.delta` / `.done` | ✓ | |
| `response.completed` | ✓ | 不含 `end_turn`（Codex 默认 `None`，有 fallback） |
| `response.failed` | ✓ | |
| `response.metadata` | — | 携带 turn state / model verification，非必需 |
| `response.incomplete` | — | DeepSeek 不产生此事件 |
| `response.reasoning_summary_text.delta` | — | DeepSeek 不支持 reasoning summary |
| `response.reasoning_summary_part.added` | — | 同上 |
| `response.custom_tool_call_input.delta` | — | DeepSeek 不支持 custom tools |

### 6. 未使用的 Responses API 参数

以下参数 Codex 在 POST `/v1/responses` 中可能发送，但 iRelay 未转发给 DeepSeek（DeepSeek Chat API 不支持）：

| 参数 | 原因 |
|---|---|
| `tool_choice` | DeepSeek 只支持隐式 `auto` |
| `parallel_tool_calls` | Codex 可并行调工具，但 DeepSeek 无对应参数 |
| `text` (verbosity / format) | DeepSeek 不支持输出格式控制 |
| `previous_response_id` | 仅 Responses WebSocket 增量协议需要，iRelay 走独立 HTTP POST |
| `include` | DeepSeek 无 reasoning.encrypted_content 概念 |

## 限制 & 注意事项

1. **API Key 明文存储** — 存在 `UserDefaults` 而非钥匙串，任何能读 `com.xdf.irelay.plist` 的进程都能拿到
2. **HTTP 请求解析有限** — 不支持 `Transfer-Encoding: chunked`、`Upgrade` 等，但 Codex 目前用不到
3. **单请求队列** — 每个 `/v1/responses` 独立发起上游请求，没有连接池或请求排队
4. **端口硬编码 8787** — 不可配置，冲突时启动失败
5. **Codex App 补丁依赖前端 bundle 字符串** — Codex App 更新后如果过滤表达式变化，补丁会记录 `pattern_not_found`，需要更新匹配模式
6. **日志无轮转** — 日志文件持续增长，需要手动清理

## 协议适配历史

### 2026-06-15：修复 `collectFunctionCalls` 字段路径

**问题**：`collectFunctionCalls()` 读取 `item["function"]["name"]`，但 Responses API 的 `function_call` item 中 `name` 和 `arguments` 是**顶层字段**而非嵌套在 `function` 对象里。

**影响**：每次请求中包含历史工具调用时（典型场景：Read 文件 → 编辑文件），DeepSeek 收到空工具名，导致"工具不可用"错误。

**修复**：改为优先读 `item["name"]` / `item["arguments"]`，兼容回退 `item["function"]["name"]`。

---

## 本地开发

```bash
# 构建
./build.sh

# 产物在 iRelay.app
# 日志在 ~/.config/irelay/irelay.log
```
