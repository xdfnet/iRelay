import SwiftUI
import iRelayCore

struct MenuBarView: View {
    @ObservedObject var state: RelayState

    var body: some View {
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
        }

        Divider()

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
