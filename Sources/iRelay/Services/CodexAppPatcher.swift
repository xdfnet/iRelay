import Foundation
import AppKit
import iRelayCore

/// 管理 Codex 桌面版 app.asar 补丁
final class CodexAppPatcher {
    private let asar = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/app.asar")
    private let backup = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/app.asar.bak")
    /// 注意：Codex 每次升级可能改变 minifier 变量名（s→l 等），若失效需同步更新
    private let original = Data("l?t.has(n.model):!n.hidden".utf8)
    private let patched  = Data("l?!n.hidden     :!n.hidden".utf8)

    /// 检测是否已打补丁（不修改文件）
    var isPatched: Bool {
        guard let data = try? Data(contentsOf: asar) else { return false }
        return data.range(of: patched) != nil
    }

    /// 检测 App 管理权限（试探写入临时文件）
    private var hasAppManagementPermission: Bool {
        let testFile = asar.deletingLastPathComponent().appendingPathComponent(".irelay_perm_test")
        do {
            try Data("test".utf8).write(to: testFile, options: .atomic)
            try FileManager.default.removeItem(at: testFile)
            return true
        } catch {
            return false
        }
    }

    /// 检查权限，无权限则弹窗引导，返回是否已就绪
    @discardableResult
    func ensurePermission() -> Bool {
        guard !hasAppManagementPermission else { return true }
        showPermissionAlert()
        return false
    }

    /// 备份 → 打补丁，调用前需 ensurePermission
    @discardableResult
    func ensurePatched() -> Bool {
        guard let data = try? Data(contentsOf: asar) else { return false }
        if data.range(of: patched) != nil { return true }
        guard data.range(of: original) != nil else { return false }

        do {
            if FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.removeItem(at: backup)
            }
            try FileManager.default.copyItem(at: asar, to: backup)
            return applyPatch(data)
        } catch {
            Log.error("codex_app_patch_failed", "error", error.localizedDescription)
            return false
        }
    }

    /// 从备份还原 asar，调用前需 ensurePermission
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

    private func applyPatch(_ data: Data) -> Bool {
        guard let r = data.range(of: original) else { return false }
        var d = data
        d.replaceSubrange(r, with: patched)
        try? d.write(to: asar, options: .atomic)
        return true
    }

    private func showPermissionAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "需要「App 管理」权限"
            alert.informativeText = "iRelay 需要修改 Codex 桌面版才能显示 DeepSeek 模型。\n\n请前往：系统设置 → 隐私与安全性 → App 管理 → 开启 iRelay"
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "取消")
            alert.alertStyle = .warning
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
