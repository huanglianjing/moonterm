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
