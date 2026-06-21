import Foundation
import AppKit
import iRelayCore

/// 管理 Codex 桌面版 app.asar 补丁
final class CodexAppPatcher {
    private let asar = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/app.asar")
    private let original = Data("s?t.has(n.model):!n.hidden".utf8)
    private let patched  = Data("s?!n.hidden     :!n.hidden".utf8)

    /// 打补丁，失败弹窗引导
    @discardableResult
    func ensurePatched() -> Bool {
        if applyPatch() { return true }
        DispatchQueue.main.async { [self] in showAlert() }
        return false
    }

    /// 还原补丁（反向替换）
    @discardableResult
    func restore() -> Bool {
        guard let data = try? Data(contentsOf: asar) else { return false }
        guard let r = data.range(of: patched) else { return true } // 没打过就不用还原
        var d = data
        d.replaceSubrange(r, with: original)
        do {
            try d.write(to: asar, options: .atomic)
            return true
        } catch {
            Log.error("codex_app_restore_failed", "error", error.localizedDescription)
            return false
        }
    }

    /// 读/写 asar（事务回滚用）
    func readAsar() -> Data? { try? Data(contentsOf: asar) }
    func writeAsar(_ data: Data) { try? data.write(to: asar, options: .atomic) }

    private func applyPatch() -> Bool {
        guard let data = try? Data(contentsOf: asar) else { return false }
        if data.range(of: patched) != nil { return true }
        guard let r = data.range(of: original) else { return false }
        var d = data
        d.replaceSubrange(r, with: patched)
        do {
            try d.write(to: asar, options: .atomic)
            return true
        } catch {
            Log.error("codex_app_patch_failed", "error", error.localizedDescription)
            return false
        }
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
