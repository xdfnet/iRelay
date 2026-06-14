import Foundation
import Combine

enum RelayStatus: Equatable {
    case stopped
    case starting
    case running
}

@MainActor
final class RelayState: ObservableObject {
    @Published var status: RelayStatus = .stopped
    @Published var model: String = "deepseek-v4-pro" {
        didSet { UserDefaults.standard.set(model, forKey: Self.modelKey) }
    }
    @Published var availableModels: [ModelInfo] = RelayState.loadModels()
    @Published var thinkingEnabled: Bool {
        didSet { UserDefaults.standard.set(thinkingEnabled, forKey: Self.thinkingKey) }
    }
    @Published var apiKey: String = "" {
        didSet { UserDefaults.standard.set(apiKey, forKey: Self.keychainKey) }
    }
    @Published var codexEnabled: Bool {
        didSet { UserDefaults.standard.set(codexEnabled, forKey: Self.codexKey) }
    }
    var upstream: String = "https://api.deepseek.com"

    private static let keychainKey = "irelay_apiKey"
    static let modelKey = "irelay_model"
    private static let thinkingKey = "irelay_thinking"
    private static let codexKey = "irelay_codexEnabled"
    /// 支持的模型列表存储到 UserDefaults
    private static func saveModels(_ models: [ModelInfo]) {
        guard let data = try? JSONEncoder().encode(models) else { return }
        UserDefaults.standard.set(data, forKey: "irelay_models")
    }

    /// 从 UserDefaults 读取模型列表，取不到时返回默认值
    nonisolated static func loadModels() -> [ModelInfo] {
        guard let data = UserDefaults.standard.data(forKey: "irelay_models"),
              let models = try? JSONDecoder().decode([ModelInfo].self, from: data),
              !models.isEmpty
        else {
            return [
                ModelInfo(id: "deepseek-v4-pro", description: "DeepSeek V4 Pro"),
                ModelInfo(id: "deepseek-v4-flash", description: "DeepSeek V4 Flash"),
            ]
        }
        return models
    }

    let codexConfigManager = CodexConfigManager()

    static let version = "1.4.0"

    init() {
        apiKey = UserDefaults.standard.string(forKey: Self.keychainKey) ?? ""
        model = UserDefaults.standard.string(forKey: Self.modelKey) ?? "deepseek-v4-pro"
        thinkingEnabled = UserDefaults.standard.object(forKey: Self.thinkingKey) as? Bool ?? true
        codexEnabled = UserDefaults.standard.object(forKey: Self.codexKey) as? Bool ?? true
        turnOn(model: model)
    }

    private var server: HTTPServer?
    private var client: DeepSeekClient?
    private var handler: RelayHandler?
    private var codexEnableSkippedForMissingKey = false
    var isOn: Bool {
        status == .running || status == .starting
    }

    /// 启动服务
    func turnOn(model: String) {
        self.model = model
        guard status == .stopped else { return }
        status = .starting
        Log.info("service_starting", "model", model)

        guard let upstreamURL = URL(string: upstream) else {
            Log.error("config_invalid", "key", "upstream", "value", upstream)
            status = .stopped
            return
        }

        let c = DeepSeekClient(apiKey: apiKey, baseURL: upstreamURL)
        client = c
        let h = RelayHandler(client: c, thinking: thinkingEnabled)
        handler = h

        let httpServer = HTTPServer()
        h.register(on: httpServer)

        do {
            try httpServer.start(port: 8787)
            server = httpServer
            status = .running
            Log.info("server_started", "port", 8787)
        } catch {
            server = nil
            client = nil
            status = .stopped
            Log.error("server_start_failed", "error", error.localizedDescription)
        }
    }

    /// 停用服务（App 退出时调用）
    func turnOff() {
        guard status == .running || status == .starting else { return }
        Log.info("service_stopping")
        stopServer()
        status = .stopped
    }

    /// 选中模型
    func selectModel(_ id: String) {
        model = id
        if apiKey.isEmpty {
            codexEnabled = false
            Log.error("codex_config_skip", "reason", "empty_api_key", "model", id)
        } else {
            codexEnabled = true
            syncCodexConfig()
        }
        Log.info("model_switched", "model", id)
    }

    /// 关闭 Codex 中的 iRelay 使用
    func disableCodex() {
        codexEnableSkippedForMissingKey = false
        codexEnabled = false
        codexConfigManager.disable()
        Log.info("codex_config_disabled")
    }

    /// 切换思考模式
    func toggleThinking() {
        setThinking(!thinkingEnabled)
    }

    /// 设置思考模式
    func setThinking(_ enabled: Bool) {
        thinkingEnabled = enabled
        handler?.thinking = thinkingEnabled
        Log.info("thinking_toggled", "enabled", thinkingEnabled)
    }

    /// 保存 API Key 到 UserDefaults
    func saveApiKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        apiKey = trimmed
        client?.apiKey = trimmed
        if isOn {
            Task { await fetchModels() }
        }
        Log.info("api_key_updated")
        return true
    }

    // MARK: - 模型列表

    /// 从上游 DeepSeek API 获取模型列表
    func fetchModels() async {
        guard !apiKey.isEmpty else { return }
        guard let url = URL(string: upstream + "/v1/models") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataList = json["data"] as? [[String: Any]]
        else { return }
        let models = dataList.compactMap { item -> ModelInfo? in
            guard let id = item["id"] as? String else { return nil }
            let desc = item["description"] as? String ?? ""
            return ModelInfo(id: id, description: desc)
        }
        guard !models.isEmpty else { return }
        availableModels = models
        Self.saveModels(models)
    }

    // MARK: - Private

    private func stopServer() {
        server?.stop()
        server = nil
        client = nil
        handler = nil
    }

    private func syncCodexConfig() {
        guard codexEnabled else {
            codexConfigManager.disable()
            return
        }
        guard !apiKey.isEmpty else {
            Log.error("codex_config_skip", "reason", "empty_api_key")
            codexEnableSkippedForMissingKey = true
            codexEnabled = false
            return
        }
        if codexConfigManager.enable(model: model) {
            codexEnableSkippedForMissingKey = false
            Log.info("codex_config_enabled", "model", model)
        }
    }

}
