import Foundation

/// 管理 ~/.codex/config.toml，控制 Codex 使用 iRelay 本地中转
final class CodexConfigManager {
    private let appPatcher = CodexAppPatcher()

    private var configPath: URL {
        let env = ProcessInfo.processInfo.environment["CODEX_CONFIG"]
        if let env, !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("config.toml")
    }

    private var configDir: URL { configPath.deletingLastPathComponent() }
    private var modelCatalogPath: URL {
        configDir.appendingPathComponent("irelay-models.json")
    }

    /// 写入 model_provider + model，告诉 Codex 用 iRelay
    @discardableResult
    func enable(model: String) -> Bool {
        let raw = (try? String(contentsOf: configPath, encoding: .utf8)) ?? ""
        let next = configureCodexTOML(raw, model: model)
        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            try modelCatalogData().write(to: modelCatalogPath, options: .atomic)
            try next.write(to: configPath, atomically: true, encoding: .utf8)
            patchAppAsar()
            return true
        } catch {
            Log.error("codex_config_write_failed", "action", "enable", "error", error.localizedDescription)
            return false
        }
    }

    /// 移除 iRelay 配置，Codex 回退默认
    @discardableResult
    func disable() -> Bool {
        // 恢复 asar + 删备份
        restoreAppAsar()
        // 清理 config.toml
        if let raw = try? String(contentsOf: configPath, encoding: .utf8) {
            let next = disableCodexTOML(raw)
            try? next.write(to: configPath, atomically: true, encoding: .utf8)
        }
        // 清理模型目录
        try? FileManager.default.removeItem(at: modelCatalogPath)
        return true
    }

    /// 备份并打补丁（app 启动时调用）
    @discardableResult
    func patchAppAsar() -> Bool {
        appPatcher.ensurePatched()
    }

    /// 恢复备份并删除备份文件（app 退出时调用）
    @discardableResult
    func restoreAppAsar() -> Bool {
        let ok = appPatcher.restoreIfPossible()
        if ok { appPatcher.deleteBackup() }
        return ok
    }

    // MARK: - TOML 操作

    /// 写配置：顶层 key 放最上面，provider 块放最下面，不加注释
    private func configureCodexTOML(_ existing: String, model: String) -> String {
        var body = removeTopLevelModelKeys(existing)
        body = removeIRelaySection(body)
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)

        var result = "model_provider = \"iRelay\"\n"
        result += "model = \"\(model)\"\n"
        result += "model_catalog_json = \"\(tomlEscaped(modelCatalogPath.path))\""
        if !trimmed.isEmpty {
            result += "\n\n" + trimmed
        }
        result += "\n\n[model_providers.iRelay]\n"
        result += "name = \"iRelay\"\n"
        result += "base_url = \"http://127.0.0.1:8787/v1\"\n"
        result += "wire_api = \"responses\"\n"
        return result
    }

    /// 删配置：移除所有 iRelay 相关行，不保留注释
    private func disableCodexTOML(_ existing: String) -> String {
        var result = removeTopLevelModelKeys(existing)
        result = removeIRelaySection(result)
        return result.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// 移除顶层 model_provider / model 行
    private func removeTopLevelModelKeys(_ toml: String) -> String {
        var currentTable = ""
        var lines: [String] = []
        for line in toml.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                currentTable = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            }
            if currentTable.isEmpty && isTopLevelModelKey(trimmed) {
                continue
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// 移除 [model_providers.iRelay] 整个 section
    private func removeIRelaySection(_ toml: String) -> String {
        let target = "[model_providers.iRelay]"
        var result: [String] = []
        var inTarget = false
        for line in toml.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == target {
                inTarget = true
                continue
            }
            if inTarget && trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                inTarget = false
                result.append(line)
                continue
            }
            if !inTarget {
                result.append(line)
            }
        }
        return result.joined(separator: "\n")
    }

    private func isTopLevelModelKey(_ line: String) -> Bool {
        guard let key = keyName(line) else { return false }
        return key == "model_provider" || key == "model" || key == "model_catalog_json"
    }

    private func keyName(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { return nil }
        return String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces)
    }

    private func modelCatalogData() throws -> Data {
        let models = RelayState.loadModels().enumerated().map { i, m in
            modelInfo(m.id, desc: m.description, priority: i)
        }
        let catalog: [String: Any] = ["models": models.isEmpty
            ? [modelInfo("deepseek-v4-pro", desc: "DeepSeek V4 Pro", priority: 0),
               modelInfo("deepseek-v4-flash", desc: "DeepSeek V4 Flash", priority: 1)]
            : models
        ]
        return try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys])
    }

    private func modelInfo(_ id: String, desc: String, priority: Int) -> [String: Any] {
        [
            "slug": id,
            "display_name": id,
            "description": desc,
            "supported_reasoning_levels": [
                ["effort": "none", "description": ""],
                ["effort": "low", "description": ""],
                ["effort": "medium", "description": ""],
                ["effort": "high", "description": ""]
            ],
            "default_reasoning_level": "none",
            "shell_type": "shell_command",
            "visibility": "list",
            "supported_in_api": true,
            "priority": priority,
            "base_instructions": "You are a helpful AI assistant powered by DeepSeek.",
            "supports_reasoning_summaries": false,
            "support_verbosity": false,
            "default_verbosity": "low",
            "apply_patch_tool_type": "freeform",
            "supports_parallel_tool_calls": true,
            "context_window": 1_000_000,
            "max_context_window": 1_000_000,
            "effective_context_window_percent": 95,
            "input_modalities": ["text"],
            "experimental_supported_tools": [],
            "truncation_policy": ["mode": "tokens", "limit": 1_000_000]
        ]
    }

    private func tomlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
