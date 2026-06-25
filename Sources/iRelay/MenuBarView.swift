import SwiftUI
import iRelayCore

struct MenuBarView: View {
    @ObservedObject var state: RelayState

    var body: some View {
        Button(state.codexEnabled ? "关闭代理" : "开启代理") {
            state.toggleCodex()
        }

        Button {
            state.toggleCodexAsar()
        } label: {
            Text(verbatim: state.isCodexPatched ? "关闭补丁" : "开启补丁")
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
