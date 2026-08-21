import SwiftUI

@main
struct MoontermApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
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
