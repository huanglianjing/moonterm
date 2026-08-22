import AppKit
import SwiftUI

extension View {

    /// 鼠标中键点一下。SwiftUI 的手势只认左键，中键得回 AppKit 接。
    func onMiddleClick(perform action: @escaping () -> Void) -> some View {
        overlay(ClickCatcher(onLeftClick: nil, onMiddleClick: action))
    }

    /// 左键点击，带点击次数与修饰键 —— `onTapGesture` 这两样都给不了
    /// （`NSEvent.modifierFlags` 那种「事后问一下当前按着什么」的读法，在双击超时窗口里已经不准了）。
    ///
    /// 语义按 AppKit 的来：**按下即触发**，第二下的 `clickCount` 是 2。所以双击的过程是
    /// 「先选中，再打开」，和 Finder 一致，也不用为了等双击而把单击延后。
    func onLeftClick(perform action: @escaping (Int, NSEvent.ModifierFlags) -> Void) -> some View {
        overlay(ClickCatcher(onLeftClick: action, onMiddleClick: nil))
    }
}

/// 盖在目标视图上的一层「只接指定按键」的 NSView。
///
/// 关键在 `hitTest`：只有自己管的那些事件才返回自己，别的一律返回 nil 穿透下去 ——
/// 否则下面 SwiftUI 视图的悬停、右键菜单、拖拽全被这层吃掉。
private struct ClickCatcher: NSViewRepresentable {

    let onLeftClick: ((Int, NSEvent.ModifierFlags) -> Void)?
    let onMiddleClick: (() -> Void)?

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: CatcherView) {
        view.onLeftClick = onLeftClick
        view.onMiddleClick = onMiddleClick
    }

    final class CatcherView: NSView {

        var onLeftClick: ((Int, NSEvent.ModifierFlags) -> Void)?
        var onMiddleClick: (() -> Void)?

        /// 中键按下与松开都落在自己身上才算一次点击（和按钮的语义一致）。
        private var isMiddlePressed = false

        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
                return onLeftClick == nil ? nil : super.hitTest(point)
            case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
                return onMiddleClick == nil ? nil : super.hitTest(point)
            default:
                return nil
            }
        }

        /// 窗口没激活时的第一下也算点击，否则得先点一下把窗口叫醒再点一次。
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func mouseDown(with event: NSEvent) {
            guard let onLeftClick else {
                super.mouseDown(with: event)
                return
            }
            onLeftClick(event.clickCount, event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        }

        override func otherMouseDown(with event: NSEvent) {
            // buttonNumber 2 = 中键；侧键（3、4…）不管。
            guard event.buttonNumber == 2 else {
                super.otherMouseDown(with: event)
                return
            }
            isMiddlePressed = true
        }

        override func otherMouseUp(with event: NSEvent) {
            guard isMiddlePressed, event.buttonNumber == 2 else {
                super.otherMouseUp(with: event)
                return
            }
            isMiddlePressed = false
            // 按下后拖到别处再松手不算点击。
            if bounds.contains(convert(event.locationInWindow, from: nil)) {
                onMiddleClick?()
            }
        }
    }
}
