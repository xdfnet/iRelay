import SwiftUI
import iRelayCore

struct MenuBarView: View {
    @ObservedObject var state: RelayState

    var body: some View {
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

        Button("密钥设置...") { openApiKeyConfig(state: state) }
        Button("打开日志") { Log.open() }

        Divider()

        Button {
            state.toggleCodex()
        } label: {
            HStack {
                Text(state.codexEnabled ? "关闭 Codex 集成" : "开启 Codex 集成")
                Spacer()
                if !state.codexEnabled {
                    Image(systemName: "checkmark")
                }
            }
        }

        Divider()

        Button("退出") {
            state.turnOff()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
