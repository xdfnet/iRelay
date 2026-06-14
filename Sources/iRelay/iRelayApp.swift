import SwiftUI
import AppKit

@main
struct iRelayApp: App {
    @StateObject private var state = RelayState()

    init() {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(state: state)
        } label: {
            Image(systemName: state.codexEnabled ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
        }
        .menuBarExtraStyle(.menu)
    }
}

// MARK: - API Key 配置窗口

@MainActor
func openApiKeyConfig(state: RelayState) {
    ApiKeyConfigWindow.shared.present(state: state)
}

// MARK: - SwiftUI 内容

private struct ApiKeyFormView: View {
    @State private var keyInput = ""
    let currentKey: String
    let onSave: (String) -> Void
    let onDismiss: () -> Void

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

// MARK: - 窗口控制器

@MainActor
private final class ApiKeyConfigWindow: NSWindowController {
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

    func dismiss() {
        window?.close()
    }
}
