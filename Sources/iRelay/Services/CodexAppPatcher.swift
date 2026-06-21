import Foundation
import AppKit
import iRelayCore

/// 管理 Codex 桌面版 app.asar 补丁
final class CodexAppPatcher {
    private let appAsarPath = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/app.asar")
    private var backupPath: URL {
        appAsarPath.deletingLastPathComponent().appendingPathComponent("app.asar.bak.irelay-auto")
    }

    private let original = Data("s?t.has(n.model):!n.hidden".utf8)
    private let patched = Data("s?!n.hidden     :!n.hidden".utf8)
    private let manualPatched = Data("s?t.has(n.model)||!n.model.startsWith(`gpt-`):!n.hidden".utf8)

    private var guardActive = false
    private var alertActive = false

    // MARK: - Public

    /// 打补丁（首次），失败弹窗引导，无论成败启动后台守护
    @discardableResult
    func ensurePatched() -> Bool {
        defer { startGuard() }

        let ok = applyPatch(notify: true)
        if ok {
            Log.info("codex_app_patch_ok", "status", "patched", "backup", backupPath.path)
        }
        return ok
    }

    /// 还原补丁
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

    func stopGuard() { guardActive = false }

    func deleteBackup() {
        let path = backupPath.path
        guard FileManager.default.fileExists(atPath: path) else { return }
        try? FileManager.default.removeItem(at: backupPath)
    }

    // MARK: - 核心补丁逻辑

    /// 读 asar → 备份 → 替换 → 写回，true = 成功
    /// notify: 写入失败时是否弹窗引导权限
    private func applyPatch(notify: Bool) -> Bool {
        guard FileManager.default.fileExists(atPath: appAsarPath.path) else { return false }

        guard let data = try? Data(contentsOf: appAsarPath) else { return false }
        // 已打就不重复
        if data.range(of: patched) != nil || data.range(of: manualPatched) != nil { return true }
        // 找不到原始模式也没法打
        guard let range = data.range(of: original) else { return false }

        // 备份
        if FileManager.default.fileExists(atPath: backupPath.path) {
            try? FileManager.default.removeItem(at: backupPath)
        }
        try? FileManager.default.copyItem(at: appAsarPath, to: backupPath)

        // 替换
        var next = data
        next.replaceSubrange(range, with: patched)

        do {
            try next.write(to: appAsarPath, options: .atomic)
            return true
        } catch {
            let e = error as NSError
            if e.domain == NSPOSIXErrorDomain && (e.code == EPERM || e.code == EACCES) {
                Log.error("codex_app_patch_permission_denied",
                    "hint", "请前往 系统设置 → 隐私与安全性 → App 管理 → 启用 iRelay")
                if notify { showPermissionAlert() }
            } else {
                Log.error("codex_app_patch_failed", "error", error.localizedDescription)
            }
            return false
        }
    }

    // MARK: - 后台守护

    private func startGuard() {
        guard !guardActive else { return }
        guardActive = true
        Thread.detachNewThread { [weak self] in self?.guardLoop() }
    }

    /// 每 60 秒 stat asar mtime，变了才静默重试补丁
    private func guardLoop() {
        var lastMTime: Date?

        while guardActive {
            Thread.sleep(forTimeInterval: 60)
            guard guardActive else { break }

            let mtime = asarModificationDate()
            if mtime == lastMTime { continue }
            lastMTime = mtime

            // 静默重打（不弹窗），成了 Log，败了下轮再试
            if applyPatch(notify: false) {
                Log.info("codex_app_patch_ok", "status", "guard_patched_after_update")
            }
        }
    }

    private func asarModificationDate() -> Date? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: appAsarPath.path) else { return nil }
        return a[.modificationDate] as? Date
    }

    // MARK: - 权限弹窗

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
            let r = alert.runModal()
            alertActive = false
            if r == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    // MARK: - 备份查找

    private func restoreBackupPath() -> URL? {
        if FileManager.default.fileExists(atPath: backupPath.path) { return backupPath }
        let dir = appAsarPath.deletingLastPathComponent()
        let backups = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("app.asar.bak.irelay.") }
            .sorted { ($0.contentModificationDate ?? .distantPast) > ($1.contentModificationDate ?? .distantPast) }
        return backups.first
    }
}

private extension URL {
    var contentModificationDate: Date? {
        try? resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
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
