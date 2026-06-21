import Foundation
import AppKit
import iRelayCore

/// 管理 Codex 桌面版 app.asar 补丁
final class CodexAppPatcher {
    private let asar = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/app.asar")
    private let backup = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/app.asar.bak")
    private let original = Data("s?t.has(n.model):!n.hidden".utf8)
    private let patched  = Data("s?!n.hidden     :!n.hidden".utf8)

    /// 备份 → 打补丁，失败弹窗引导
    @discardableResult
    func ensurePatched() -> Bool {
        do {
            // 1. 删除旧备份
            if FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.removeItem(at: backup)
            }
            // 2. 备份
            try FileManager.default.copyItem(at: asar, to: backup)
            // 3. 打补丁
            return applyPatch()
        } catch {
            Log.error("codex_app_patch_failed", "error", error.localizedDescription)
            DispatchQueue.main.async { [self] in showAlert() }
            return false
        }
    }

    /// 从备份还原 asar（关闭集成用）
    @discardableResult
    func restoreFromBackup() -> Bool {
        guard FileManager.default.fileExists(atPath: backup.path) else { return true }
        do {
            if FileManager.default.fileExists(atPath: asar.path) {
                try FileManager.default.removeItem(at: asar)
            }
            try FileManager.default.copyItem(at: backup, to: asar)
            try FileManager.default.removeItem(at: backup)
            return true
        } catch {
            Log.error("codex_app_restore_failed", "error", error.localizedDescription)
            return false
        }
    }

    /// 删备份（enable 回滚用）
    func deleteBackup() {
        if FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.removeItem(at: backup)
        }
    }

    private func applyPatch() -> Bool {
        guard let data = try? Data(contentsOf: asar) else { return false }
        if data.range(of: patched) != nil { return true }
        guard let r = data.range(of: original) else { return false }
        var d = data
        d.replaceSubrange(r, with: patched)
        try? d.write(to: asar, options: .atomic)
        return true
    }

    private func showAlert() {
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
            if !applyPatch() { showAlert() }
        default:
            NSApp.terminate(nil)
        }
    }
}
