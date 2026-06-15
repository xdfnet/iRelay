import Foundation

/// 推理模式
enum ThinkingMode: String, Codable {
    case none            // 不支持推理
    case deepseekStyle   // payload["thinking"] = ["type": "enabled"/"disabled"]
}

/// 提供商配置
struct ProviderConfig: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var baseURL: String
    var apiKey: String
    var defaultModel: String
    var models: [ModelInfo]

    // -- 功能标志 --
    var thinkingMode: ThinkingMode
    /// SSE delta 中推理文本的字段名（如 "reasoning_content"）
    var reasoningField: String
    var supportsToolChoice: Bool

    // -- 模型目录 --
    var baseInstructions: String
    var contextWindow: Int

    var supportsThinking: Bool { thinkingMode != .none }

    // MARK: - 预设

    static let deepSeek = ProviderConfig(
        id: "deepseek",
        name: "DeepSeek",
        baseURL: "https://api.deepseek.com",
        apiKey: "",
        defaultModel: "deepseek-v4-pro",
        models: [
            ModelInfo(id: "deepseek-v4-pro", description: "DeepSeek V4 Pro"),
            ModelInfo(id: "deepseek-v4-flash", description: "DeepSeek V4 Flash"),
        ],
        thinkingMode: .deepseekStyle,
        reasoningField: "reasoning_content",
        supportsToolChoice: false,
        baseInstructions: "You are a helpful AI assistant powered by DeepSeek.",
        contextWindow: 1_000_000
    )

    static let openAI = ProviderConfig(
        id: "openai",
        name: "OpenAI",
        baseURL: "https://api.openai.com",
        apiKey: "",
        defaultModel: "gpt-4o",
        models: [],
        thinkingMode: .none,
        reasoningField: "",
        supportsToolChoice: true,
        baseInstructions: "You are a helpful AI assistant.",
        contextWindow: 128_000
    )

    static func custom(baseURL: String) -> ProviderConfig {
        ProviderConfig(
            id: "custom-" + UUID().uuidString.prefix(8).lowercased(),
            name: "自定义",
            baseURL: baseURL,
            apiKey: "",
            defaultModel: "",
            models: [],
            thinkingMode: .none,
            reasoningField: "",
            supportsToolChoice: false,
            baseInstructions: "You are a helpful AI assistant.",
            contextWindow: 128_000
        )
    }
}
