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
    ///
    /// 次数**每两下归零**（1、2、1、2…），不像 AppKit 那样一路涨到 3、4、5 ——
    /// 连着点五下应该是「开两个」，不是「开四个」。
    func onLeftClick(perform action: @escaping (Int, NSEvent.ModifierFlags) -> Void) -> some View {
        overlay(ClickCatcher(onLeftClick: action, onMiddleClick: nil))
    }

    /// 左键点击 **+ 拖动**。
    ///
    /// 拖动必须和点击走同一条通道：mouseDown 一旦被这层 NSView 接下，后续的 mouseDragged
    /// 就只发给它，底下 SwiftUI 的 `DragGesture` 再也收不到 —— 所以拖拽也得从这儿报出来。
    ///
    /// 位置是**本视图的局部坐标**（左上原点，和 SwiftUI 一致）。调用方知道自己在全局的哪儿，
    /// 加一下就得到全局坐标；这层自己没法知道 SwiftUI 的坐标空间在哪。
    /// `clickOnRelease` 把点击推迟到松手，并且**拖过就不算点击** ——
    /// 给「点一下会改变布局」的行用（比如折叠分组）：按下就折叠的话，一开拖列表先跳一下。
    func onLeftMouse(
        click: @escaping (Int, NSEvent.ModifierFlags) -> Void,
        drag: @escaping (LeftDragPhase) -> Void,
        clickOnRelease: Bool = false
    ) -> some View {
        overlay(
            ClickCatcher(
                onLeftClick: click,
                onMiddleClick: nil,
                onLeftDrag: drag,
                clicksOnRelease: clickOnRelease
            )
        )
    }
}

/// 左键拖动的阶段。`ended` 只在真的拖起来（超过起手阈值）之后才发。
enum LeftDragPhase {
    case changed(CGPoint)
    case ended
}

/// 盖在目标视图上的一层「只接指定按键」的 NSView。
///
/// 关键在 `hitTest`：只有自己管的那些事件才返回自己，别的一律返回 nil 穿透下去 ——
/// 否则下面 SwiftUI 视图的悬停、右键菜单、拖拽全被这层吃掉。
private struct ClickCatcher: NSViewRepresentable {

    let onLeftClick: ((Int, NSEvent.ModifierFlags) -> Void)?
    let onMiddleClick: (() -> Void)?
    var onLeftDrag: ((LeftDragPhase) -> Void)?
    var clicksOnRelease = false

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
        view.onLeftDrag = onLeftDrag
        view.clicksOnRelease = clicksOnRelease
    }

    final class CatcherView: NSView {

        var onLeftClick: ((Int, NSEvent.ModifierFlags) -> Void)?
        var onMiddleClick: (() -> Void)?
        var onLeftDrag: ((LeftDragPhase) -> Void)?
        var clicksOnRelease = false

        /// 中键按下与松开都落在自己身上才算一次点击（和按钮的语义一致）。
        private var isMiddlePressed = false
        /// 左键按下的位置（局部坐标），用来判断有没有超过起手阈值。
        private var leftDownLocation: CGPoint?
        private var isDragging = false
        /// `clicksOnRelease` 时留到松手再用的那次按下。
        private var pendingClick: (count: Int, modifiers: NSEvent.ModifierFlags)?
        /// 已经结算掉的连击次数。见 `cycledClickCount(of:)`。
        private var settledClicks = 0

        /// 局部坐标跟 SwiftUI 对齐：左上原点、y 向下。
        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
                return onLeftClick == nil && onLeftDrag == nil ? nil : super.hitTest(point)
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
            guard onLeftClick != nil || onLeftDrag != nil else {
                super.mouseDown(with: event)
                return
            }
            leftDownLocation = convert(event.locationInWindow, from: nil)
            isDragging = false
            let click = (
                cycledClickCount(of: event),
                event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            )
            if clicksOnRelease {
                pendingClick = click
            } else {
                onLeftClick?(click.0, click.1)
            }
        }

        /// 把 AppKit 的连击次数折成 1、2、1、2…
        ///
        /// AppKit 在双击间隔内一路往上加（1、2、3、4…）。照它报的话，第三下、第四下都是
        /// 「> 1」，连着点五下会开四个 tab；实际想要的是**每两下算一次双击**：
        /// 报出 2 之后就把它当结算点，下一下重新从 1 起算。
        /// 新的一串连击（`clickCount == 1`）自然把结算点清零。
        private func cycledClickCount(of event: NSEvent) -> Int {
            if event.clickCount == 1 {
                settledClicks = 0
            }
            let count = max(event.clickCount - settledClicks, 1)
            guard count >= 2 else { return count }
            settledClicks = event.clickCount
            return 2
        }

        /// 拖动：动过 `dragThreshold` 之后才算拖，免得手抖一下就把顺序改了。
        override func mouseDragged(with event: NSEvent) {
            guard let onLeftDrag, let start = leftDownLocation else {
                super.mouseDragged(with: event)
                return
            }
            let point = convert(event.locationInWindow, from: nil)
            if !isDragging {
                guard hypot(point.x - start.x, point.y - start.y) > Self.dragThreshold else { return }
                isDragging = true
            }
            onLeftDrag(.changed(point))
        }

        override func mouseUp(with event: NSEvent) {
            let click = pendingClick
            defer {
                leftDownLocation = nil
                isDragging = false
                pendingClick = nil
            }
            guard isDragging, let onLeftDrag else {
                // 没拖起来：这才算一次点击（`clicksOnRelease`）。
                if let click, bounds.contains(convert(event.locationInWindow, from: nil)) {
                    onLeftClick?(click.count, click.modifiers)
                } else if click == nil {
                    super.mouseUp(with: event)
                }
                return
            }
            // 最后一下移动可能没被 mouseDragged 收到，松手位置再算一遍。
            onLeftDrag(.changed(convert(event.locationInWindow, from: nil)))
            onLeftDrag(.ended)
        }

        private static let dragThreshold: CGFloat = 4

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
