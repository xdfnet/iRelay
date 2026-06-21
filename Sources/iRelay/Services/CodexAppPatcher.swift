import Foundation
import iRelayCore

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

    private var polling = false

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
            let nsError = error as NSError
            if nsError.domain == NSPOSIXErrorDomain && (nsError.code == EPERM || nsError.code == EACCES) {
                Log.error("codex_app_patch_permission_denied", "error", error.localizedDescription,
                    "hint", "请前往 系统设置 → 隐私与安全性 → App 管理 → 启用 iRelay")
                startPolling()
            } else {
                Log.error("codex_app_patch_failed", "error", error.localizedDescription)
            }
            return false
        }
    }

    // MARK: - 权限轮询

    /// 每 5 秒重试一次补丁，权限就绪后自动打上
    private func startPolling() {
        guard !polling else { return }
        polling = true
        let t = Thread { [weak self] in self?.pollLoop() }
        t.name = "com.xdf.irelay.codex-patcher"
        t.start()
    }

    private func pollLoop() {
        Log.info("codex_app_patch_polling_started")

        while polling {
            Thread.sleep(forTimeInterval: 5)

            guard polling else { break }
            guard FileManager.default.fileExists(atPath: appAsarPath.path) else { continue }

            do {
                let data = try Data(contentsOf: appAsarPath)
                if data.range(of: patched) != nil || data.range(of: manualPatched) != nil {
                    Log.info("codex_app_patch_ok", "status", "polling_already_patched")
                    break
                }
                guard let range = data.range(of: original) else { continue }

                var next = data
                next.replaceSubrange(range, with: patched)
                try next.write(to: appAsarPath, options: .atomic)
                Log.info("codex_app_patch_ok", "status", "polling_patched")
                break
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSPOSIXErrorDomain && (nsError.code == EPERM || nsError.code == EACCES) {
                    continue // 权限未就绪，继续轮询
                }
                Log.error("codex_app_patch_polling_stopped", "error", error.localizedDescription)
                break
            }
        }

        polling = false
        Log.info("codex_app_patch_polling_stopped")
    }

    @discardableResult
    func restoreIfPossible() -> Bool {
        polling = false
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
