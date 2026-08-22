import AppKit

/// 「点终端就聚焦所在分栏」的实现。
///
/// SwiftTerm 的 `becomeFirstResponder` 是 `public override` 而不是 `open`，模块外没法重写；
/// 它自己也不会在 `mouseDown` 里抢 firstResponder。所以这里在窗口层面监听鼠标按下，
/// 命中哪个终端视图就报给外面。事件原样放行，终端的选区与点击行为不受影响。
final class TerminalFocusMonitor {

    private var monitor: Any?

    func start(onHit: @escaping (SSHTerminalView) -> Void) {
        guard monitor == nil else { return }
        // 右键也算「点了这一栏」：右键即粘贴，内容得落在用户以为的那个分栏里。
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            if let view = Self.terminalView(for: event) {
                onHit(view)
            }
            return event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    deinit {
        stop()
    }

    /// 从命中点往上找最近的终端视图（SwiftTerm 内部还有光标之类的子视图）。
    private static func terminalView(for event: NSEvent) -> SSHTerminalView? {
        guard let contentView = event.window?.contentView else { return nil }
        var candidate = contentView.hitTest(event.locationInWindow)
        while let view = candidate {
            if let terminal = view as? SSHTerminalView { return terminal }
            candidate = view.superview
        }
        return nil
    }
}
