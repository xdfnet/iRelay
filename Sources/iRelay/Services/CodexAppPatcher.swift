import Foundation
import iRelayCore

/// Patches the Codex desktop frontend model picker so custom non-OpenAI models
/// are not filtered out by the remote GPT model allowlist.
///
/// 启动 guard 后自动开启后台线程，每 60 秒验证补丁是否还在。
/// Codex 升级后 asar 被恢复原样，guard 能在下一轮检测到并重新打补丁。
final class CodexAppPatcher {
    private let appAsarPath = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/app.asar")
    private var backupPath: URL {
        appAsarPath.deletingLastPathComponent().appendingPathComponent("app.asar.bak.irelay-auto")
    }

    private let original = Data("s?t.has(n.model):!n.hidden".utf8)
    private let patched = Data("s?!n.hidden     :!n.hidden".utf8)
    private let manualPatched = Data("s?t.has(n.model)||!n.model.startsWith(`gpt-`):!n.hidden".utf8)

    private var guardThreadActive = false

    // MARK: - Public

    /// 尝试打补丁，无论成败都会启动后台 guard 持续守护
    @discardableResult
    func ensurePatched() -> Bool {
        defer { startGuard() }

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
            } else {
                Log.error("codex_app_patch_failed", "error", error.localizedDescription)
            }
            return false
        }
    }

    /// 恢复原始 asar（不操作 guard，由调用方处理）
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

    func stopGuard() { guardThreadActive = false }

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

    // MARK: - Guard 线程

    /// 每 60 秒检查一次补丁完整性，Codex 升级后自动重打
    private func startGuard() {
        guard !guardThreadActive else { return }
        guardThreadActive = true
        let t = Thread { [weak self] in self?.guardLoop() }
        t.name = "com.xdf.irelay.codex-patcher"
        t.start()
    }

    private func guardLoop() {
        Log.info("codex_app_patch_guard_started")

        while guardThreadActive {
            Thread.sleep(forTimeInterval: 60)
            guard guardThreadActive else { break }
            guard FileManager.default.fileExists(atPath: appAsarPath.path) else { continue }

            do {
                let data = try Data(contentsOf: appAsarPath)
                // 补丁还在 → 下一轮
                if data.range(of: patched) != nil || data.range(of: manualPatched) != nil {
                    continue
                }
                // 补丁丢了（Codex 升级了）→ 重打
                guard let range = data.range(of: original) else { continue }

                var next = data
                next.replaceSubrange(range, with: patched)
                try next.write(to: appAsarPath, options: .atomic)
                Log.info("codex_app_patch_ok", "status", "guard_patched_after_update")
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSPOSIXErrorDomain && (nsError.code == EPERM || nsError.code == EACCES) {
                    Log.error("codex_app_patch_permission_denied",
                        "hint", "请前往 系统设置 → 隐私与安全性 → App 管理 → 启用 iRelay")
                } else {
                    Log.info("codex_app_patch_guard_retry", "error", error.localizedDescription)
                }
            }
        }

        Log.info("codex_app_patch_guard_stopped")
    }

    // MARK: - Backup

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
