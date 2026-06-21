import Foundation
import AppKit
import iRelayCore

/// 管理 Codex 桌面版 app.asar 补丁
///
/// 启动时权限不通会阻塞引导，直到用户授权或退出 App。
/// 启动成功后权限就是通的，后台只验补丁完整性，不再关心权限。
final class CodexAppPatcher {
    private let appAsarPath = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/app.asar")
    private var backupPath: URL {
        appAsarPath.deletingLastPathComponent().appendingPathComponent("app.asar.bak.irelay-auto")
    }

    private let original = Data("s?t.has(n.model):!n.hidden".utf8)
    private let patched = Data("s?!n.hidden     :!n.hidden".utf8)
    private let manualPatched = Data("s?t.has(n.model)||!n.model.startsWith(`gpt-`):!n.hidden".utf8)

    private var guardActive = false

    // MARK: - Public

    /// 打补丁，权限不通则阻塞直到用户授权或退出
    @discardableResult
    func ensurePatched() -> Bool {
        defer { startGuard() }

        if applyPatch() { return true }

        // 延迟弹窗，等主循环就绪
        DispatchQueue.main.async { [self] in showBlockingAlert() }
        return false
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

    func stopGuard() { guardActive = false }

    func deleteBackup() {
        let path = backupPath.path
        guard FileManager.default.fileExists(atPath: path) else { return }
        try? FileManager.default.removeItem(at: backupPath)
    }

    // MARK: - 打补丁

    private func applyPatch() -> Bool {
        guard FileManager.default.fileExists(atPath: appAsarPath.path) else { return false }
        guard let data = try? Data(contentsOf: appAsarPath) else { return false }
        if data.range(of: patched) != nil || data.range(of: manualPatched) != nil {
            return probeWrite(data)
        }
        guard let range = data.range(of: original) else { return false }

        if FileManager.default.fileExists(atPath: backupPath.path) {
            try? FileManager.default.removeItem(at: backupPath)
        }
        try? FileManager.default.copyItem(at: appAsarPath, to: backupPath)

        var next = data
        next.replaceSubrange(range, with: patched)

        do {
            try next.write(to: appAsarPath, options: .atomic)
            return true
        } catch {
            logWriteError(error)
            return false
        }
    }

    /// 原样写回，验证写入权限仍通
    private func probeWrite(_ data: Data) -> Bool {
        do {
            try data.write(to: appAsarPath, options: .atomic)
            return true
        } catch {
            logWriteError(error)
            return false
        }
    }

    private func logWriteError(_ error: Error) {
        let e = error as NSError
        if e.domain == NSPOSIXErrorDomain && (e.code == EPERM || e.code == EACCES) {
            Log.error("codex_app_patch_permission_denied",
                "hint", "请前往 系统设置 → 隐私与安全性 → App 管理 → 启用 iRelay")
        } else {
            Log.error("codex_app_patch_failed", "error", error.localizedDescription)
        }
    }

    // MARK: - 守护线程

    private func startGuard() {
        guard !guardActive else { return }
        guardActive = true
        Thread.detachNewThread { [weak self] in self?.guardLoop() }
    }

    private func guardLoop() {
        var lastMTime: Date?

        while guardActive {
            Thread.sleep(forTimeInterval: 60)
            guard guardActive else { break }

            let mtime = asarModificationDate()
            if mtime == lastMTime { continue }
            lastMTime = mtime

            if applyPatch() {
                Log.info("codex_app_patch_ok", "status", "guard_patched_after_update")
            }
        }
    }

    private func asarModificationDate() -> Date? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: appAsarPath.path) else { return nil }
        return a[.modificationDate] as? Date
    }

    // MARK: - 阻塞权限引导

    private func showBlockingAlert() {
        while true {
            let alert = NSAlert()
            alert.messageText = "需要「App 管理」权限"
            alert.informativeText = "iRelay 需要修改 Codex 桌面版才能显示 DeepSeek 模型。\n\n请前往：系统设置 → 隐私与安全性 → App 管理 → 开启 iRelay"
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "退出 iRelay")
            alert.alertStyle = .warning

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles") {
                    NSWorkspace.shared.open(url)
                }
                if applyPatch() { return }

            default:
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - 备份

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
