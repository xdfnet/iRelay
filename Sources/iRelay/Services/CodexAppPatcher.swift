import Foundation
import AppKit
import iRelayCore

/// 管理 Codex 桌面版 app.asar 补丁
final class CodexAppPatcher {
    private let asar = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/app.asar")
    private let original = Data("s?t.has(n.model):!n.hidden".utf8)
    private let patched  = Data("s?!n.hidden     :!n.hidden".utf8)

    private var guardActive = false

    /// 打补丁，失败弹窗引导用户授权
    @discardableResult
    func ensurePatched() -> Bool {
        if applyPatch() {
            startGuard()
            return true
        }
        // 写失败（权限问题）→ 弹窗引导
        DispatchQueue.main.async { [self] in showAlert() }
        return false
    }

    // MARK: - 打补丁

    /// 读 → 替换 → 写回，true = 成功
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

    // MARK: - 弹窗

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
            // 用户授权回来后自动重试
            if !applyPatch() { showAlert() }
        default:
            NSApp.terminate(nil)
        }
    }

    // MARK: - 守护

    private func startGuard() {
        guard !guardActive else { return }
        guardActive = true
        Thread.detachNewThread { [weak self] in self?.guardLoop() }
    }

    private func guardLoop() {
        var last: Date?
        while guardActive {
            Thread.sleep(forTimeInterval: 60)
            guard guardActive else { break }
            let m = (try? FileManager.default.attributesOfItem(atPath: asar.path))?[.modificationDate] as? Date
            if m == last { continue }; last = m
            if applyPatch() { Log.info("codex_app_patch_ok", "status", "guard_repatch") }
        }
    }

    func stopGuard() { guardActive = false }
}
