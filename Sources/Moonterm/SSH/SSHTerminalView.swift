import AppKit
import SwiftTerm

/// 观察 PTY 原始输出的钩子（用于密码兜底注入与失败归因）。
protocol SSHTerminalViewObserver: AnyObject {
    func terminalView(_ view: SSHTerminalView, didReceiveOutput slice: ArraySlice<UInt8>)
}

/// `LocalProcessTerminalView` 已经把 forkpty、PTY 读写、窗口大小同步（TIOCSWINSZ）、
/// VT/xterm 解析、滚动缓冲、选区与复制粘贴全做了。这里只加三件事：
///
/// - 把原始输出抄送给观察者
/// - 视图第一次拿到真实尺寸时回调，让会话在正确的行列数下启动 ssh
///   （否则远端 shell 会先以 80x25 启动再 reflow）
/// - 选中即复制、右键即粘贴（终端里的老习惯，SwiftTerm 默认只认 ⌘C / ⌘V）
final class SSHTerminalView: LocalProcessTerminalView {

    weak var observer: SSHTerminalViewObserver?

    /// 只触发一次：视图第一次具备非零尺寸时。
    var onReadyForProcess: (() -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        observer?.terminalView(self, didReceiveOutput: slice)
    }

    // MARK: - 尺寸就绪

    override func layout() {
        super.layout()
        notifyIfReady()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        notifyIfReady()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        notifyIfReady()
    }

    private func notifyIfReady() {
        guard let callback = onReadyForProcess,
              bounds.width > 1,
              bounds.height > 1
        else { return }
        onReadyForProcess = nil
        callback()
    }

    // MARK: - 选中即复制

    /// 松开左键时选区里有东西就直接进剪贴板，不用再按 ⌘C。
    ///
    /// 判定放在 `mouseUp` 而不是 `selectionChanged`：拖选过程中每一格都会触发一次变化，
    /// 只有松手那一下才是「选定了」。双击选词、三击选行也都会走到这里。
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        copySelectionIfAny()
    }

    private func copySelectionIfAny() {
        guard let selection, selection.active else { return }
        let text = selection.getSelectedText()
        guard !text.isEmpty else { return }

        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        clipboard.setString(text, forType: .string)
    }

    // MARK: - 右键即粘贴

    /// 右键直接粘贴。SwiftTerm 本来完全不处理右键（连鼠标上报也不转发右键），
    /// 所以这里不用担心抢掉别的行为。粘贴走 SwiftTerm 自己的 `paste(_:)`，
    /// 括号粘贴模式（bracketed paste）等细节由它负责。
    override func rightMouseDown(with event: NSEvent) {
        paste(self)
    }
}
