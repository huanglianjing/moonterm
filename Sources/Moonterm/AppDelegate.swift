import AppKit

/// 做两件 SwiftUI 管不到的事：调整系统菜单的快捷键、退出前收干净子进程。
final class AppDelegate: NSObject, NSApplicationDelegate {

    weak var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 终端底色是固定的黑，外壳（标题栏 / tab 条 / 弹窗）也固定走深色，别出现黑白拼接。
        ChromeStyle.applyDarkAppearance()

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

/// 系统 File 菜单里的「关闭窗口」默认占用 ⌘W，会抢掉我们的「关闭当前分栏」。
/// 把它挪到 ⇧⌘W，⌘W 留给关闭分栏 —— 这也是终端类 App 的通行做法。
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
                // 必须写成**大写 W + 只带 .command**。
                //
                // 写成小写 "w" + [.command, .shift] 看着也像 ⇧⌘W（菜单里显示也没问题），
                // 但 AppKit 匹配快捷键时按小写字面量比对，裸 ⌘W 依然会命中这一项：
                // File 菜单排在自定义菜单前面，于是 ⌘W 关掉的是 App 唯一的窗口
                // （`applicationShouldTerminateAfterLastWindowClosed` 为 true → 整个 App 退出），
                // 而不是我们想关的那个分栏。
                item.keyEquivalent = "W"
                item.keyEquivalentModifierMask = [.command]
            }
        }
    }
}
