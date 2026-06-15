# iRelay API 文档

> 版本 2.1.0 · 基础 URL: `http://localhost:8787`

iRelay 是一个运行在 macOS 菜单栏的中继代理，将 Codex 的 Responses API 转换为 DeepSeek 的 Chat Completions API，同时提供 Chat Completions 直通接口。

---

## 端点一览

| 方法 | 路径 | 说明 |
|------|------|------|
| `GET` | `/health` | 健康检查 |
| `GET` | `/v1/models` | 获取模型列表（透传 DeepSeek） |
| `POST` | `/v1/responses` | Responses → Chat 协议转换（流式/非流式） |
| `POST` | `/v1/chat/completions` | Chat Completions 直通透传（流式/非流式） |

所有请求的 Content-Type 均为 `application/json`（除 `/health` 外）。

---

## GET /health

健康检查。服务正常时返回 `200 OK`。

### 响应示例

```json
{
    "ok": true
}
```

---

## GET /v1/models

透传 DeepSeek 的 `/v1/models` 接口，返回可用模型列表。需要 `Authorization: Bearer <api-key>` 请求头。

### 请求

```http
GET /v1/models
Authorization: Bearer sk-xxxxxxxxxxxxxxxx
```

### 响应

透传 DeepSeek 原始响应，格式为：

```json
{
    "object": "list",
    "data": [
        {
            "id": "deepseek-v4-pro",
            "object": "model",
            "created": 1700000000,
            "owned_by": "deepseek"
        }
    ]
}
```

---

## POST /v1/responses

**协议转换端点。** 接收 Codex 的 Responses API 请求体，内部转换为 Chat Completions API 调用 DeepSeek，再将 DeepSeek 响应转换回 Responses API 格式。

这是 iRelay 的核心端点，支持流式 SSE 和非流式 JSON 两种模式。

### 请求体

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `model` | string | 是 | 模型 ID（如 `deepseek-v4-pro`） |
| `input` | string / array | 是 | 输入内容，见下方 Input 格式 |
| `instructions` | string | 否 | 系统指令，映射为 Chat 的 system message |
| `stream` | bool | 否 | 是否流式输出，默认 `false` |
| `tools` | array | 否 | 工具定义 |
| `tool_choice` | string / object | 否 | 工具选择策略（DeepSeek 不支持） |
| `parallel_tool_calls` | bool | 否 | 是否并行调用工具 |
| `temperature` | number | 否 | 采样温度 |
| `top_p` | number | 否 | 核采样参数 |
| `max_output_tokens` | number | 否 | 最大输出 token 数 |
| `reasoning.effort` | string | 否 | 推理努力程度（DeepSeek 模式） |

#### Input 格式

支持字符串或数组两种形式：

**字符串形式：**
```json
{"input": "你好，请介绍一下你自己"}
```

**数组形式（每条是一个 input_item）：**

| type | 说明 | 关键字段 |
|------|------|----------|
| `message` | 普通消息 | `role` (user/assistant), `content` |
| `input_text` | 用户文本 | `text` |
| `function_call` | 工具调用 | `name`, `arguments`, `call_id` |
| `function_call_output` | 工具调用结果 | `call_id`, `output` |
| `reasoning` | 推理内容 | `content` |

#### 工具定义

```json
{
    "tools": [{
        "type": "function",
        "name": "edit_file",
        "description": "编辑文件内容",
        "parameters": {
            "type": "object",
            "properties": {
                "path": { "type": "string" },
                "content": { "type": "string" }
            },
            "required": ["path", "content"]
        }
    }]
}
```

### 非流式响应

`stream: false` 时返回 `200 OK` JSON。

```json
{
    "id": "resp_ab12cd34ef56...",
    "object": "response",
    "status": "completed",
    "model": "deepseek-v4-pro",
    "output": [
        {
            "id": "rs_fe23dc...",
            "type": "reasoning",
            "status": "completed",
            "content": [{
                "type": "reasoning_text",
                "text": "用户想了解我的身份，我需要...",
                "annotations": []
            }]
        },
        {
            "id": "msg_78ab90...",
            "type": "message",
            "status": "completed",
            "role": "assistant",
            "content": [{
                "type": "output_text",
                "text": "你好！我是 DeepSeek，一个 AI 助手...",
                "annotations": []
            }]
        }
    ],
    "output_text": "你好！我是 DeepSeek，一个 AI 助手...",
    "usage": {
        "input_tokens": 25,
        "output_tokens": 120,
        "total_tokens": 145,
        "input_tokens_details": { "cached_tokens": 0 },
        "output_tokens_details": { "reasoning_tokens": 30 }
    }
}
```

`output` 数组包含推理（reasoning）、消息（message）、函数调用（function_call）等类型的 item 对象。

### 流式响应

`stream: true` 时返回 `text/event-stream` SSE 流，包含以下事件：

| 事件 | 说明 |
|------|------|
| `response.created` | 流开始 |
| `response.metadata` | 元数据（turn state / model） |
| `response.output_item.added` | 新 item 开始（reasoning / message / function_call） |
| `response.content_part.added` | 新内容片段开始 |
| `response.reasoning_text.delta` | 推理文本增量（DeepSeek 特有） |
| `response.reasoning_text.done` | 推理文本结束 |
| `response.output_text.delta` | 输出文本增量 |
| `response.output_text.done` | 输出文本结束 |
| `response.function_call_arguments.delta` | 工具调用参数增量 |
| `response.function_call_arguments.done` | 工具调用参数结束 |
| `response.content_part.done` | 内容片段完成 |
| `response.output_item.done` | item 完成 |
| `response.completed` | 流结束，含 `usage` + `end_turn` |
| `response.failed` | 异常结束 |

SSE 格式示例：

```
event: response.created
data: {"type":"response.created","response":{"id":"resp_...","status":"in_progress","model":"deepseek-v4-pro","output":[]}}

event: response.output_text.delta
data: {"type":"response.output_text.delta","item_id":"msg_...","output_index":0,"content_index":0,"delta":"你好"}

event: response.completed
data: {"type":"response.completed","response":{"id":"resp_...","status":"completed","output":[...],"usage":{...}}}
```

---

## POST /v1/chat/completions

**直通透传端点。** 接收标准 OpenAI Chat Completions API 请求体，直接转发给 DeepSeek，返回原生响应。不做任何协议转换。

支持 `stream: true`（流式 SSE）和 `stream: false`（JSON）两种模式。

### 请求体

标准 Chat Completions API 格式：

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `model` | string | 是 | 模型 ID |
| `messages` | array | 是 | 消息列表 |
| `stream` | bool | 否 | 是否流式 |
| `temperature` | number | 否 | 采样温度 |
| `top_p` | number | 否 | 核采样参数 |
| `max_tokens` | number | 否 | 最大输出 token |
| `tools` | array | 否 | 工具定义 |
| `tool_choice` | string | 否 | 工具选择 |
| `thinking` | object | 否 | DeepSeek 推理模式（`{"type":"enabled"}`） |

### 请求示例

```json
{
    "model": "deepseek-v4-pro",
    "messages": [
        {"role": "system", "content": "你是 DeepSeek，一个 AI 助手。"},
        {"role": "user", "content": "你好"}
    ],
    "stream": false
}
```

### 非流式响应

返回 DeepSeek 原生 Chat Completions 响应：

```json
{
    "id": "chatcmpl-...",
    "object": "chat.completion",
    "created": 1700000000,
    "model": "deepseek-v4-pro",
    "choices": [{
        "index": 0,
        "message": {
            "role": "assistant",
            "content": "你好！我是 DeepSeek，很高兴为你服务！"
        },
        "finish_reason": "stop"
    }],
    "usage": {
        "prompt_tokens": 25,
        "completion_tokens": 120,
        "total_tokens": 145
    }
}
```

### 流式响应

`stream: true` 时返回标准 SSE 流，每行 `data: {...}` 格式，以 `data: [DONE]` 结束：

```
data: {"id":"chatcmpl-...","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

data: {"id":"chatcmpl-...","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"你好"},"finish_reason":null}]}

data: {"id":"chatcmpl-...","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"！我是 DeepSeek"},"finish_reason":null}]}

data: [DONE]
```

---

## 错误响应

所有端点统一使用 HTTP 状态码 + JSON 错误体：

```json
{
    "error": "错误描述信息"
}
```

| 状态码 | 含义 |
|--------|------|
| 400 | 请求体 JSON 格式错误 |
| 404 | 路径不存在 |
| 413 | 请求体超过 20MB |
| 502 | 上游 DeepSeek API 调用失败 |
| 504 | 上游请求超时（120s） |

---

## 与 Codex 配合使用

在 Codex 的 `~/.codex/config.toml` 中配置：

```toml
model_provider = "iRelay"
model = "deepseek-v4-pro"
model_catalog_json = "/Users/xxx/.codex/irelay-models.json"
```

iRelay 会自动管理这份配置。启动 iRelay 后，Codex 通过 `POST /v1/responses` 与 iRelay 通信。

如果已有标准 OpenAI SDK 或工具，也可以直接通过 `POST /v1/chat/completions` 使用，端口 `8787`，无需额外配置。

---

## 限制

1. 不支持 `Transfer-Encoding: chunked`（HTTP 解析受限）
2. 单请求队列，无连接池
3. 不支持 WebSocket 端点
4. API Key 明文存储于 UserDefaults，非钥匙串
