import Testing
import Foundation
@testable import iRelayCore

// MARK: - 协议转换测试

@Test func testResponsesToChatPayloadBasic() {
    let body: JSON = [
        "model": "deepseek-v4-pro",
        "instructions": "You are a helpful assistant.",
        "input": "Hello!",
        "stream": true,
    ]
    let payload = RelayHandler.responsesToChatPayload(body, provider: .deepSeek)
    #expect(payload != nil)
    #expect(payload?["model"] as? String == "deepseek-v4-pro")
    #expect(payload?["stream"] as? Bool == true)

    let messages = payload?["messages"] as? [JSON]
    #expect(messages?.count == 2)
    #expect(messages?[0]["role"] as? String == "system")
    #expect(messages?[0]["content"] as? String == "You are a helpful assistant.")
    #expect(messages?[1]["role"] as? String == "user")
    #expect(messages?[1]["content"] as? String == "Hello!")
}

@Test func testResponsesToChatPayloadWithThinking() {
    let body: JSON = ["input": "Hi"]
    let payload = RelayHandler.responsesToChatPayload(body, provider: .deepSeek)
    #expect(payload?["thinking"] != nil)
}

@Test func testResponsesToChatPayloadWithoutThinking() {
    let body: JSON = ["input": "Hi"]
    var provider = ProviderConfig.deepSeek
    provider.thinkingMode = .none
    let payload = RelayHandler.responsesToChatPayload(body, provider: provider)
    #expect(payload?["thinking"] == nil)
}

@Test func testChatCompletionToResponse() {
    let chat: JSON = [
        "choices": [["message": ["role": "assistant", "content": "Hello world"]]],
        "model": "deepseek-v4-pro",
        "usage": ["prompt_tokens": 10, "completion_tokens": 20, "total_tokens": 30],
    ]
    let resp = RelayHandler.chatCompletionToResponse(chat, model: "deepseek-v4-pro", provider: .deepSeek)
    #expect(resp["object"] as? String == "response")
    #expect(resp["status"] as? String == "completed")
    #expect(resp["output_text"] as? String == "Hello world")
    let usage = resp["usage"] as? JSON
    #expect(usage?["input_tokens"] as? Int == 10)
    #expect(usage?["output_tokens"] as? Int == 20)
}

@Test func testChatCompletionToResponseWithToolCalls() {
    let chat: JSON = [
        "choices": [[
            "message": [
                "role": "assistant",
                "content": NSNull(),
                "tool_calls": [[
                    "id": "call_123",
                    "type": "function",
                    "function": ["name": "Edit", "arguments": "{\"file_path\":\"/test\"}"]
                ]]
            ] as JSON
        ]]
    ]
    let resp = RelayHandler.chatCompletionToResponse(chat, model: "deepseek", provider: .deepSeek)
    let output = resp["output"] as? [JSON]
    #expect(output?.count == 1)
    #expect(output?[0]["type"] as? String == "function_call")
    #expect(output?[0]["name"] as? String == "Edit")
    let args = output?[0]["arguments"] as? String
    #expect(args == "{\"file_path\":\"/test\"}")
}

@Test func testChatCompletionToResponseWithReasoning() {
    let chat: JSON = [
        "choices": [[
            "message": [
                "role": "assistant",
                "content": "Final answer",
                "reasoning_content": "Let me think..."
            ] as JSON
        ]]
    ]
    let resp = RelayHandler.chatCompletionToResponse(chat, model: "model", provider: .deepSeek)
    let output = resp["output"] as? [JSON]
    #expect(output?.count == 2)
    #expect(output?[0]["type"] as? String == "reasoning")
    #expect(output?[1]["type"] as? String == "message")
}

// MARK: - collectFunctionCalls（之前修过的 bug）

@Test func testCollectFunctionCallsResponsesFormat() {
    // Responses API 格式：name/arguments 在顶层
    let items: [JSON] = [
        ["type": "function_call", "id": "call_1", "call_id": "call_1", "name": "Edit", "arguments": "{\"x\":1}", "status": "completed"],
        ["type": "function_call", "id": "call_2", "call_id": "call_2", "name": "Read", "arguments": "{\"y\":2}", "status": "completed"],
    ]
    let (calls, consumed) = RelayHandler.collectFunctionCalls(items, start: 0)
    #expect(consumed == 2)
    #expect(calls.count == 2)
    let fn0 = calls[0]["function"] as? JSON
    #expect(fn0?["name"] as? String == "Edit")
    #expect(fn0?["arguments"] as? String == "{\"x\":1}")
    let fn1 = calls[1]["function"] as? JSON
    #expect(fn1?["name"] as? String == "Read")
    #expect(fn1?["arguments"] as? String == "{\"y\":2}")
}

@Test func testCollectFunctionCallsChatFormat() {
    // Chat API 格式（fallback）：name/arguments 在 function 内
    let items: [JSON] = [
        ["type": "function_call", "id": "call_1", "call_id": "call_1", "function": ["name": "Edit", "arguments": "{}"]],
    ]
    let (calls, consumed) = RelayHandler.collectFunctionCalls(items, start: 0)
    #expect(consumed == 1)
    let fn = calls[0]["function"] as? JSON
    #expect(fn?["name"] as? String == "Edit")
}

// MARK: - parseInput

@Test func testParseInputString() {
    let messages = RelayHandler.parseInput(instructions: "", input: "Hello")
    #expect(messages?.count == 1)
    #expect(messages?[0]["role"] as? String == "user")
    #expect(messages?[0]["content"] as? String == "Hello")
}

@Test func testParseInputWithInstructions() {
    let messages = RelayHandler.parseInput(instructions: "Be helpful", input: "Hi")
    #expect(messages?.count == 2)
}

@Test func testParseInputNull() {
    let messages = RelayHandler.parseInput(instructions: "", input: nil)
    #expect(messages == nil)
}

@Test func testParseInputWithFunctionCallAndOutput() {
    let items: [JSON] = [
        ["type": "function_call", "id": "call_1", "call_id": "call_1", "name": "Read", "arguments": "{}", "status": "completed"],
        ["type": "function_call_output", "call_id": "call_1", "output": "file content"],
        ["type": "message", "role": "user", "content": [["type": "input_text", "text": "continue"]] as Any],
    ]
    let messages = RelayHandler.parseInput(instructions: "", input: items)
    #expect(messages?.count == 3)
    let toolCalls = messages?[0]["tool_calls"] as? [JSON]
    #expect(toolCalls != nil)
    #expect(toolCalls?.count == 1)
    #expect(messages?[1]["role"] as? String == "tool")
    #expect(messages?[2]["role"] as? String == "user")
}

// MARK: - contentToText

@Test func testContentToTextString() {
    let result = RelayHandler.contentToText("hello")
    #expect(result == "hello")
}

@Test func testContentToTextNil() {
    let result = RelayHandler.contentToText(nil)
    #expect(result == nil)
}

@Test func testContentToTextArray() {
    let items: [Any] = [
        ["type": "output_text", "text": "hello"] as [String: Any],
        ["type": "output_text", "text": "world"] as [String: Any],
    ]
    #expect(RelayHandler.contentToText(items) == "hello\nworld")
}

// MARK: - convertTools

@Test func testConvertToolsBasic() {
    let tools: [JSON] = [
        ["type": "function", "name": "Edit", "description": "Edits files", "parameters": ["type": "object", "properties": [:]] as JSON]
    ]
    let converted = RelayHandler.convertTools(tools)
    #expect(converted.count == 1)
    let fn = converted[0]["function"] as? JSON
    #expect(fn?["name"] as? String == "Edit")
    #expect(fn?["description"] as? String == "Edits files")
}

@Test func testConvertToolsFiltersNonFunction() {
    let tools: [JSON] = [
        ["type": "web_search"],
        ["type": "function", "name": "Edit", "description": "", "parameters": [:]] as JSON,
    ]
    let converted = RelayHandler.convertTools(tools)
    #expect(converted.count == 1)
}

// MARK: - ensureToolAfterAssistant

@Test func testEnsureToolAfterAssistantAlreadyOrdered() {
    let messages: [JSON] = [
        ["role": "user", "content": "hi"],
        ["role": "assistant", "tool_calls": [["id": "call_1", "type": "function", "function": ["name": "Edit"]]] as [JSON]],
        ["role": "tool", "tool_call_id": "call_1", "content": "done"],
    ]
    let result = RelayHandler.ensureToolAfterAssistant(messages)
    #expect(result.count == 3)
    #expect(result[0]["role"] as? String == "user")
    #expect(result[1]["role"] as? String == "assistant")
    #expect(result[2]["role"] as? String == "tool")
}

// MARK: - 提供商配置

@Test func testProviderConfigDeepSeekDefaults() {
    let p = ProviderConfig.deepSeek
    #expect(p.name == "DeepSeek")
    #expect(p.supportsThinking == true)
    #expect(p.reasoningField == "reasoning_content")
}

@Test func testProviderConfigOpenAI() {
    let p = ProviderConfig.openAI
    #expect(p.name == "OpenAI")
    #expect(p.supportsThinking == false)
    #expect(p.supportsToolChoice == true)
}

@Test func testProviderConfigCustom() {
    let p = ProviderConfig.custom(baseURL: "http://localhost:11434/v1")
    #expect(p.baseURL == "http://localhost:11434/v1")
    #expect(p.id.hasPrefix("custom-"))
}

// MARK: - responseItemToMessage

@Test func testResponseItemToMessageFunctionCallOutput() {
    let item: JSON = ["type": "function_call_output", "call_id": "call_1", "output": "result"]
    let result = RelayHandler.responseItemToMessage(item)
    #expect(result != nil)
    let (msg, ok) = result!
    #expect(ok)
    #expect(msg["role"] as? String == "tool")
    #expect(msg["tool_call_id"] as? String == "call_1")
    #expect(msg["content"] as? String == "result")
}

@Test func testResponseItemToMessageInputText() {
    let item: JSON = ["type": "input_text", "text": "hello"]
    let result = RelayHandler.responseItemToMessage(item)
    #expect(result != nil)
    let (msg, ok) = result!
    #expect(msg["role"] as? String == "user")
    #expect(msg["content"] as? String == "hello")
}

// MARK: - Edge cases

@Test func testParseInputWithReasoningItem() {
    let items: [JSON] = [
        ["type": "reasoning", "content": [["type": "reasoning_text", "text": "thinking..."]] as Any],
        ["type": "message", "role": "assistant", "content": "answer"],
    ]
    let messages = RelayHandler.parseInput(instructions: "", input: items)
    #expect(messages?.count == 1)
    #expect(messages?[0]["reasoning_content"] as? String == "thinking...")
}

@Test func testResponsesToChatPayloadWithToolChoice() {
    let body: JSON = [
        "input": "hi",
        "tool_choice": "auto",
    ]
    // DeepSeek 不支持 tool_choice，不应透传
    let payload = RelayHandler.responsesToChatPayload(body, provider: .deepSeek)
    #expect(payload?["tool_choice"] == nil)
}

@Test func testResponsesToChatPayloadWithToolChoiceOpenAI() {
    let body: JSON = [
        "input": "hi",
        "tool_choice": "auto",
    ]
    // OpenAI 支持 tool_choice
    let payload = RelayHandler.responsesToChatPayload(body, provider: .openAI)
    #expect(payload?["tool_choice"] as? String == "auto")
}
