import Foundation
import AppKit
import iRelayCore

/// Patches the Codex desktop frontend model picker so custom non-OpenAI models
/// are not filtered out by the remote GPT model allowlist.
///
/// 启动 guard 后每 60 秒 stat 一次 asar mtime，变了才读内容验补丁。
/// Codex 升级后 asar 被恢复原样时自动重打，权限不足时弹窗引导。
final class CodexAppPatcher {
    private let appAsarPath = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/app.asar")
    private var backupPath: URL {
        appAsarPath.deletingLastPathComponent().appendingPathComponent("app.asar.bak.irelay-auto")
    }

    private let original = Data("s?t.has(n.model):!n.hidden".utf8)
    private let patched = Data("s?!n.hidden     :!n.hidden".utf8)
    private let manualPatched = Data("s?t.has(n.model)||!n.model.startsWith(`gpt-`):!n.hidden".utf8)

    private var guardThreadActive = false
    private var alertActive = false

    // MARK: - Public

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
                Log.error("codex_app_patch_permission_denied",
                    "hint", "请前往 系统设置 → 隐私与安全性 → App 管理 → 启用 iRelay")
                showPermissionAlert()
            } else {
                Log.error("codex_app_patch_failed", "error", error.localizedDescription)
            }
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

    // MARK: - Guard

    private func startGuard() {
        guard !guardThreadActive else { return }
        guardThreadActive = true
        let t = Thread { [weak self] in self?.guardLoop() }
        t.name = "com.xdf.irelay.codex-patcher"
        t.start()
    }

    /// 每 60 秒 stat 一次 asar mtime，变了才读内容验补丁
    private func guardLoop() {
        Log.info("codex_app_patch_guard_started")
        var lastMTime: Date?

        while guardThreadActive {
            Thread.sleep(forTimeInterval: 60)
            guard guardThreadActive else { break }

            let mtime = fileModificationDate()
            if mtime == lastMTime { continue }
            lastMTime = mtime

            ensurePatchIntact()
        }

        Log.info("codex_app_patch_guard_stopped")
    }

    /// 轻量 stat，不读文件内容
    private func fileModificationDate() -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: appAsarPath.path) else { return nil }
        return attrs[.modificationDate] as? Date
    }

    /// 读 asar 检查补丁，丢了就重打（写入失败会弹权限引导）
    private func ensurePatchIntact() {
        guard FileManager.default.fileExists(atPath: appAsarPath.path) else { return }

        guard let data = try? Data(contentsOf: appAsarPath) else { return }
        if data.range(of: patched) != nil || data.range(of: manualPatched) != nil { return }
        guard let range = data.range(of: original) else { return }

        do {
            var next = data
            next.replaceSubrange(range, with: patched)
            try next.write(to: appAsarPath, options: .atomic)
            Log.info("codex_app_patch_ok", "status", "guard_patched_after_update")
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSPOSIXErrorDomain && (nsError.code == EPERM || nsError.code == EACCES) {
                Log.error("codex_app_patch_permission_denied",
                    "hint", "请前往 系统设置 → 隐私与安全性 → App 管理 → 启用 iRelay")
                showPermissionAlert()
            } else {
                Log.info("codex_app_patch_guard_retry", "error", error.localizedDescription)
            }
        }
    }

    // MARK: - Alert

    /// 弹窗提示用户前往系统设置授予 App 管理权限（防重复）
    private func showPermissionAlert() {
        guard !alertActive else { return }
        alertActive = true
        DispatchQueue.main.async { [self] in
            let alert = NSAlert()
            alert.messageText = "需要「App 管理」权限"
            alert.informativeText = "iRelay 需要修改 Codex 桌面版才能显示 DeepSeek 模型。\n\n请前往：系统设置 → 隐私与安全性 → App 管理 → 开启 iRelay"
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "稍后")
            alert.alertStyle = .warning

            let response = alert.runModal()
            alertActive = false
            if response == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
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
