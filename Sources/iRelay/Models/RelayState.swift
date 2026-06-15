import Foundation
import Combine
import iRelayCore

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
    private static func saveModels(_ models: [ModelInfo]) {
        guard let data = try? JSONEncoder().encode(models) else { return }
        UserDefaults.standard.set(data, forKey: "irelay_models")
    }

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
    static let version = "2.1.0"

    init() {
        apiKey = UserDefaults.standard.string(forKey: Self.keychainKey) ?? ""
        model = UserDefaults.standard.string(forKey: Self.modelKey) ?? "deepseek-v4-pro"
        thinkingEnabled = UserDefaults.standard.object(forKey: Self.thinkingKey) as? Bool ?? true
        codexEnabled = UserDefaults.standard.object(forKey: Self.codexKey) as? Bool ?? true

        turnOn(model: model)
    }

    private var server: HTTPServer?
    private var client: ChatClient?
    private var handler: RelayHandler?
    private var codexEnableSkippedForMissingKey = false
    var isOn: Bool { status == .running || status == .starting }

    func turnOn(model: String) {
        self.model = model
        guard status == .stopped else { return }
        status = .starting
        Log.info("service_starting", "model", model, "port", 8787)

        guard let upstreamURL = URL(string: upstream) else {
            Log.error("config_invalid", "key", "upstream", "value", upstream)
            status = .stopped
            return
        }

        let c = ChatClient(apiKey: apiKey, baseURL: upstreamURL)
        client = c
        let h = RelayHandler(client: c, provider: .deepSeek)
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

    func turnOff() {
        guard status == .running || status == .starting else { return }
        Log.info("service_stopping")
        stopServer()
        status = .stopped
    }

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

    func disableCodex() {
        codexEnableSkippedForMissingKey = false
        codexEnabled = false
        codexConfigManager.disable()
        Log.info("codex_config_disabled")
    }

    func toggleThinking() { setThinking(!thinkingEnabled) }

    func setThinking(_ enabled: Bool) {
        thinkingEnabled = enabled
        var p = ProviderConfig.deepSeek
        p.thinkingMode = enabled ? .deepseekStyle : .none
        handler?.provider = p
        Log.info("thinking_toggled", "enabled", thinkingEnabled)
    }

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
        if codexConfigManager.enable(model: model, port: 8787) {
            codexEnableSkippedForMissingKey = false
            Log.info("codex_config_enabled", "model", model)
        }
    }
}
