import SwiftUI

/// 把会话**已有的**终端视图摆进 SwiftUI 层级。
///
/// 关键点：`makeNSView` 返回的是 `SSHSession` 长期持有的实例，不在这里新建。
/// 视图不被销毁重建，切 tab 时 PTY 与 ssh 进程都不受影响。
struct TerminalContainer: NSViewRepresentable {

    let session: SSHSession

    func makeNSView(context: Context) -> SSHTerminalView {
        session.terminalView
    }

    func updateNSView(_ nsView: SSHTerminalView, context: Context) {
        // 尺寸交给 AppKit 的 layout，字号变化由 AppState 直接推给会话，这里无事可做。
    }
}
