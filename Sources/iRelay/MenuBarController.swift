import Cocoa
import iRelayCore

@MainActor
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private let state: RelayState
    private var blinkTimer: Timer?
    private var showFilled = true

    init(state: RelayState) {
        self.state = state
        super.init()
        setup()
    }

    // MARK: - Setup

    private func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        button.action = #selector(buttonClicked)
        button.target = self
        updateIcon()

        // 监听数据流变化
        state.onActivityChanged = { [weak self] in
            self?.updateIcon()
        }
    }

    // MARK: - Icon

    private func updateIcon() {
        let name: String
        if state.activeRequestCount > 0 {
            name = showFilled
                ? "antenna.radiowaves.left.and.right.circle.fill"
                : "antenna.radiowaves.left.and.right.circle"
            startBlinking()
        } else {
            name = state.codexEnabled
                ? "antenna.radiowaves.left.and.right.circle.fill"
                : "antenna.radiowaves.left.and.right.slash.circle.fill"
            stopBlinking()
        }

        if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            img.size = NSSize(width: 16, height: 16)
            statusItem?.button?.image = img
        }
    }

    private func startBlinking() {
        guard blinkTimer == nil else { return }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.showFilled.toggle()
                self.updateIcon()
            }
        }
    }

    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        showFilled = true
    }

    // MARK: - Menu

    @objc private func buttonClicked() {
        statusItem?.menu = buildMenu()
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let proxy = NSMenuItem(title: state.codexEnabled ? "关闭代理" : "开启代理",
                               action: #selector(toggleProxy), keyEquivalent: "")
        proxy.target = self
        menu.addItem(proxy)

        let patch = NSMenuItem(title: state.isCodexPatched ? "关闭补丁" : "开启补丁",
                               action: #selector(togglePatch), keyEquivalent: "")
        patch.target = self
        menu.addItem(patch)

        menu.addItem(.separator())

        let apiKey = NSMenuItem(title: "设置密钥", action: #selector(openConfig), keyEquivalent: "")
        apiKey.target = self
        menu.addItem(apiKey)

        let log = NSMenuItem(title: "打开日志", action: #selector(openLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    // MARK: - Actions

    @objc private func toggleProxy() {
        state.toggleCodex()
        updateIcon()
    }

    @objc private func togglePatch() {
        state.toggleCodexAsar()
    }

    @objc private func openConfig() {
        openApiKeyConfig(state: state)
    }

    @objc private func openLog() {
        Log.open()
    }

    @objc private func quitApp() {
        state.turnOff()
        NSApplication.shared.terminate(nil)
    }

    deinit {
        blinkTimer?.invalidate()
    }
}
