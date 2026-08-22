import SwiftUI

@main
struct MoontermApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                // 拖拽状态单独注入：只有 tab 条和落点提示层观察它，拖拽时不会带着整棵分栏树重画。
                .environmentObject(appState.drag)
                .onAppear {
                    // 让 AppDelegate 能在退出前终止所有 ssh 进程。
                    appDelegate.appState = appState
                }
        }
        .defaultSize(width: 1040, height: 660)
        .commands {
            AppCommands(appState: appState)
        }
    }
}
