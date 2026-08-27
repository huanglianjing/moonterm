import MoontermCore
import SwiftUI

/// 菜单栏与快捷键。
struct AppCommands: Commands {

    @ObservedObject var appState: AppState

    var body: some Commands {
        // 去掉「新建窗口」，换成「新建连接」。本 App 只用一个窗口，多连接靠 tab 与分栏。
        // 选主机的地方只有一处 —— 左侧竖栏的主机面板，所以这里就是把它展开。
        CommandGroup(replacing: .newItem) {
            Button("新建连接…") {
                appState.revealHosts()
            }
        }

        CommandGroup(replacing: .appSettings) {
            Button("主机…") {
                appState.isHostManagerPresented = true
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandMenu("连接") {
            Button("重新连接") {
                appState.reconnectFocused()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(appState.focusedSession == nil)

            Divider()

            // tab 里只有一个窗口时，⌘W 关掉的就是整个 tab —— 菜单文案跟着变，免得歧义。
            Button(appState.selectedTab?.sessionCount ?? 0 > 1 ? "关闭当前窗口" : "关闭标签页") {
                appState.closeFocusedSession()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(appState.focusedSession == nil)

            // 装了不止一个窗口时才需要「连整个 tab 一起关」，否则和上面那条重复。
            if appState.selectedTab?.sessionCount ?? 0 > 1 {
                Button("关闭标签页（含全部窗口）") {
                    if let id = appState.selectedTabID {
                        appState.close(tabID: id)
                    }
                }
            }

            Button("关闭其他标签页") {
                if let id = appState.selectedTabID {
                    appState.closeOtherTabs(keeping: id)
                }
            }
            .disabled(appState.tabs.count < 2)
        }

        // 分栏一律用当前标签页绑定的那台主机，不再问选哪台 —— 一个 tab 只装一台主机。
        CommandMenu("分栏") {
            Button("左右分栏") {
                appState.splitFocused(.trailing)
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(appState.selectedTab == nil)

            Button("上下分栏") {
                appState.splitFocused(.bottom)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(appState.selectedTab == nil)

            Button("在当前分栏新建窗口") {
                appState.addWindowToFocusedPane()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(appState.selectedTab == nil)

            Divider()

            Button("重命名当前分栏…") {
                appState.beginRenamingFocusedSession()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(appState.selectedTab == nil)

            Divider()

            Button("聚焦左侧分栏") { appState.moveFocus(.leading) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("聚焦右侧分栏") { appState.moveFocus(.trailing) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("聚焦上方分栏") { appState.moveFocus(.top) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("聚焦下方分栏") { appState.moveFocus(.bottom) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
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
            Button(appState.activeSidebar == .hosts ? "隐藏主机面板" : "显示主机面板") {
                appState.toggleSidebar(.hosts)
            }
            .keyboardShortcut("b", modifiers: .command)

            Button(appState.activeSidebar == .files ? "隐藏文件面板" : "显示文件面板") {
                appState.toggleSidebar(.files)
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])

            Divider()

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
