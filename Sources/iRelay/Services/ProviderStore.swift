import Foundation
import iRelayCore

/// 多提供商配置存储，持久化到 UserDefaults
@MainActor
final class ProviderStore: ObservableObject {
    @Published var providers: [ProviderConfig] = []
    @Published var activeProviderID: String = "deepseek"

    var activeProvider: ProviderConfig? {
        providers.first { $0.id == activeProviderID }
    }

    private let providersKey = "irelay_providers"
    private let activeKey = "irelay_active_provider"

    // v1 key 常量
    private let v1ApiKey = "irelay_apiKey"
    private let v1Model = "irelay_model"
    private let v1Thinking = "irelay_thinking"
    private let v1Models = "irelay_models"

    init() {
        if !migrateFromV1() {
            load()
        }
        if providers.isEmpty {
            providers = [.deepSeek]
            activeProviderID = "deepseek"
            save()
        }
        ensureActiveProviderExists()
    }

    // MARK: - CRUD

    func addProvider(_ config: ProviderConfig) {
        providers.append(config)
        save()
    }

    func updateProvider(_ config: ProviderConfig) {
        guard let idx = providers.firstIndex(where: { $0.id == config.id }) else { return }
        providers[idx] = config
        save()
    }

    func deleteProvider(_ id: String) {
        providers.removeAll { $0.id == id }
        if activeProviderID == id {
            activeProviderID = providers.first?.id ?? ""
        }
        save()
    }

    func setActive(_ id: String) {
        guard providers.contains(where: { $0.id == id }) else { return }
        activeProviderID = id
        UserDefaults.standard.set(id, forKey: activeKey)
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(providers) else { return }
        UserDefaults.standard.set(data, forKey: providersKey)
        UserDefaults.standard.set(activeProviderID, forKey: activeKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: providersKey),
              let decoded = try? JSONDecoder().decode([ProviderConfig].self, from: data),
              !decoded.isEmpty
        else { return }
        providers = decoded
        activeProviderID = UserDefaults.standard.string(forKey: activeKey) ?? providers.first?.id ?? "deepseek"
    }

    // MARK: - v1 Migration

    /// 从 v1 UserDefaults 键迁移到 ProviderStore
    /// 返回 true 表示已执行迁移
    private func migrateFromV1() -> Bool {
        guard let oldKey = UserDefaults.standard.string(forKey: v1ApiKey), !oldKey.isEmpty else {
            return false
        }

        let oldModel = UserDefaults.standard.string(forKey: v1Model) ?? "deepseek-v4-pro"
        let oldModels: [ModelInfo] = {
            guard let data = UserDefaults.standard.data(forKey: v1Models),
                  let models = try? JSONDecoder().decode([ModelInfo].self, from: data),
                  !models.isEmpty
            else { return [] }
            return models
        }()

        var ds = ProviderConfig.deepSeek
        ds.apiKey = oldKey
        if !oldModels.isEmpty { ds.models = oldModels }
        ds.defaultModel = oldModel

        providers = [ds]
        activeProviderID = "deepseek"

        // 写新格式
        save()

        // 清旧 key（留 apiKey 作回退）
        UserDefaults.standard.removeObject(forKey: v1Model)
        UserDefaults.standard.removeObject(forKey: v1Thinking)
        UserDefaults.standard.removeObject(forKey: v1Models)

        return true
    }

    private func ensureActiveProviderExists() {
        if activeProvider == nil {
            activeProviderID = providers.first?.id ?? ""
            if activeProviderID.isEmpty, providers.isEmpty {
                providers = [.deepSeek]
                activeProviderID = "deepseek"
                save()
            }
        }
    }
}
