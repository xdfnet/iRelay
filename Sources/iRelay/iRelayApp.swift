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
    guard let p = state.providerStore.activeProvider else { return }
    ApiKeyConfigWindow.shared.present(state: state, providerName: p.name)
}

@MainActor
func openProviderManager(state: RelayState) {
    ProviderManagerWindow.shared.present(state: state)
}

@MainActor
func openPortConfig(state: RelayState) {
    PortConfigWindow.shared.present(state: state)
}

// MARK: - API Key Form

private struct ApiKeyFormView: View {
    @State private var keyInput = ""
    let currentKey: String
    let providerName: String
    let onSave: (String) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("\(providerName) API Key")
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

// MARK: - 端口配置窗口

private struct PortConfigFormView: View {
    @State private var portInput = ""
    let currentPort: UInt16
    let onSave: (UInt16) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("服务器端口")
                .font(.headline)
            TextField("8787", text: $portInput)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("取消") { onDismiss() }
                    .keyboardShortcut(.escape)
                Button("保存") {
                    if let p = UInt16(portInput), p > 0 {
                        onSave(p)
                    }
                    onDismiss()
                }
                .keyboardShortcut(.return)
                .disabled(portInput.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 280)
        .onAppear { portInput = String(currentPort) }
    }
}

// MARK: - 提供商管理窗口

private struct ProviderManagerFormView: View {
    @State private var providers: [ProviderConfig]
    @State private var newName = ""
    @State private var newURL = ""
    @State private var newKey = ""
    let onUpdate: ([ProviderConfig]) -> Void
    let onDismiss: () -> Void

    init(providers: [ProviderConfig], onUpdate: @escaping ([ProviderConfig]) -> Void, onDismiss: @escaping () -> Void) {
        _providers = State(initialValue: providers)
        self.onUpdate = onUpdate
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("管理提供商")
                .font(.headline)

            List {
                ForEach(providers.indices, id: \.self) { i in
                    VStack(alignment: .leading) {
                        Text(providers[i].name).font(.subheadline).bold()
                        Text(providers[i].baseURL).font(.caption).foregroundColor(.secondary)
                    }
                }
                .onDelete { idx in
                    providers.remove(atOffsets: idx)
                }
            }
            .frame(minHeight: 120)

            Divider()

            Text("添加自定义提供商").font(.subheadline)
            TextField("名称", text: $newName)
                .textFieldStyle(.roundedBorder)
            TextField("https://api.example.com", text: $newURL)
                .textFieldStyle(.roundedBorder)
            TextField("API Key（可选）", text: $newKey)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("取消") { onDismiss() }
                    .keyboardShortcut(.escape)
                Button("保存") {
                    if !newName.isEmpty, !newURL.isEmpty {
                        var c = ProviderConfig.custom(baseURL: newURL)
                        c.name = newName
                        c.apiKey = newKey
                        providers.append(c)
                        newName = ""
                        newURL = ""
                        newKey = ""
                    }
                }
                .disabled(newName.isEmpty || newURL.isEmpty)
            }

            HStack {
                Button("保存并关闭") {
                    onUpdate(providers)
                    onDismiss()
                }
                .keyboardShortcut(.return)
            }
        }
        .padding(20)
        .frame(width: 420)
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

    func present(state: RelayState, providerName: String) {
        let dismissAction = { [weak self] in self?.dismiss(); () }
        let view = ApiKeyFormView(
            currentKey: state.apiKey,
            providerName: providerName,
            onSave: { _ = state.saveApiKey($0) },
            onDismiss: dismissAction
        )
        window?.contentViewController = NSHostingController(rootView: view)
        window?.title = "\(providerName) API Key"
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() { window?.close() }
}

@MainActor
private final class PortConfigWindow: NSWindowController {
    static let shared = PortConfigWindow()

    private init() {
        let hosting = NSHostingController(rootView: EmptyView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "配置端口"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(state: RelayState) {
        let dismissAction = { [weak self] in self?.dismiss(); () }
        let view = PortConfigFormView(
            currentPort: state.port,
            onSave: { state.port = $0 },
            onDismiss: dismissAction
        )
        window?.contentViewController = NSHostingController(rootView: view)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() { window?.close() }
}

@MainActor
private final class ProviderManagerWindow: NSWindowController {
    static let shared = ProviderManagerWindow()

    private init() {
        let hosting = NSHostingController(rootView: EmptyView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "管理提供商"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(state: RelayState) {
        let dismissAction = { [weak self] in self?.dismiss(); () }
        let view = ProviderManagerFormView(
            providers: state.providerStore.providers,
            onUpdate: { updated in
                // 简单替换：保留 id 不变，更新其他字段
                for cfg in updated {
                    if let idx = state.providerStore.providers.firstIndex(where: { $0.id == cfg.id }) {
                        state.providerStore.updateProvider(cfg)
                    } else {
                        state.providerStore.addProvider(cfg)
                    }
                }
                // 删除不在列表中的
                let updatedIDs = Set(updated.map(\.id))
                for p in state.providerStore.providers {
                    if !updatedIDs.contains(p.id) {
                        state.providerStore.deleteProvider(p.id)
                    }
                }
            },
            onDismiss: dismissAction
        )
        window?.contentViewController = NSHostingController(rootView: view)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() { window?.close() }
}
