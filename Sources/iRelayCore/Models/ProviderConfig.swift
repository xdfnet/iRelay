import Foundation

/// 推理模式
public enum ThinkingMode: String, Codable {
    case none            // 不支持推理
    case deepseekStyle   // payload["thinking"] = ["type": "enabled"/"disabled"]
}

/// 提供商配置
public struct ProviderConfig: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var baseURL: String
    public var apiKey: String
    public var defaultModel: String
    public var models: [ModelInfo]

    // -- 功能标志 --
    public var thinkingMode: ThinkingMode
    /// SSE delta 中推理文本的字段名（如 "reasoning_content"）
    public var reasoningField: String
    public var supportsToolChoice: Bool

    // -- 模型目录 --
    public var baseInstructions: String
    public var contextWindow: Int

    public var supportsThinking: Bool { thinkingMode != .none }

    public init(id: String, name: String, baseURL: String, apiKey: String, defaultModel: String, models: [ModelInfo], thinkingMode: ThinkingMode, reasoningField: String, supportsToolChoice: Bool, baseInstructions: String, contextWindow: Int) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.defaultModel = defaultModel
        self.models = models
        self.thinkingMode = thinkingMode
        self.reasoningField = reasoningField
        self.supportsToolChoice = supportsToolChoice
        self.baseInstructions = baseInstructions
        self.contextWindow = contextWindow
    }

    // MARK: - 预设

    public static let deepSeek = ProviderConfig(
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

    public static let openAI = ProviderConfig(
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

    public static func custom(baseURL: String) -> ProviderConfig {
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
