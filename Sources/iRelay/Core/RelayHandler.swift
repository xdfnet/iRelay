import Foundation

// MARK: - 类型别名

typealias JSON = [String: Any]

// MARK: - RelayHandler

final class RelayHandler {
    let client: ChatClient
    var provider: ProviderConfig

    init(client: ChatClient, provider: ProviderConfig) {
        self.client = client
        self.provider = provider
    }

    func register(on server: HTTPServer) {
        server.on("GET", "/health") { _, conn in
            conn.sendJSON(status: 200, body: ["ok": true])
        }
        server.on("GET", "/v1/models") { [weak self] _, conn in
            guard let self else { return }
            Task {
                let url = self.client.baseURL.appendingPathComponent("/v1/models")
                var req = URLRequest(url: url)
                req.setValue("Bearer \(self.client.apiKey)", forHTTPHeaderField: "Authorization")
                guard let (data, resp) = try? await URLSession.shared.data(for: req),
                      let httpResp = resp as? HTTPURLResponse,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    conn.sendJSON(status: 502, body: ["error": "upstream fetch failed"])
                    return
                }
                conn.sendJSON(status: httpResp.statusCode, body: json)
            }
        }
        server.on("POST", "/v1/responses") { [weak self] req, conn in
            self?.handleResponses(req: req, conn: conn)
        }
    }

    // MARK: - /v1/responses 主处理

    private func handleResponses(req: HTTPRequest, conn: ServerConnection) {
        guard let body = try? JSONSerialization.jsonObject(with: req.body) as? JSON else {
            conn.sendJSON(status: 400, body: ["error": "invalid JSON"])
            return
        }

        let model = body["model"] as? String ?? (UserDefaults.standard.string(forKey: "irelay_model") ?? "deepseek-v4-pro")
        let stream = body["stream"] as? Bool ?? false
        let tools = body["tools"] as? [JSON] ?? []
        let instructions = body["instructions"] as? String ?? ""
        let maxTokens = body["max_output_tokens"] as? Int ?? 0
        let start = Date()

        Log.info("codex_request",
            "model", model,
            "stream", stream,
            "tools", tools.count,
            "input", Log.summaryInput(body["input"]),
            "instructions", instructions.isEmpty ? "" : Log.summaryInput(instructions),
            "max_tokens", maxTokens)

        guard let payload = Self.responsesToChatPayload(body, provider: provider) else {
            Log.error("request_parse_failed", "model", model, "duration_ms", Log.msSince(start))
            conn.sendJSON(status: 400, body: ["error": "invalid request format"])
            return
        }

        if stream {
            handleStream(conn: conn, payload: payload, model: model, start: start)
        } else {
            handleNonStream(conn: conn, payload: payload, model: model, start: start)
        }
    }

    // MARK: - 非流式

    private func handleNonStream(conn: ServerConnection, payload: JSON, model: String, start: Date) {
        Task {
            do {
                let (chat, status) = try await client.chat(payload: payload)
                let dur = Log.msSince(start)
                guard (200...299).contains(status) else {
                    let errMsg = (chat["error"] as? JSON)?["message"] as? String ?? "upstream_error"
                    Log.error("upstream_status_error", "model", model, "status", status, "error", errMsg, "duration_ms", dur)
                    conn.sendJSON(status: 502, body: chat)
                    Log.end()
                    return
                }
                let resp = Self.chatCompletionToResponse(chat, model: model, provider: provider)
                let usage = resp["usage"] as? JSON ?? [:]
                let outputText = resp["output_text"] as? String ?? ""
                Log.info("response",
                    "stream", false,
                    "model", model,
                    "output_text", outputText,
                    "input_tokens", usage["input_tokens"] ?? 0,
                    "output_tokens", usage["output_tokens"] ?? 0,
                    "duration_ms", dur)
                conn.sendJSON(status: 200, body: resp)
                Log.end()
            } catch {
                Log.error("upstream_error", "model", model, "error", error.localizedDescription, "duration_ms", Log.msSince(start))
                conn.sendJSON(status: 502, body: ["error": error.localizedDescription])
                Log.end()
            }
        }
    }

    // MARK: - 流式

    private func handleStream(conn: ServerConnection, payload: JSON, model: String, start: Date) {
        conn.startSSE()

        let responseID = "resp_" + randomID()

        // response.created
        conn.sendSSEJSON(event: "response.created", json: [
            "type": "response.created",
            "response": [
                "id": responseID,
                "object": "response",
                "status": "in_progress",
                "model": model,
                "output": []
            ] as JSON
        ])

        Task {
            var messageID = ""
            var messageOutputIndex = -1
            var textStarted = false
            var accumulated = ""

            var rsID = ""
            var rsOutputIndex = 0
            var rsContent = ""
            var rsStarted = false

            var toolCalls: [Int: StreamToolCall] = [:]
            var nextOutputIndex = 0
            var upstreamModel = model
            var lastUsage: JSON?
            var outputItems: [Int: JSON] = [:]

            let stream = client.chatStream(payload: payload)

            do {
                for try await event in stream {
                    if let m = event["model"] as? String { upstreamModel = m }
                    if let u = event["usage"] as? JSON { lastUsage = u }

                    guard let delta = Self.firstChoiceDelta(event) else { continue }

                    // reasoning_content delta
                    if provider.supportsThinking, let reasoningText = delta[provider.reasoningField] as? String, !reasoningText.isEmpty {
                        if !rsStarted {
                            rsStarted = true
                            rsID = "rs_" + randomID()
                            rsOutputIndex = nextOutputIndex
                            nextOutputIndex += 1

                            conn.sendSSEJSON(event: "response.output_item.added", json: [
                                "type": "response.output_item.added",
                                "output_index": rsOutputIndex,
                                "item": [
                                    "id": rsID,
                                    "type": "reasoning",
                                    "status": "in_progress",
                                    "content": []
                                ] as JSON
                            ])
                            conn.sendSSEJSON(event: "response.content_part.added", json: [
                                "type": "response.content_part.added",
                                "item_id": rsID,
                                "output_index": rsOutputIndex,
                                "content_index": 0,
                                "part": [
                                    "type": "reasoning_text",
                                    "text": "",
                                    "annotations": []
                                ] as JSON
                            ])
                        }
                        rsContent += reasoningText
                        conn.sendSSEJSON(event: "response.reasoning_text.delta", json: [
                            "type": "response.reasoning_text.delta",
                            "item_id": rsID,
                            "output_index": rsOutputIndex,
                            "content_index": 0,
                            "delta": reasoningText
                        ])
                    }

                    // content delta
                    if let text = delta["content"] as? String, !text.isEmpty {
                        if !textStarted {
                    if provider.supportsThinking && rsStarted {
                                Self.finalizeReasoning(conn: conn, rsID: rsID, rsOutputIndex: rsOutputIndex, rsContent: rsContent, outputItems: &outputItems)
                                rsStarted = false
                            }
                            textStarted = true
                            messageID = "msg_" + randomID()
                            messageOutputIndex = nextOutputIndex
                            nextOutputIndex += 1

                            conn.sendSSEJSON(event: "response.output_item.added", json: [
                                "type": "response.output_item.added",
                                "output_index": messageOutputIndex,
                                "item": [
                                    "id": messageID,
                                    "type": "message",
                                    "status": "in_progress",
                                    "role": "assistant",
                                    "content": []
                                ] as JSON
                            ])
                            conn.sendSSEJSON(event: "response.content_part.added", json: [
                                "type": "response.content_part.added",
                                "item_id": messageID,
                                "output_index": messageOutputIndex,
                                "content_index": 0,
                                "part": [
                                    "type": "output_text",
                                    "text": "",
                                    "annotations": []
                                ] as JSON
                            ])
                        }
                        accumulated += text
                        conn.sendSSEJSON(event: "response.output_text.delta", json: [
                            "type": "response.output_text.delta",
                            "item_id": messageID,
                            "output_index": messageOutputIndex,
                            "content_index": 0,
                            "delta": text
                        ])
                    }

                    // tool_calls delta
                    for call in streamToolDeltas(delta) {
                        if toolCalls[call.index] == nil {
                            let itemID = call.id.isEmpty ? "call_" + randomID() : call.id
                            toolCalls[call.index] = StreamToolCall(
                                id: itemID,
                                callID: itemID,
                                outputIndex: nextOutputIndex,
                                name: call.name
                            )
                            nextOutputIndex += 1
                            conn.sendSSEJSON(event: "response.output_item.added", json: [
                                "type": "response.output_item.added",
                                "output_index": toolCalls[call.index]!.outputIndex,
                                "item": [
                                    "id": itemID,
                                    "type": "function_call",
                                    "status": "in_progress",
                                    "call_id": itemID,
                                    "name": call.name,
                                    "arguments": ""
                                ] as JSON
                            ])
                        }
                        if let current = toolCalls[call.index] {
                            if !call.id.isEmpty { toolCalls[call.index]?.callID = call.id }
                            if !call.name.isEmpty { toolCalls[call.index]?.name = call.name }
                            if !call.arguments.isEmpty {
                                toolCalls[call.index]?.arguments += call.arguments
                                conn.sendSSEJSON(event: "response.function_call_arguments.delta", json: [
                                    "type": "response.function_call_arguments.delta",
                                    "item_id": current.id,
                                    "output_index": current.outputIndex,
                                    "delta": call.arguments
                                ])
                            }
                        }
                    }
                }
            } catch {
                Log.error("stream_upstream_error", "model", model, "error", error.localizedDescription, "duration_ms", Log.msSince(start))
                conn.sendSSEJSONAndClose(event: "response.failed", json: [
                    "type": "response.failed",
                    "response": [
                        "id": responseID,
                        "status": "failed",
                        "error": ["message": error.localizedDescription]
                    ] as JSON
                ])
                Log.end()
                return
            }

            // ---- 以下是正常完成流程 ----

            // 完成处理
            if provider.supportsThinking && rsStarted {
                Self.finalizeReasoning(conn: conn, rsID: rsID, rsOutputIndex: rsOutputIndex, rsContent: rsContent, outputItems: &outputItems)
            }

            if textStarted {
                let msgItem: JSON = [
                    "id": messageID,
                    "type": "message",
                    "status": "completed",
                    "role": "assistant",
                    "content": [[
                        "type": "output_text",
                        "text": accumulated,
                        "annotations": []
                    ] as JSON]
                ]
                conn.sendSSEJSON(event: "response.output_text.done", json: [
                    "type": "response.output_text.done",
                    "item_id": messageID,
                    "output_index": messageOutputIndex,
                    "content_index": 0,
                    "text": accumulated
                ])
                conn.sendSSEJSON(event: "response.content_part.done", json: [
                    "type": "response.content_part.done",
                    "item_id": messageID,
                    "output_index": messageOutputIndex,
                    "content_index": 0,
                    "part": (msgItem["content"] as! [JSON])[0]
                ])
                conn.sendSSEJSON(event: "response.output_item.done", json: [
                    "type": "response.output_item.done",
                    "output_index": messageOutputIndex,
                    "item": msgItem
                ])
                outputItems[messageOutputIndex] = msgItem
            }

            // Finalize tool calls
            for call in sortedToolCalls(toolCalls) {
                conn.sendSSEJSON(event: "response.function_call_arguments.done", json: [
                    "type": "response.function_call_arguments.done",
                    "call_id": call.callID,
                    "item_id": call.id,
                    "name": call.name,
                    "output_index": call.outputIndex,
                    "arguments": call.arguments
                ])
                let callItem: JSON = [
                    "id": call.id,
                    "type": "function_call",
                    "status": "completed",
                    "call_id": call.callID,
                    "name": call.name,
                    "arguments": call.arguments
                ]
                conn.sendSSEJSON(event: "response.output_item.done", json: [
                    "type": "response.output_item.done",
                    "output_index": call.outputIndex,
                    "item": callItem
                ])
                outputItems[call.outputIndex] = callItem
            }

            // response.completed
            let turnID = "turn_" + randomID()
            let turnOutputIndex = nextOutputIndex
            nextOutputIndex += 1
            let turnItem: JSON = [
                "id": turnID,
                "type": "end_turn",
                "status": "completed"
            ]
            conn.sendSSEJSON(event: "response.output_item.added", json: [
                "type": "response.output_item.added",
                "output_index": turnOutputIndex,
                "item": turnItem
            ])
            conn.sendSSEJSON(event: "response.output_item.done", json: [
                "type": "response.output_item.done",
                "output_index": turnOutputIndex,
                "item": turnItem
            ])
            outputItems[turnOutputIndex] = turnItem

            let output = sortedOutputItems(outputItems)
            var completed: JSON = [
                "type": "response.completed",
                "response": [
                    "id": responseID,
                    "object": "response",
                    "status": "completed",
                    "model": upstreamModel,
                    "output": output,
                    "output_text": accumulated,
                    "end_turn": true
                ] as JSON
            ]
            if let usage = lastUsage {
                completed["response"] = (completed["response"] as! JSON).merging([
                    "usage": [
                        "input_tokens": usage["prompt_tokens"] ?? 0,
                        "output_tokens": usage["completion_tokens"] ?? 0,
                        "total_tokens": usage["total_tokens"] ?? 0
                    ]
                ]) { $1 }
            }
            let dur = Log.msSince(start)
            let inTokens = upstreamModel.isEmpty ? 0 : (lastUsage?["prompt_tokens"] as? Int ?? 0)
            let outTokens = upstreamModel.isEmpty ? 0 : (lastUsage?["completion_tokens"] as? Int ?? 0)
            Log.info("response",
                "stream", true,
                "model", upstreamModel,
                "output_text", accumulated,
                "tools", toolCalls.count,
                "input_tokens", inTokens,
                "output_tokens", outTokens,
                "duration_ms", dur)
            conn.sendSSEJSONAndClose(event: "response.completed", json: completed)
            Log.end()
        }
    }

    // MARK: - 转换逻辑（移植自 Go responses.go）

    /// Codex Responses 请求 → Chat API 请求
    static func responsesToChatPayload(_ body: JSON, provider: ProviderConfig) -> JSON? {
        let instructions = body["instructions"] as? String ?? ""
        let rawInput = body["input"]
        let tools = body["tools"] as? [JSON] ?? []
        let temp = body["temperature"] as? Double
        let topP = body["top_p"] as? Double
        let maxTokens = body["max_output_tokens"] as? Int
        let model = body["model"] as? String ?? (UserDefaults.standard.string(forKey: "irelay_model") ?? "deepseek-v4-pro")
        let stream = body["stream"] as? Bool ?? false

        guard let messages = parseInput(instructions: instructions, input: rawInput) else {
            return nil
        }

        let reordered = ensureToolAfterAssistant(messages)

        var payload: JSON = [
            "model": model,
            "messages": reordered
        ]
        if let t = temp { payload["temperature"] = t }
        if let p = topP { payload["top_p"] = p }
        if let m = maxTokens { payload["max_tokens"] = m }
        if !tools.isEmpty { payload["tools"] = convertTools(tools) }
        if provider.supportsToolChoice, let toolChoice = body["tool_choice"] {
            payload["tool_choice"] = toolChoice
        }
        if let parallel = body["parallel_tool_calls"] as? Bool {
            payload["parallel_tool_calls"] = parallel
        }
        if stream {
            payload["stream"] = true
            payload["stream_options"] = ["include_usage": true] as JSON
        }

        switch provider.thinkingMode {
        case .deepseekStyle:
            payload["thinking"] = ["type": "enabled"] as JSON
        case .none:
            break
        }

        return payload
    }

    /// Chat Completion 响应 → Codex Responses 格式
    static func chatCompletionToResponse(_ chat: JSON, model: String, provider: ProviderConfig) -> JSON {
        let message = firstChoiceMessage(chat)
        let text = message["content"] as? String ?? ""
        let modelName = chat["model"] as? String ?? model

        var output: [JSON] = []

        if provider.supportsThinking, let reasoning = message[provider.reasoningField] as? String, !reasoning.isEmpty {
            output.append([
                "id": "rs_" + randomID(),
                "type": "reasoning",
                "status": "completed",
                "content": [[
                    "type": "reasoning_text",
                    "text": reasoning,
                    "annotations": []
                ] as JSON]
            ])
        }

        if !text.isEmpty {
            output.append([
                "id": "msg_" + randomID(),
                "type": "message",
                "status": "completed",
                "role": "assistant",
                "content": [[
                    "type": "output_text",
                    "text": text,
                    "annotations": []
                ] as JSON]
            ])
        }

        if let calls = message["tool_calls"] as? [JSON] {
            for call in calls {
                let fn = call["function"] as? JSON ?? [:]
                let callID = call["id"] as? String ?? "call_" + randomID()
                output.append([
                    "id": callID,
                    "type": "function_call",
                    "status": "completed",
                    "call_id": callID,
                    "name": fn["name"] as? String ?? "",
                    "arguments": fn["arguments"] as? String ?? "{}"
                ])
            }
        }

        var response: JSON = [
            "id": "resp_" + randomID(),
            "object": "response",
            "status": "completed",
            "model": modelName,
            "output": output,
            "output_text": text
        ]

        if let usage = chat["usage"] as? JSON {
            response["usage"] = [
                "input_tokens": usage["prompt_tokens"] ?? 0,
                "output_tokens": usage["completion_tokens"] ?? 0,
                "total_tokens": usage["total_tokens"] ?? 0
            ] as JSON
        }

        return response
    }

    // MARK: - 输入解析

    /// 解析 instructions + input 为 chat messages
    private static func parseInput(instructions: String, input: Any?) -> [JSON]? {
        var messages: [JSON] = []

        if !instructions.isEmpty {
            messages.append(["role": "system", "content": instructions])
        }

        guard let input = input else { return nil }

        if let text = input as? String {
            messages.append(["role": "user", "content": text])
            return messages
        }

        guard let items = input as? [JSON] else { return nil }

        var i = 0
        var pendingReasoning = ""

        while i < items.count {
            let item = items[i]
            let type = item["type"] as? String ?? ""

            if type == "function_call" {
                let (calls, consumed) = collectFunctionCalls(items, start: i)
                i += consumed
                if let last = messages.last, last["role"] as? String == "assistant" {
                    var existingTCs = last["tool_calls"] as? [JSON] ?? []
                    existingTCs.append(contentsOf: calls)
                    messages[messages.count - 1]["tool_calls"] = existingTCs
                } else {
                    messages.append(["role": "assistant", "tool_calls": calls])
                }
                continue
            }

            if type == "reasoning" {
                i += 1
                if let content = contentToText(item["content"]), !content.isEmpty {
                    if !pendingReasoning.isEmpty { pendingReasoning += "\n" }
                    pendingReasoning += content
                }
                continue
            }

            i += 1
            if let (msg, ok) = responseItemToMessage(item), ok {
                if !pendingReasoning.isEmpty, msg["role"] as? String == "assistant" {
                    var m = msg
                    m["reasoning_content"] = pendingReasoning
                    messages.append(m)
                    pendingReasoning = ""
                } else {
                    messages.append(msg)
                }
            }
        }

        return messages
    }

    private static func collectFunctionCalls(_ items: [JSON], start: Int) -> (calls: [JSON], consumed: Int) {
        var calls: [JSON] = []
        var i = start
        while i < items.count {
            let item = items[i]
            guard item["type"] as? String == "function_call" else { break }
            let callID = (item["call_id"] as? String) ?? (item["id"] as? String) ?? "call_" + randomID()
            let name = item["name"] as? String ?? (item["function"] as? JSON)?["name"] as? String ?? ""
            let arguments = item["arguments"] as? String ?? (item["function"] as? JSON)?["arguments"] as? String ?? "{}"
            calls.append([
                "id": callID,
                "type": "function",
                "function": [
                    "name": name,
                    "arguments": arguments
                ] as JSON
            ])
            i += 1
        }
        return (calls, i - start)
    }

    private static func responseItemToMessage(_ item: JSON) -> (JSON, Bool)? {
        let type = item["type"] as? String ?? ""
        let role = normalizeRole(item["role"] as? String ?? "")

        if type == "function_call_output" {
            return (["role": "tool", "tool_call_id": item["call_id"] as? String ?? "", "content": contentToText(item["output"]) ?? ""], true)
        }

        if type == "input_text" {
            return (["role": "user", "content": item["text"] as? String ?? ""], true)
        }

        if let content = item["content"] {
            let r = role.isEmpty ? "user" : role
            return (["role": r, "content": contentToText(content) ?? ""], true)
        }

        if let text = item["text"] as? String, !text.isEmpty {
            let r = role.isEmpty ? "user" : role
            return (["role": r, "content": text], true)
        }

        return nil
    }

    private static func normalizeRole(_ role: String) -> String {
        switch role {
        case "assistant", "system", "tool": return role
        case "developer": return "system"
        default: return "user"
        }
    }

    private static func contentToText(_ content: Any?) -> String? {
        guard let content else { return nil }
        if let text = content as? String { return text }
        if let items = content as? [Any] {
            let parts = items.compactMap { item -> String? in
                if let s = item as? String { return s }
                if let dict = item as? JSON {
                    let t = dict["type"] as? String ?? ""
                    let validTypes = ["input_text", "output_text", "text", "reasoning_text"]
                    guard validTypes.contains(t) else { return nil }
                    return dict["text"] as? String
                }
                return nil
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        return nil
    }

    private static func ensureToolAfterAssistant(_ messages: [JSON]) -> [JSON] {
        var result: [JSON] = []
        var i = 0
        while i < messages.count {
            let msg = messages[i]
            if msg["role"] as? String == "assistant", let tcs = msg["tool_calls"] as? [JSON], !tcs.isEmpty {
                var expectedIDs = Set(tcs.compactMap { $0["id"] as? String })
                var toolMsgs: [JSON] = []
                var nonToolMsgs: [JSON] = []
                var j = i + 1
                while j < messages.count, !expectedIDs.isEmpty {
                    let nxt = messages[j]
                    if nxt["role"] as? String == "tool", let id = nxt["tool_call_id"] as? String, expectedIDs.contains(id) {
                        expectedIDs.remove(id)
                        toolMsgs.append(nxt)
                    } else if nxt["role"] as? String == "system" {
                        nonToolMsgs.append(nxt)
                    } else {
                        break
                    }
                    j += 1
                }
                result.append(contentsOf: nonToolMsgs)
                result.append(msg)
                result.append(contentsOf: toolMsgs)
                i = j
            } else {
                result.append(msg)
                i += 1
            }
        }
        return result
    }

    // MARK: - Helpers

    private static func convertTools(_ tools: [JSON]) -> [JSON] {
        tools.compactMap { tool in
            guard tool["type"] as? String == "function" else { return nil }
            let params = tool["parameters"] ?? ["type": "object", "properties": [:]] as JSON
            return [
                "type": "function",
                "function": [
                    "name": tool["name"] as? String ?? "",
                    "description": tool["description"] as? String ?? "",
                    "parameters": params
                ] as JSON
            ] as JSON
        }
    }

    private static func firstChoiceMessage(_ chat: JSON) -> JSON {
        (chat["choices"] as? [JSON])?.first?["message"] as? JSON ?? [:]
    }

    private static func firstChoiceDelta(_ event: JSON) -> JSON? {
        (event["choices"] as? [JSON])?.first?["delta"] as? JSON
    }

    private static func finalizeReasoning(conn: ServerConnection, rsID: String, rsOutputIndex: Int, rsContent: String, outputItems: inout [Int: JSON]) {
        conn.sendSSEJSON(event: "response.reasoning_text.done", json: [
            "type": "response.reasoning_text.done",
            "item_id": rsID,
            "output_index": rsOutputIndex,
            "content_index": 0,
            "text": rsContent
        ])
        conn.sendSSEJSON(event: "response.content_part.done", json: [
            "type": "response.content_part.done",
            "item_id": rsID,
            "output_index": rsOutputIndex,
            "content_index": 0,
            "part": ["type": "reasoning_text", "text": rsContent, "annotations": []] as JSON
        ])
        conn.sendSSEJSON(event: "response.output_item.done", json: [
            "type": "response.output_item.done",
            "output_index": rsOutputIndex,
            "item": [
                "id": rsID,
                "type": "reasoning",
                "status": "completed",
                "content": [[
                    "type": "reasoning_text",
                    "text": rsContent,
                    "annotations": []
                ] as JSON]
            ] as JSON
        ])
        outputItems[rsOutputIndex] = [
            "id": rsID,
            "type": "reasoning",
            "status": "completed",
            "content": [[
                "type": "reasoning_text",
                "text": rsContent,
                "annotations": []
            ] as JSON]
        ]
    }

}

// MARK: - 流式工具调用跟踪

private struct StreamToolCall {
    var id: String
    var callID: String
    var outputIndex: Int
    var name: String
    var arguments: String = ""
}

private struct ToolDelta {
    let index: Int
    let id: String
    let name: String
    let arguments: String
}

private func streamToolDeltas(_ delta: JSON) -> [ToolDelta] {
    guard let rawCalls = delta["tool_calls"] as? [JSON] else { return [] }
    return rawCalls.map { call in
        let fn = call["function"] as? JSON ?? [:]
        return ToolDelta(
            index: call["index"] as? Int ?? 0,
            id: call["id"] as? String ?? "",
            name: fn["name"] as? String ?? "",
            arguments: fn["arguments"] as? String ?? ""
        )
    }
}

private func sortedToolCalls(_ calls: [Int: StreamToolCall]) -> [StreamToolCall] {
    calls.values.sorted { $0.outputIndex < $1.outputIndex }
}

private func sortedOutputItems(_ items: [Int: JSON]) -> [JSON] {
    items.keys.sorted().compactMap { items[$0] }
}

/// Generate a hex random ID (compatible with Go's hex.EncodeToString)
private func randomID() -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return bytes.map { String(format: "%02x", $0) }.joined()
}
// Thu Jun  4 19:41:08 CST 2026
