import SwiftUI
import AppKit
import iRelayCore

@main
struct iRelayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            Color.clear.frame(width: 0, height: 0).hidden()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 0, height: 0)
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = RelayState()
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menuBarController = MenuBarController(state: state)
    }
}

// MARK: - API Key 配置窗口

@MainActor
func openApiKeyConfig(state: RelayState) {
    ApiKeyConfigWindow.shared.present(state: state)
}

struct ApiKeyFormView: View {
    @State private var keyInput = ""
    let currentKey: String
    let onSave: (String) -> Void
    let onDismiss: () -> Void

    init(currentKey: String, onSave: @escaping (String) -> Void, onDismiss: @escaping () -> Void) {
        self._keyInput = State(initialValue: currentKey)
        self.currentKey = currentKey
        self.onSave = onSave
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("DeepSeek API Key")
                .font(.headline)
            TextField("sk-xxxxxxxxxxxxxxxx", text: $keyInput)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("取消") { onDismiss() }
                    .keyboardShortcut(.escape)
                Button("保存") {
                    onSave(keyInput)
                    onDismiss()
                }
                .keyboardShortcut(.return)
                .disabled(keyInput.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear { keyInput = currentKey }
    }
}

@MainActor
final class ApiKeyConfigWindow: NSWindowController {
    static let shared = ApiKeyConfigWindow()

    private init() {
        let hosting = NSHostingController(rootView: EmptyView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "配置 API Key"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(state: RelayState) {
        let dismissAction = { [weak self] in self?.dismiss(); () }
        let view = ApiKeyFormView(
            currentKey: state.apiKey,
            onSave: { _ = state.saveApiKey($0) },
            onDismiss: dismissAction
        )
        window?.contentViewController = NSHostingController(rootView: view)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() { window?.close() }
}
