import SwiftUI

/// 菜单栏与快捷键。
struct AppCommands: Commands {

    @ObservedObject var appState: AppState

    var body: some Commands {
        // 去掉「新建窗口」，换成「新建连接」。本 App 只用一个窗口，多连接靠 tab。
        CommandGroup(replacing: .newItem) {
            Button("新建连接…") {
                appState.isHostPickerPresented = true
            }
            .keyboardShortcut("t", modifiers: .command)
        }

        CommandGroup(replacing: .appSettings) {
            Button("主机…") {
                appState.isHostManagerPresented = true
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandMenu("连接") {
            Button("重新连接") {
                appState.reconnectSelected()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(appState.selectedSession == nil)

            Divider()

            Button("关闭标签页") {
                appState.closeSelected()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(appState.selectedSession == nil)

            Button("关闭其他标签页") {
                if let id = appState.selectedSessionID {
                    appState.closeOthers(keeping: id)
                }
            }
            .disabled(appState.sessions.count < 2)
        }

        CommandMenu("标签页") {
            Button("下一个标签页") {
                appState.selectNext()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])

            Button("上一个标签页") {
                appState.selectPrevious()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])

            Divider()

            ForEach(1...9, id: \.self) { index in
                Button("第 \(index) 个标签页") {
                    appState.select(index: index - 1)
                }
                .keyboardShortcut(
                    KeyEquivalent(Character(String(index))),
                    modifiers: .command
                )
            }
        }

        CommandGroup(after: .sidebar) {
            Button("放大字号") {
                appState.increaseFontSize()
            }
            .keyboardShortcut("+", modifiers: .command)

            Button("缩小字号") {
                appState.decreaseFontSize()
            }
            .keyboardShortcut("-", modifiers: .command)

            Button("恢复默认字号") {
                appState.resetFontSize()
            }
            .keyboardShortcut("0", modifiers: .command)
        }
    }
}
