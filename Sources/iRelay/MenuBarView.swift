import SwiftUI
import iRelayCore

struct MenuBarView: View {
    @ObservedObject var state: RelayState

    var body: some View {
        Button(state.codexEnabled ? "关闭 Codex 集成" : "开启 Codex 集成") {
            state.toggleCodex()
        }

        Divider()

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
            state.setThinking(!state.thinkingEnabled)
        } label: {
            HStack {
                Text("推理模式")
                Spacer()
                if state.thinkingEnabled {
                    Image(systemName: "checkmark")
                }
            }
        }

        Divider()

        Button("设置密钥") { openApiKeyConfig(state: state) }
        Button("打开日志") { Log.open() }

        Divider()

        Button("退出") {
            state.turnOff()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
