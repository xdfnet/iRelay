import SwiftUI
import iRelayCore

struct MenuBarView: View {
    @ObservedObject var state: RelayState

    var body: some View {
        // 提供商切换
        if let active = state.providerStore.activeProvider {
            Menu(active.name) {
                ForEach(state.providerStore.providers) { provider in
                    Button {
                        state.switchProvider(provider.id)
                    } label: {
                        HStack {
                            Text(provider.name)
                            if provider.id == state.providerStore.activeProviderID {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Divider()
                Button("管理提供商...") { openProviderManager(state: state) }
            }
        }

        // 模型列表
        Menu("模型") {
            ForEach(state.availableModels) { model in
                Button {
                    state.selectModel(model.id)
                } label: {
                    HStack {
                        Text(model.displayName)
                        if state.codexEnabled, model.id == state.model {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            Divider()

            Button {
                state.disableCodex()
            } label: {
                HStack {
                    Text("关闭")
                    if !state.codexEnabled {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }
        }

        Divider()

        // 思考模式
        Menu("模式") {
            Button {
                state.setThinking(true)
            } label: {
                HStack {
                    Text("开启")
                    if state.thinkingEnabled {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }
            .disabled(!(state.providerStore.activeProvider?.supportsThinking ?? false))

            Button {
                state.setThinking(false)
            } label: {
                HStack {
                    Text("关闭")
                    if !state.thinkingEnabled {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }
            .disabled(!(state.providerStore.activeProvider?.supportsThinking ?? false))
        }

        Divider()

        // 配置
        Menu("配置") {
            Button("API 密钥...") { openApiKeyConfig(state: state) }
            Button("端口: \(state.port)") { openPortConfig(state: state) }
            Button("打开日志") { Log.open() }
        }

        Divider()

        Button("退出") {
            state.turnOff()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
