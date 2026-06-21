import SwiftUI
import iRelayCore

struct MenuBarView: View {
    @ObservedObject var state: RelayState

    var body: some View {
        Button(state.codexEnabled ? "关闭 Codex 集成" : "开启 Codex 集成") {
            state.toggleCodex()
        }

        Divider()

        Button {
            state.setThinking(!state.thinkingEnabled)
        } label: {
            HStack {
                Text(verbatim: "推理模式")
                Spacer()
                if state.thinkingEnabled {
                    Image(systemName: "checkmark")
                }
            }
        }

        Divider()

        Button(action: { openApiKeyConfig(state: state) }) { Text(verbatim: "设置密钥") }
        Button(action: { Log.open() }) { Text(verbatim: "打开日志") }

        Divider()

        Button(action: { state.turnOff(); NSApplication.shared.terminate(nil) }) {
            Text(verbatim: "退出")
        }
        .keyboardShortcut("q")
    }
}
