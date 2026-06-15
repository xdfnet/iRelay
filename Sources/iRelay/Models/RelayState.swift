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
    @Published var providerStore = ProviderStore()
    @Published var port: UInt16 {
        didSet { UserDefaults.standard.set(port, forKey: Self.portKey) }
    }

    var model: String { providerStore.activeProvider?.defaultModel ?? "deepseek-v4-pro" }
    var thinkingEnabled: Bool = true
    var apiKey: String { providerStore.activeProvider?.apiKey ?? "" }
    var availableModels: [ModelInfo] { providerStore.activeProvider?.models ?? [] }
    var codexEnabled: Bool = true

    private static let portKey = "irelay_port"

    let codexConfigManager = CodexConfigManager()
    static let version = "2.0.0"

    init() {
        port = UInt16(UserDefaults.standard.integer(forKey: Self.portKey))
        if port == 0 { port = 8787 }
        // ProviderStore init 已处理 v1 迁移
        if let p = providerStore.activeProvider {
            thinkingEnabled = p.supportsThinking
        }
        turnOn(model: providerStore.activeProvider?.defaultModel ?? "deepseek-v4-pro")
    }

    private var server: HTTPServer?
    private var client: ChatClient?
    private var handler: RelayHandler?

    var isOn: Bool { status == .running || status == .starting }

    // MARK: - 服务生命周期

    func turnOn(model: String) {
        guard let provider = providerStore.activeProvider else { return }
        guard status == .stopped else { return }
        status = .starting
        Log.info("service_starting", "model", model, "provider", provider.name, "port", port)

        guard let upstreamURL = URL(string: provider.baseURL) else {
            Log.error("config_invalid", "key", "upstream", "value", provider.baseURL)
            status = .stopped
            return
        }

        let c = ChatClient(apiKey: provider.apiKey, baseURL: upstreamURL)
        client = c
        var prov = provider
        if !model.isEmpty { prov.defaultModel = model }
        let h = RelayHandler(client: c, provider: prov)
        handler = h

        let httpServer = HTTPServer()
        h.register(on: httpServer)

        do {
            try httpServer.start(port: port)
            server = httpServer
            status = .running
            Log.info("server_started", "port", port)
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

    // MARK: - 提供商切换

    func switchProvider(_ id: String) {
        providerStore.setActive(id)
        thinkingEnabled = providerStore.activeProvider?.supportsThinking ?? false
        turnOff()
        if let p = providerStore.activeProvider {
            turnOn(model: p.defaultModel)
            syncCodexConfig(provider: p)
        }
        Log.info("provider_switched", "provider", providerStore.activeProvider?.name ?? id)
    }

    // MARK: - 模型

    func selectModel(_ id: String) {
        guard var p = providerStore.activeProvider else { return }
        p.defaultModel = id
        providerStore.updateProvider(p)
        if apiKey.isEmpty {
            codexEnabled = false
            Log.error("codex_config_skip", "reason", "empty_api_key", "model", id)
        } else {
            codexEnabled = true
            syncCodexConfig(provider: p)
        }
        Log.info("model_switched", "model", id)
    }

    func disableCodex() {
        codexEnabled = false
        codexConfigManager.disable()
        Log.info("codex_config_disabled")
    }

    // MARK: - 思考

    func toggleThinking() {
        setThinking(!thinkingEnabled)
    }

    func setThinking(_ enabled: Bool) {
        thinkingEnabled = enabled
        handler?.provider = providerStore.activeProvider ?? .deepSeek
        Log.info("thinking_toggled", "enabled", thinkingEnabled)
    }

    // MARK: - API Key

    func saveApiKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var p = providerStore.activeProvider else { return false }
        p.apiKey = trimmed
        providerStore.updateProvider(p)
        client?.apiKey = trimmed
        if isOn {
            Task { await fetchModels() }
        }
        Log.info("api_key_updated", "provider", p.name)
        return true
    }

    // MARK: - 模型列表

    func fetchModels() async {
        guard let p = providerStore.activeProvider, !p.apiKey.isEmpty else { return }
        guard let url = URL(string: p.baseURL + "/v1/models") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(p.apiKey)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataList = json["data"] as? [[String: Any]]
        else { return }
        let models = dataList.compactMap { item -> ModelInfo? in
            guard let id = item["id"] as? String else { return nil }
            let desc = item["description"] as? String ?? ""
            return ModelInfo(id: id, description: desc)
        }
        guard !models.isEmpty, var p = providerStore.activeProvider else { return }
        p.models = models
        providerStore.updateProvider(p)
    }

    // MARK: - Private

    private func stopServer() {
        server?.stop()
        server = nil
        client = nil
        handler = nil
    }

    private func syncCodexConfig(provider: ProviderConfig) {
        guard codexEnabled else {
            codexConfigManager.disable()
            return
        }
        guard !provider.apiKey.isEmpty else {
            Log.error("codex_config_skip", "reason", "empty_api_key")
            codexEnabled = false
            return
        }
        if codexConfigManager.enable(provider: provider, port: port) {
            Log.info("codex_config_enabled", "provider", provider.name, "model", provider.defaultModel)
        }
    }
}
