import Foundation
import iRelayCore

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

    @discardableResult
    func enable(model: String, port: UInt16) -> Bool {
        guard patchAppAsar() else {
            Log.error("codex_config_enable_failed", "reason", "asar_patch_failed")
            return false
        }

        let raw = (try? String(contentsOf: configPath, encoding: .utf8)) ?? ""
        let next = configureCodexTOML(raw, model: model, port: port)
        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            try modelCatalogData().write(to: modelCatalogPath, options: .atomic)
            try next.write(to: configPath, atomically: true, encoding: .utf8)
            return true
        } catch {
            Log.error("codex_config_enable_failed", "reason", "config_write_failed", "error", error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func disable() -> Bool {
        appPatcher.stopGuard()
        if let raw = try? String(contentsOf: configPath, encoding: .utf8) {
            let next = disableCodexTOML(raw)
            try? next.write(to: configPath, atomically: true, encoding: .utf8)
        }
        try? FileManager.default.removeItem(at: modelCatalogPath)
        return true
    }

    @discardableResult
    func patchAppAsar() -> Bool { appPatcher.ensurePatched() }

    // MARK: - TOML

    private func configureCodexTOML(_ existing: String, model: String, port: UInt16) -> String {
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
        result += "base_url = \"http://127.0.0.1:\(port)/v1\"\n"
        result += "wire_api = \"responses\"\n"
        return result
    }

    private func disableCodexTOML(_ existing: String) -> String {
        var result = removeTopLevelModelKeys(existing)
        result = removeIRelaySection(result)
        return result.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

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
            if !inTarget { result.append(line) }
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

    // MARK: - Model catalog

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
                ["effort": "none", "description": "不推理"],
                ["effort": "low", "description": "快速响应"],
                ["effort": "medium", "description": "平衡速度与深度"],
                ["effort": "high", "description": "深度推理"],
                ["effort": "xhigh", "description": "极深推理"]
            ],
            "default_reasoning_level": "none",
            "shell_type": "shell_command",
            "visibility": "list",
            "supported_in_api": true,
            "priority": priority,
            "base_instructions": "You are an AI coding assistant powered by DeepSeek. You have a 1M token context window and support multiple reasoning levels (none/low/medium/high/xhigh). You excel at understanding large codebases, editing files, running shell commands, and reasoning through complex engineering problems. Think step by step before acting. Use tools proactively to explore, verify, and iterate. Be direct, concise, and helpful.",
            "supports_reasoning_summaries": true,
            "default_reasoning_summary": "concise",
            "support_verbosity": true,
            "default_verbosity": "low",
            "apply_patch_tool_type": "freeform",
            "supports_parallel_tool_calls": true,
            "context_window": 1_000_000,
            "max_context_window": 1_000_000,
            "effective_context_window_percent": 95,
            "auto_compact_token_limit": 950_000,
            "input_modalities": ["text"],
            "web_search_tool_type": "text",
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
