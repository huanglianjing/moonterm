import AppKit
import Combine
import MoontermCore

/// 分隔线接点的共享高亮状态。单独观察，避免悬停时让 `AppState` 和整棵终端树一起刷新。
final class PaneDividerHighlightController: ObservableObject {

    struct Identity: Hashable {
        let splitID: UUID
        let dividerIndex: Int

        init(splitID: UUID, dividerIndex: Int) {
            self.splitID = splitID
            self.dividerIndex = dividerIndex
        }

        init(_ geometry: PaneDividerGeometry) {
            self.init(splitID: geometry.splitID, dividerIndex: geometry.dividerIndex)
        }
    }

    @Published private(set) var emphasized: Set<Identity> = []
    /// 接点处可能有多个扩展热区重叠；只允许最后收到 active 的那条线清除这一组。
    private var owner: Identity?

    func update(owner: Identity, emphasized next: Set<Identity>) {
        self.owner = owner
        if emphasized != next { emphasized = next }
    }

    func clear(owner: Identity) {
        guard self.owner == owner else { return }
        self.owner = nil
        if !emphasized.isEmpty { emphasized = [] }
    }
}

/// 悬停或拖动分隔线期间把鼠标图标占住，别让别人半路改掉。
///
/// 鼠标图标是 AppKit 的全局状态，`NSCursor.set()` 只活到下一次 cursor rect 生效为止，
/// 而 cursor rect 是**跨过区域边界**时才补一次 cursorUpdate 的 —— 所以症状是「挪到某个位置就变了」。
/// 分隔线的热区要向两侧分栏各伸出 6 点，分栏边界正好横在热区中间：终端视图（SwiftTerm）
/// 给自己整块 bounds 装了 I 形 rect，SwiftUI 给普通区域装的是箭头 rect，跨过去就把我们
/// 刚设好的调整图标顶掉（实测：热区里只有没跨过任何边界的那几下能留住正确图标）。
///
/// 所以进入热区就整窗关掉 cursor rect（`disableCursorRects` 本来就是给「我先占着」这种场景
/// 准备的），离开时再开回去并重建，让 AppKit 自己按当前位置把图标补对 ——
/// 比我们猜鼠标下面是终端还是标题栏可靠。
enum PaneDividerCursorGuard {

    /// 当前占着图标的那条线。接点处多条线的热区互相重叠，只有占有者能交还。
    private static var owner: PaneDividerHighlightController.Identity?
    /// 被我们关掉 cursor rect 的窗口，恢复时按原样开回去。
    private static var suspended: [NSWindow] = []
    /// 当前该显示的图标。关掉 cursor rect 之后要靠它补设一次。
    private static var held: NSCursor?

    /// 接管鼠标图标。同一条线反复调用只重设图标，不再动窗口的 cursor rect。
    static func take(_ cursor: NSCursor, owner: PaneDividerHighlightController.Identity) {
        held = cursor
        if self.owner != owner {
            self.owner = owner
            suspend()
        }
        cursor.set()
    }

    /// 交还鼠标图标；不是当前占有者时什么都不做。
    static func release(owner: PaneDividerHighlightController.Identity) {
        guard self.owner == owner else { return }
        self.owner = nil
        held = nil
        NSCursor.arrow.set()
        restore()
    }

    /// 每次换占有者都重扫一遍窗口：万一上一轮的窗口没等到 hover 结束就关掉了，
    /// 只靠「已经关过就不再关」会让新窗口一直漏在外面。
    private static func suspend() {
        for window in NSApp.windows where window.isVisible && window.areCursorRectsEnabled {
            window.disableCursorRects()
            suspended.append(window)
        }
        // 关掉那一下 AppKit 还会补一次「回到默认图标」，而且是延后一拍发出的（之后再动鼠标就不会了），
        // 所以这一拍之后再把图标按回来 —— 否则刚从终端移进热区的第一下会闪成箭头。
        DispatchQueue.main.async {
            guard let held else { return }
            held.set()
        }
    }

    private static func restore() {
        let windows = suspended
        suspended = []
        for window in windows where window.isVisible {
            window.enableCursorRects()
            // 重建之后 AppKit 会按鼠标当前位置重新发 cursorUpdate：回到终端上就自己变回 I 形。
            window.resetCursorRects()
        }
    }
}

/// 给分隔线接点提供方向明确的鼠标图标。
///
/// AppKit 只有单轴调整图标，T 形与十字必须自己画；白色外描边让它在深浅终端背景上都看得清。
enum PaneDividerCursor {

    private struct Arms: OptionSet {
        let rawValue: Int

        static let left = Arms(rawValue: 1 << 0)
        static let right = Arms(rawValue: 1 << 1)
        static let top = Arms(rawValue: 1 << 2)
        static let bottom = Arms(rawValue: 1 << 3)
    }

    private static let teeTop = makeCursor(arms: [.left, .right, .bottom])
    private static let teeBottom = makeCursor(arms: [.left, .right, .top])
    private static let teeLeft = makeCursor(arms: [.right, .top, .bottom])
    private static let teeRight = makeCursor(arms: [.left, .top, .bottom])
    private static let cross = makeCursor(arms: [.left, .right, .top, .bottom])

    static func cursor(for shape: PaneDividerDragShape) -> NSCursor {
        switch shape {
        case .leftRight: return .resizeLeftRight
        case .upDown: return .resizeUpDown
        case .teeTop: return teeTop
        case .teeBottom: return teeBottom
        case .teeLeft: return teeLeft
        case .teeRight: return teeRight
        case .cross: return cross
        }
    }

    /// 箭头尖端朝可移动方向；热点固定在交点正中。
    private static func makeCursor(arms: Arms) -> NSCursor {
        let center = NSPoint(x: 12, y: 12)
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        if arms.contains(.left) {
            appendArrow(
                to: path,
                from: center,
                tip: NSPoint(x: 2.5, y: 12),
                wings: (NSPoint(x: 6.5, y: 15.5), NSPoint(x: 6.5, y: 8.5))
            )
        }
        if arms.contains(.right) {
            appendArrow(
                to: path,
                from: center,
                tip: NSPoint(x: 21.5, y: 12),
                wings: (NSPoint(x: 17.5, y: 15.5), NSPoint(x: 17.5, y: 8.5))
            )
        }
        if arms.contains(.top) {
            appendArrow(
                to: path,
                from: center,
                tip: NSPoint(x: 12, y: 21.5),
                wings: (NSPoint(x: 8.5, y: 17.5), NSPoint(x: 15.5, y: 17.5))
            )
        }
        if arms.contains(.bottom) {
            appendArrow(
                to: path,
                from: center,
                tip: NSPoint(x: 12, y: 2.5),
                wings: (NSPoint(x: 8.5, y: 6.5), NSPoint(x: 15.5, y: 6.5))
            )
        }

        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            NSColor.white.withAlphaComponent(0.95).setStroke()
            path.lineWidth = 4
            path.stroke()

            NSColor.black.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 2
            path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: center)
    }

    private static func appendArrow(
        to path: NSBezierPath,
        from center: NSPoint,
        tip: NSPoint,
        wings: (NSPoint, NSPoint)
    ) {
        path.move(to: center)
        path.line(to: tip)
        path.move(to: wings.0)
        path.line(to: tip)
        path.line(to: wings.1)
    }
}
