import AppKit

/// 做两件 SwiftUI 管不到的事：调整系统菜单的快捷键、退出前收干净子进程。
final class AppDelegate: NSObject, NSApplicationDelegate {

    weak var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI 的菜单在启动流程里组装，下一轮 runloop 再改才稳。
        DispatchQueue.main.async {
            MenuCustomizer.relocateCloseWindowShortcut()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.terminateAll()
    }
}

/// 系统 File 菜单里的「关闭窗口」默认占用 ⌘W，会抢掉我们的「关闭标签页」。
/// 把它挪到 ⇧⌘W，⌘W 留给关闭 tab —— 这也是终端类 App 的通行做法。
enum MenuCustomizer {

    static func relocateCloseWindowShortcut() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let performClose = #selector(NSWindow.performClose(_:))

        for topLevelItem in mainMenu.items {
            guard let submenu = topLevelItem.submenu else { continue }
            for item in submenu.items where item.action == performClose {
                guard item.keyEquivalent == "w",
                      item.keyEquivalentModifierMask == [.command]
                else { continue }
                // 小写字母 + 显式 .shift：AppKit 里这是 ⇧⌘W 的规范写法。
                item.keyEquivalent = "w"
                item.keyEquivalentModifierMask = [.command, .shift]
            }
        }
    }
}
