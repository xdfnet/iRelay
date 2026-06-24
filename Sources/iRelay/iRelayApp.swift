import SwiftUI
import AppKit
import iRelayCore

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
            MenuBarIcon(codexEnabled: state.codexEnabled, isActive: state.activeRequestCount > 0)
        }
        .menuBarExtraStyle(.menu)
    }
}

// MARK: - 菜单栏图标（支持闪烁）

struct MenuBarIcon: View {
    let codexEnabled: Bool
    let isActive: Bool
    @State private var showFilled = true

    init(codexEnabled: Bool, isActive: Bool) {
        self.codexEnabled = codexEnabled
        self.isActive = isActive
    }

    var iconName: String {
        guard codexEnabled else { return "antenna.radiowaves.left.and.right.slash.circle.fill" }
        guard isActive else { return "antenna.radiowaves.left.and.right.circle.fill" }
        return showFilled
            ? "antenna.radiowaves.left.and.right.circle.fill"
            : "antenna.radiowaves.left.and.right.circle"
    }

    var body: some View {
        Image(systemName: iconName)
            .task(id: isActive) {
                guard isActive else {
                    showFilled = true
                    return
                }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    showFilled.toggle()
                }
            }
    }
}

// MARK: - API Key 配置窗口

@MainActor
func openApiKeyConfig(state: RelayState) {
    ApiKeyConfigWindow.shared.present(state: state)
}

// MARK: - Forms

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


// MARK: - 窗口控制器

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

