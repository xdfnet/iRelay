import Foundation

/// Patches the Codex desktop frontend model picker so custom non-OpenAI models
/// are not filtered out by the remote GPT model allowlist.
final class CodexAppPatcher {
    private let appAsarPath = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/app.asar")
    private var backupPath: URL {
        appAsarPath.deletingLastPathComponent().appendingPathComponent("app.asar.bak.irelay-auto")
    }

    private let original = Data("s?t.has(n.model):!n.hidden".utf8)
    private let patched = Data("s?!n.hidden     :!n.hidden".utf8)
    private let manualPatched = Data("s?t.has(n.model)||!n.model.startsWith(`gpt-`):!n.hidden".utf8)

    @discardableResult
    func ensurePatched() -> Bool {
        guard FileManager.default.fileExists(atPath: appAsarPath.path) else {
            Log.error("codex_app_patch_failed", "reason", "app_asar_missing", "path", appAsarPath.path)
            return false
        }

        do {
            let data = try Data(contentsOf: appAsarPath)
            if data.range(of: patched) != nil || data.range(of: manualPatched) != nil {
                Log.info("codex_app_patch_ok", "status", "already_patched")
                return true
            }

            guard let range = data.range(of: original) else {
                Log.error("codex_app_patch_failed", "reason", "pattern_not_found")
                return false
            }

            if FileManager.default.fileExists(atPath: backupPath.path) {
                try FileManager.default.removeItem(at: backupPath)
            }
            try FileManager.default.copyItem(at: appAsarPath, to: backupPath)

            var next = data
            next.replaceSubrange(range, with: patched)
            try next.write(to: appAsarPath, options: .atomic)
            Log.info("codex_app_patch_ok", "status", "patched", "backup", backupPath.path)
            return true
        } catch {
            Log.error("codex_app_patch_failed", "error", error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func restoreIfPossible() -> Bool {
        guard let source = restoreBackupPath() else {
            Log.info("codex_app_restore_skip", "reason", "backup_missing")
            return true
        }

        do {
            try FileManager.default.copyItemReplacingExisting(at: source, to: appAsarPath)
            Log.info("codex_app_restore_ok", "backup", source.path)
            return true
        } catch {
            Log.error("codex_app_restore_failed", "error", error.localizedDescription)
            return false
        }
    }

    /// 删除备份文件（恢复成功后调用）
    func deleteBackup() {
        let path = backupPath.path
        guard FileManager.default.fileExists(atPath: path) else { return }
        do {
            try FileManager.default.removeItem(at: backupPath)
            Log.info("codex_app_backup_deleted", "path", path)
        } catch {
            Log.error("codex_app_backup_delete_failed", "error", error.localizedDescription)
        }
    }

    private func restoreBackupPath() -> URL? {
        if FileManager.default.fileExists(atPath: backupPath.path) {
            return backupPath
        }
        let dir = appAsarPath.deletingLastPathComponent()
        let backups = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return backups
            .filter { $0.lastPathComponent.hasPrefix("app.asar.bak.irelay.") }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
            .first
    }
}

private extension FileManager {
    func copyItemReplacingExisting(at source: URL, to destination: URL) throws {
        if fileExists(atPath: destination.path) {
            try removeItem(at: destination)
        }
        try copyItem(at: source, to: destination)
    }
}
