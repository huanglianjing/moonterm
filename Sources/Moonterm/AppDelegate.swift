import AppKit

/// 做三件 SwiftUI 管不到的事：把 ⌘W 从系统菜单手里抢回来、调整系统菜单的快捷键、退出前收干净子进程。
final class AppDelegate: NSObject, NSApplicationDelegate {

    weak var appState: AppState?

    /// ⌘W 的本地事件监视器，见 `installCloseShortcut()`。
    private var closeShortcutMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 终端底色是固定的黑，外壳（标题栏 / tab 条 / 弹窗）也固定走深色，别出现黑白拼接。
        ChromeStyle.applyDarkAppearance()

        installCloseShortcut()

        // SwiftUI 的菜单在启动流程里组装，下一轮 runloop 再改才稳。
        DispatchQueue.main.async {
            MenuCustomizer.relocateCloseWindowShortcuts()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.terminateAll()
    }

    // MARK: - ⌘W / ⇧⌘W

    /// 关闭类快捷键全部自己拦：⌘W 关当前分栏，⇧⌘W 关窗口（本 App 只有一个窗口，等于退出）。
    ///
    /// 交给菜单去匹配**不可靠**，而代价是整个 App 没了：
    ///
    /// - 系统 File 菜单排在自定义菜单前面，里面有两项都带着 w 键：「关闭窗口」（`performClose:`）
    ///   和它的替代项「全部关闭」（`closeAll:`）。AppKit 匹配时字符是不分大小写比的，
    ///   所以把「关闭窗口」写成大写 W 只改了菜单里的显示，**裸 ⌘W 照样命中它** ——
    ///   窗口一关，`applicationShouldTerminateAfterLastWindowClosed` 为 true，App 跟着退出。
    /// - SwiftUI 那条「关闭标签页」菜单项在 `focusedSession == nil` 时是禁用的
    ///   （没有连接、焦点会话刚被销毁都属于这种），一禁用 ⌘W 就漏给了上面两项。
    ///   这就是「偶尔按 ⌘W 整个程序就没了」的来历。
    ///
    /// 本地事件监视器在菜单快捷键匹配之前拿到 keyDown，是唯一稳的位置。菜单项都照旧留着 ——
    /// 用鼠标点一样能用，也让人看得见快捷键分别是 ⌘W 和 ⇧⌘W。
    private func installCloseShortcut() {
        closeShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let kind = Self.closeShortcut(event) else { return event }

            switch kind {
            case .session:
                closeFocusedSession()
            case .window:
                // 弹窗在前时 `keyWindow` 是那张 sheet，关它没有意义 —— 认主窗口。
                NSApp.mainWindow?.performClose(nil)
            }
            // 一律吞掉：漏下去就会被 File 菜单里那两项接走，那是关窗口 = 退出 App。
            return nil
        }
    }

    private enum CloseShortcut {
        /// ⌘W：关当前分栏。
        case session
        /// ⇧⌘W：关窗口。
        case window
    }

    private static func closeShortcut(_ event: NSEvent) -> CloseShortcut? {
        guard event.charactersIgnoringModifiers?.lowercased() == "w" else { return nil }
        switch event.modifierFlags.intersection(.deviceIndependentFlagsMask) {
        case [.command]: return .session
        case [.command, .shift]: return .window
        // ⌥⌘W（「全部关闭」）和别的组合不接：本 App 只有一个窗口，多一条路只是多一个误关的机会。
        default: return nil
        }
    }

    private func closeFocusedSession() {
        guard let appState else { return }
        // 弹窗（主机管理 / 主机编辑）在前时不去动它背后的分栏 —— 弹窗自己用 Esc / 回车收尾。
        guard NSApp.keyWindow?.attachedSheet == nil else { return }
        // 正在改名：焦点在输入框里，这时候把它要改的那个窗口关掉太突然。
        guard appState.sessionBeingRenamed == nil else { return }
        appState.closeFocusedSession()
    }
}

/// 把系统菜单里那几个带 w 键的项挪到 ⇧⌘W 一侧，⌘W 留给「关闭当前分栏」——
/// 这是终端类 App 的通行做法。
///
/// 注意这里只管**菜单里显示成什么样**：真正决定按键落到哪儿的是
/// `AppDelegate.installCloseShortcut()`，它在菜单匹配之前就把 ⌘W / ⇧⌘W 都接走了。
/// 这两处得对上，别让菜单写着一个键、按下去是另一回事。
enum MenuCustomizer {

    static func relocateCloseWindowShortcuts() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let performClose = #selector(NSWindow.performClose(_:))
        // 「全部关闭」在 AppKit 里是「关闭窗口」的替代项（isAlternate），选择器没有公开常量。
        let closeAll = Selector(("closeAll:"))

        for topLevelItem in mainMenu.items {
            guard let submenu = topLevelItem.submenu else { continue }
            for item in submenu.items {
                guard item.keyEquivalent.lowercased() == "w" else { continue }

                // 键位统一写小写 + 用修饰键表达 ⇧：大写字面量只影响菜单显示，
                // AppKit 比对字符时不分大小写。
                switch item.action {
                case performClose:
                    item.keyEquivalent = "w"
                    item.keyEquivalentModifierMask = [.command, .shift]
                case closeAll:
                    item.keyEquivalent = "w"
                    item.keyEquivalentModifierMask = [.command, .option, .shift]
                default:
                    // 我们自己那条「关闭标签页」（⌘W）不动。
                    continue
                }
            }
        }
    }
}
