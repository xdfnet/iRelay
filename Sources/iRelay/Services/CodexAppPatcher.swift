import Foundation
import AppKit
import iRelayCore

/// Patches the Codex desktop frontend model picker so custom non-OpenAI models
/// are not filtered out by the remote GPT model allowlist.
///
/// 启动 guard 后每 10 秒做两件事：
/// 1. 检查 App 管理权限 → 缺则弹窗引导用户
/// 2. 检查 asar 补丁 → 丢了则自动重打
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

    /// 尝试打补丁，无论成败都启动后台 guard 持续守护
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
                showPermissionAlert()
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

    private func startGuard() {
        guard !guardThreadActive else { return }
        guardThreadActive = true
        let t = Thread { [weak self] in self?.guardLoop() }
        t.name = "com.xdf.irelay.codex-patcher"
        t.start()
    }

    /// 每 10 秒循环：①查权限 ②查补丁，各自独立
    private func guardLoop() {
        Log.info("codex_app_patch_guard_started")

        while guardThreadActive {
            Thread.sleep(forTimeInterval: 10)
            guard guardThreadActive else { break }

            // ① 检查权限：尝试写入 asar（轻量探测）
            checkPermission()

            // ② 检查补丁：丢了就重打
            ensurePatchIntact()
        }

        Log.info("codex_app_patch_guard_stopped")
    }

    /// 探测 App 管理权限是否就绪
    private func checkPermission() {
        guard FileManager.default.fileExists(atPath: appAsarPath.path) else { return }

        // 尝试读→写回（不改变内容）来检测写入权限
        guard let data = try? Data(contentsOf: appAsarPath) else { return }
        do {
            try data.write(to: appAsarPath, options: .atomic)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSPOSIXErrorDomain && (nsError.code == EPERM || nsError.code == EACCES) {
                Log.error("codex_app_patch_permission_denied",
                    "hint", "请前往 系统设置 → 隐私与安全性 → App 管理 → 启用 iRelay")
                showPermissionAlert()
            }
        }
    }

    /// 检查 asar 补丁完整性，丢了就自动重打
    private func ensurePatchIntact() {
        guard FileManager.default.fileExists(atPath: appAsarPath.path) else { return }

        guard let data = try? Data(contentsOf: appAsarPath) else { return }
        // 补丁还在 → 不用管
        if data.range(of: patched) != nil || data.range(of: manualPatched) != nil { return }
        // 原始模式都没有 → 无法处理
        guard let range = data.range(of: original) else { return }

        do {
            var next = data
            next.replaceSubrange(range, with: patched)
            try next.write(to: appAsarPath, options: .atomic)
            Log.info("codex_app_patch_ok", "status", "guard_patched_after_update")
        } catch {
            Log.info("codex_app_patch_guard_retry", "error", error.localizedDescription)
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
