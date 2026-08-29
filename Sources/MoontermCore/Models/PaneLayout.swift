import CoreGraphics
import Foundation

// MARK: - 方向

/// 分栏方向。`horizontal` 表示子分栏左右排列，`vertical` 表示上下排列。
public enum PaneAxis: String, Equatable, Codable, Sendable {
    case horizontal
    case vertical
}

/// 一条分隔线在窗口全局坐标里的几何信息。
///
/// `splitAxis` 是子分栏的排列方向，因此 `.horizontal` 对应画面中的竖线，
/// `.vertical` 对应画面中的横线。
public struct PaneDividerGeometry: Equatable {
    public let splitID: UUID
    public let dividerIndex: Int
    public let splitAxis: PaneAxis
    public let frame: CGRect

    public init(splitID: UUID, dividerIndex: Int, splitAxis: PaneAxis, frame: CGRect) {
        self.splitID = splitID
        self.dividerIndex = dividerIndex
        self.splitAxis = splitAxis
        self.frame = frame
    }
}

/// 鼠标所在位置允许怎样调整分栏；T 形名称对应它在画面中的字形。
public enum PaneDividerDragShape: Equatable, Sendable {
    /// 普通竖分隔线，只能左右调整。
    case leftRight
    /// 普通横分隔线，只能上下调整。
    case upDown
    /// `┬`：左右加向下三个方向。
    case teeTop
    /// `┴`：左右加向上三个方向。
    case teeBottom
    /// `├`：上下加向右三个方向。
    case teeLeft
    /// `┤`：上下加向左三个方向。
    case teeRight
    /// `┼`：四个方向。
    case cross
}

/// 判定一次分隔线拖动是否从十字或 T 形接点起手。
public enum PaneDividerJunction {

    /// 接点允许的最大视觉间隔。SwiftUI 的布局坐标以点计，这里按界面里的 5 像素语义处理。
    public static let tolerance: CGFloat = 5

    /// 一个接点：交点坐标，加上要一起移动的整组分隔线（含主动线）。
    struct Junction {
        let point: CGPoint
        let dividers: [PaneDividerGeometry]
    }

    /// 返回接点附近需要一起移动的整组分隔线；只有横、竖两个方向都出现时才算有效接点。
    ///
    /// 返回整组而不只是最近的一条：树形布局中的十字通常由一条竖线和左右两条横线组成，
    /// 三条都锁住才能让十字在拖动后仍然对齐。空数组表示本次仍按普通单线拖动处理。
    /// `sourceHitOutset` 只控制鼠标离主动线多远仍算命中，不改变两条线之间的 `tolerance`。
    public static func linkedDividers(
        dragging splitID: UUID,
        dividerIndex: Int,
        at point: CGPoint,
        among dividers: [PaneDividerGeometry],
        tolerance: CGFloat = PaneDividerJunction.tolerance,
        sourceHitOutset: CGFloat = PaneDividerJunction.tolerance
    ) -> [PaneDividerGeometry] {
        junction(
            dragging: splitID,
            dividerIndex: dividerIndex,
            at: point,
            among: dividers,
            tolerance: tolerance,
            sourceHitOutset: sourceHitOutset
        )?.dividers ?? []
    }

    /// 判定鼠标是不是停在一个接点上，并把整组线圈出来。
    ///
    /// 鼠标只负责回答「在不在接点上」（同时落在相交两条线各自的热区里），
    /// **组员一律以交点为原点判定，不看鼠标**。反过来按鼠标到各条线的距离收组的话，
    /// 热区有十几点宽，鼠标在里面挪两三点就能让十字对面那条线掉出组 ——
    /// 高亮会只剩一条、图标也在单轴 / T / 十字之间来回跳，就是这么来的。
    static func junction(
        dragging splitID: UUID,
        dividerIndex: Int,
        at point: CGPoint,
        among dividers: [PaneDividerGeometry],
        tolerance: CGFloat = PaneDividerJunction.tolerance,
        sourceHitOutset: CGFloat = PaneDividerJunction.tolerance
    ) -> Junction? {
        guard tolerance >= 0, sourceHitOutset >= 0,
              let source = dividers.first(where: {
                  $0.splitID == splitID && $0.dividerIndex == dividerIndex
              }),
              distance(from: point, to: source.frame) <= sourceHitOutset
        else { return nil }

        // 鼠标可能停在 2 点宽主动线的另一侧：两条线本身相隔 5 点时，鼠标到另一条线
        // 最远会是 7 点。把主动线的短边算进去，判定的才是「线与线间隔」而不是鼠标到线的距离。
        let sourceThickness = min(source.frame.width, source.frame.height)
        let reach = sourceHitOutset + sourceThickness

        // 交点位置由两条线自己给：竖线定 x，横线定 y。
        guard let partner = dividers
            .filter({
                $0.splitAxis != source.splitAxis
                    && distance(between: source.frame, and: $0.frame) <= tolerance
                    && distance(from: point, to: $0.frame) <= reach
            })
            .min(by: { distance(from: point, to: $0.frame) < distance(from: point, to: $1.frame) })
        else { return nil }

        let vertical = source.splitAxis == .horizontal ? source : partner
        let horizontal = source.splitAxis == .horizontal ? partner : source
        let crossing = CGPoint(x: vertical.frame.midX, y: horizontal.frame.midY)

        let group = dividers.filter {
            distance(between: source.frame, and: $0.frame) <= tolerance
                && distance(from: crossing, to: $0.frame) <= reach
        }
        return Junction(point: crossing, dividers: group)
    }

    /// 返回鼠标当前位置应显示的调整光标形状；找不到主动线时返回 nil。
    /// `sourceHitOutset` 与界面的透明拖动热区一致，和接点容差分别计算。
    public static func dragShape(
        dragging splitID: UUID,
        dividerIndex: Int,
        at point: CGPoint,
        among dividers: [PaneDividerGeometry],
        tolerance: CGFloat = PaneDividerJunction.tolerance,
        sourceHitOutset: CGFloat = PaneDividerJunction.tolerance
    ) -> PaneDividerDragShape? {
        guard tolerance >= 0, sourceHitOutset >= 0,
              let source = dividers.first(where: {
                  $0.splitID == splitID && $0.dividerIndex == dividerIndex
              }),
              distance(from: point, to: source.frame) <= sourceHitOutset
        else { return nil }

        guard let junction = junction(
            dragging: splitID,
            dividerIndex: dividerIndex,
            at: point,
            among: dividers,
            tolerance: tolerance,
            sourceHitOutset: sourceHitOutset
        ) else {
            return source.splitAxis == .horizontal ? .leftRight : .upDown
        }

        // 腿也要从**交点**量，不能拿鼠标当原点：热区向两侧各伸出好几点，鼠标压在偏外侧
        // 那一两点上时，交点对面的那条线会被算成一条腿，T 形就在那儿误报成十字。
        // 分栏最短边远大于容差；超过交点 5 点仍有线段，就代表那个方向确实有一条“腿”。
        var hasLeft = false
        var hasRight = false
        var hasTop = false
        var hasBottom = false
        for divider in junction.dividers {
            switch divider.splitAxis {
            case .horizontal:
                hasTop = hasTop || divider.frame.minY < junction.point.y - tolerance
                hasBottom = hasBottom || divider.frame.maxY > junction.point.y + tolerance
            case .vertical:
                hasLeft = hasLeft || divider.frame.minX < junction.point.x - tolerance
                hasRight = hasRight || divider.frame.maxX > junction.point.x + tolerance
            }
        }

        switch (hasLeft, hasRight, hasTop, hasBottom) {
        case (true, true, true, true): return .cross
        case (true, true, false, true): return .teeTop
        case (true, true, true, false): return .teeBottom
        case (false, true, true, true): return .teeLeft
        case (true, false, true, true): return .teeRight
        default:
            // 极小布局或多条线恰好挤在一起时也允许双轴拖动；四向图标比误报成单轴更准确。
            return .cross
        }
    }

    /// 点在矩形内时距离为 0；在外面时取到最近边或角的欧氏距离。
    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, point.x - rect.maxX, 0)
        let dy = max(rect.minY - point.y, point.y - rect.maxY, 0)
        return hypot(dx, dy)
    }

    /// 两个矩形相交或接触时距离为 0。
    private static func distance(between lhs: CGRect, and rhs: CGRect) -> CGFloat {
        let dx = max(lhs.minX - rhs.maxX, rhs.minX - lhs.maxX, 0)
        let dy = max(lhs.minY - rhs.maxY, rhs.minY - lhs.maxY, 0)
        return hypot(dx, dy)
    }
}

/// 平行分隔线的磁吸对齐。竖线比较全局 x 中心，横线比较全局 y 中心。
public enum PaneDividerMagnet {

    /// 鼠标目标进入这个距离后吸附；超过后立即恢复自由拖动。
    ///
    /// 取 12 点：比分隔线的拖动热区（半边 6 点）宽一倍，手推过去时能明显感到被拉住；
    /// 相对分栏最短边 120 点又只占十分之一，不至于粘手。要再灵敏就只改这一个数。
    public static let tolerance: CGFloat = 18

    /// 返回吸附后的起手位移。没有同向候选或尚未进入阈值时原样返回 `translation`。
    public static func snappedTranslation(
        dragging source: PaneDividerGeometry,
        translation: CGFloat,
        among dividers: [PaneDividerGeometry],
        tolerance: CGFloat = PaneDividerMagnet.tolerance
    ) -> CGFloat {
        guard tolerance >= 0 else { return translation }

        let sourcePosition = position(of: source)
        let proposedPosition = sourcePosition + translation
        let candidate = dividers
            .filter {
                $0.splitAxis == source.splitAxis
                    && !($0.splitID == source.splitID && $0.dividerIndex == source.dividerIndex)
            }
            .map { (position: position(of: $0), distance: abs(position(of: $0) - proposedPosition)) }
            .min { $0.distance < $1.distance }

        guard let candidate, candidate.distance <= tolerance else { return translation }
        return candidate.position - sourcePosition
    }

    private static func position(of divider: PaneDividerGeometry) -> CGFloat {
        divider.splitAxis == .horizontal ? divider.frame.midX : divider.frame.midY
    }
}

/// 相对某个分栏的落点方位。
public enum PaneEdge: String, Equatable, Codable, Sendable, CaseIterable {
    case leading
    case trailing
    case top
    case bottom

    public var axis: PaneAxis {
        switch self {
        case .leading, .trailing: return .horizontal
        case .top, .bottom: return .vertical
        }
    }

    /// 新分栏是否排在目标分栏之前。
    public var insertsBefore: Bool {
        switch self {
        case .leading, .top: return true
        case .trailing, .bottom: return false
        }
    }
}

/// 标题栏菜单提供的整组分栏方式。
///
/// 当前分栏会保留原来的窗口组；其余位置各放一个新会话。
public enum PaneSplitPreset: Equatable, Sendable {
    case sideBySide
    case stacked
    case grid

    /// 应为这个布局新建的会话数。
    public var newSessionCount: Int {
        switch self {
        case .sideBySide, .stacked: return 1
        case .grid: return 3
        }
    }
}

// MARK: - 落点判定

/// 指针落在某个分栏矩形内时代表的意图。
public enum PaneDropZone: Equatable, Sendable {
    /// 贴着某条边：在那一侧开出新分栏。
    case edge(PaneEdge)
    /// 落在正中：并入这个分栏的会话组（多一个小标签）。
    case center

    /// 中心区域占分栏长宽的比例。
    public static let centerRatio: CGFloat = 0.4

    /// 把「指针位置 + 分栏矩形」翻译成意图。
    ///
    /// 坐标系按 SwiftUI 的约定：y 向下增长，所以 y 小的一侧是 `.top`。
    public static func resolve(
        point: CGPoint,
        in rect: CGRect,
        centerRatio: CGFloat = PaneDropZone.centerRatio
    ) -> PaneDropZone {
        guard rect.width > 0, rect.height > 0 else { return .center }
        let x = (point.x - rect.minX) / rect.width
        let y = (point.y - rect.minY) / rect.height
        let low = (1 - centerRatio) / 2
        let high = 1 - low
        if x > low, x < high, y > low, y < high { return .center }
        return .edge(nearestEdge(point: point, in: rect))
    }

    /// 忽略中心区，只取最近的一条边。
    public static func nearestEdge(point: CGPoint, in rect: CGRect) -> PaneEdge {
        guard rect.width > 0, rect.height > 0 else { return .trailing }
        let x = (point.x - rect.minX) / rect.width
        let y = (point.y - rect.minY) / rect.height
        // 归一化距离，谁小就贴谁。
        let candidates: [(PaneEdge, CGFloat)] = [
            (.leading, x), (.trailing, 1 - x), (.top, y), (.bottom, 1 - y)
        ]
        return candidates.min { $0.1 < $1.1 }?.0 ?? .trailing
    }

    /// 根据实际可执行的窗口移动修正预览。拖动目标分栏里唯一的窗口到自身边缘时，没有另一个
    /// 窗口可作为拆分锚点，松手后布局不会变化；此时用中心全框表达「仍留在原分栏」。
    public func previewingMove(
        movingSessionID: UUID,
        targetSessionID: UUID,
        targetPaneSessionCount: Int
    ) -> PaneDropZone {
        guard case .edge = self,
              movingSessionID == targetSessionID,
              targetPaneSessionCount == 1
        else { return self }
        return .center
    }
}

// MARK: - 会话组

/// 一个分栏里的会话组。
///
/// 一个分栏可以装多个会话，用分栏顶部的小标签条切换；`activeID` 是当前显示的那个。
/// 不变式：`sessionIDs` 非空，且 `activeID` 一定在里面。
public struct PaneGroup: Equatable {

    public private(set) var sessionIDs: [UUID]
    public private(set) var activeID: UUID

    public init(_ sessionID: UUID) {
        self.sessionIDs = [sessionID]
        self.activeID = sessionID
    }

    /// `sessionIDs` 为空或 `activeID` 不在其中时返回 nil。
    public init?(sessionIDs: [UUID], activeID: UUID) {
        guard !sessionIDs.isEmpty, sessionIDs.contains(activeID) else { return nil }
        self.sessionIDs = sessionIDs
        self.activeID = activeID
    }

    public var count: Int { sessionIDs.count }

    public func contains(_ sessionID: UUID) -> Bool { sessionIDs.contains(sessionID) }

    public mutating func activate(_ sessionID: UUID) {
        guard sessionIDs.contains(sessionID) else { return }
        activeID = sessionID
    }

    /// 插到第 `index` 位（nil 表示末尾），并设为当前显示。
    public mutating func insert(_ sessionID: UUID, at index: Int?) {
        guard !sessionIDs.contains(sessionID) else { return }
        let position = min(max(index ?? sessionIDs.count, 0), sessionIDs.count)
        sessionIDs.insert(sessionID, at: position)
        activeID = sessionID
    }

    /// 组内挪位置。`index` 是「插到原数组第几项之前」。
    public mutating func move(_ sessionID: UUID, to index: Int?) {
        guard let from = sessionIDs.firstIndex(of: sessionID) else { return }
        let destination = min(max(index ?? sessionIDs.count, 0), sessionIDs.count)
        guard destination != from, destination != from + 1 else { return }
        sessionIDs.remove(at: from)
        sessionIDs.insert(sessionID, at: destination > from ? destination - 1 : destination)
    }

    /// 移除一个会话。移除的是当前显示的那个时，焦点顺移到它右边（没有就左边）。
    /// 组里只剩一个时不动 —— 空组没有意义，由调用方连整个分栏一起删。
    public mutating func remove(_ sessionID: UUID) {
        guard sessionIDs.count > 1, let index = sessionIDs.firstIndex(of: sessionID) else { return }
        sessionIDs.remove(at: index)
        if activeID == sessionID {
            activeID = sessionIDs[min(index, sessionIDs.count - 1)]
        }
    }
}

// MARK: - 分栏树

/// 一个 tab 的分栏布局：叶子是一组会话（`PaneGroup`），`split` 是同方向的若干子分栏 + 各自占比。
///
/// 全部操作只认 `UUID`，不碰任何视图对象，所以可以直接单测。
/// 不变式：
/// - 同一个 `split` 的 `children.count >= 2`，`fraction` 之和为 1；
/// - 相邻两层 `split` 的轴向必然不同（同轴会被拍平，见 `normalize()`）；
/// - 每个叶子的会话组非空。
public struct PaneNode: Identifiable, Equatable {

    public struct Child: Equatable {
        public var node: PaneNode
        public var fraction: CGFloat

        public init(node: PaneNode, fraction: CGFloat) {
            self.node = node
            self.fraction = fraction
        }
    }

    public enum Content: Equatable {
        case group(PaneGroup)
        case split(axis: PaneAxis, children: [Child])
    }

    public let id: UUID
    public var content: Content

    public init(id: UUID = UUID(), content: Content) {
        self.id = id
        self.content = content
    }

    /// 只装一个会话的分栏。
    public static func terminal(_ sessionID: UUID, id: UUID = UUID()) -> PaneNode {
        PaneNode(id: id, content: .group(PaneGroup(sessionID)))
    }

    // MARK: - 查询

    public var group: PaneGroup? {
        if case .group(let group) = content { return group }
        return nil
    }

    public var isLeaf: Bool { group != nil }

    /// 叶子当前显示的会话。
    public var activeSessionID: UUID? { group?.activeID }

    /// 树里所有会话，按视觉顺序（左→右、上→下；同一分栏内按小标签顺序）。
    public var sessionIDs: [UUID] {
        switch content {
        case .group(let group):
            return group.sessionIDs
        case .split(_, let children):
            return children.flatMap { $0.node.sessionIDs }
        }
    }

    /// 各分栏当前显示的会话 —— 也就是真正占着屏幕的那些终端。
    public var activeSessionIDs: [UUID] {
        switch content {
        case .group(let group):
            return [group.activeID]
        case .split(_, let children):
            return children.flatMap { $0.node.activeSessionIDs }
        }
    }

    /// 分栏（叶子）个数。
    public var paneCount: Int {
        switch content {
        case .group:
            return 1
        case .split(_, let children):
            return children.reduce(0) { $0 + $1.node.paneCount }
        }
    }

    /// 会话总数（一个分栏里可能有好几个）。
    public var sessionCount: Int { sessionIDs.count }

    public func contains(sessionID target: UUID) -> Bool {
        sessionIDs.contains(target)
    }

    /// 找到包含某个会话的那个分栏的会话组。
    public func group(containing sessionID: UUID) -> PaneGroup? {
        switch content {
        case .group(let group):
            return group.contains(sessionID) ? group : nil
        case .split(_, let children):
            for child in children {
                if let found = child.node.group(containing: sessionID) { return found }
            }
            return nil
        }
    }

    // MARK: - 分栏：插入

    /// 在包含 `target` 的那个分栏的 `edge` 一侧开一个新分栏。
    ///
    /// 目标分栏所在 split 的轴向与 `edge` 一致时插到**同级**（三栏保持扁平），
    /// 新分栏取目标分栏占比的一半，其他分栏占比不受影响。
    @discardableResult
    public mutating func insert(sessionID newID: UUID, relativeTo target: UUID, edge: PaneEdge) -> Bool {
        switch content {
        case .group(let group):
            guard group.contains(target) else { return false }
            // 叶子自己就是目标：原地长出一个 split，原来那组会话整体下沉一层。
            let kept = PaneNode(content: .group(group))
            let added = PaneNode.terminal(newID)
            let children = edge.insertsBefore
                ? [Child(node: added, fraction: 0.5), Child(node: kept, fraction: 0.5)]
                : [Child(node: kept, fraction: 0.5), Child(node: added, fraction: 0.5)]
            content = .split(axis: edge.axis, children: children)
            return true

        case .split(let axis, var children):
            if axis == edge.axis,
               let index = children.firstIndex(where: { $0.node.isLeaf && $0.node.contains(sessionID: target) }) {
                let half = children[index].fraction / 2
                children[index].fraction = half
                children.insert(
                    Child(node: .terminal(newID), fraction: half),
                    at: edge.insertsBefore ? index : index + 1
                )
                content = .split(axis: axis, children: children)
                return true
            }
            for index in children.indices {
                if children[index].node.insert(sessionID: newID, relativeTo: target, edge: edge) {
                    content = .split(axis: axis, children: children)
                    return true
                }
            }
            return false
        }
    }

    /// 把包含 `target` 的分栏一次变成标题栏菜单指定的布局。
    ///
    /// 操作先在副本上完成，任何一步失败都不改原树。四宫格先左右分栏，再分别上下分栏，
    /// 并按「左上保留当前分栏，右上、左下、右下依次放入三个新会话」排列；用逐边插入
    /// 构造，才能在目标外面已经有同轴 split 时仍只平分目标原本占据的范围。
    @discardableResult
    public mutating func split(
        relativeTo target: UUID,
        preset: PaneSplitPreset,
        newSessionIDs: [UUID]
    ) -> Bool {
        guard contains(sessionID: target),
              newSessionIDs.count == preset.newSessionCount,
              Set(newSessionIDs).count == newSessionIDs.count,
              newSessionIDs.allSatisfy({ !contains(sessionID: $0) })
        else { return false }

        var updated = self
        switch preset {
        case .sideBySide:
            guard updated.insert(sessionID: newSessionIDs[0], relativeTo: target, edge: .trailing) else {
                return false
            }

        case .stacked:
            guard updated.insert(sessionID: newSessionIDs[0], relativeTo: target, edge: .bottom) else {
                return false
            }

        case .grid:
            let topRight = newSessionIDs[0]
            let bottomLeft = newSessionIDs[1]
            guard updated.insert(sessionID: topRight, relativeTo: target, edge: .trailing),
                  updated.insert(sessionID: bottomLeft, relativeTo: target, edge: .bottom),
                  updated.insert(sessionID: newSessionIDs[2], relativeTo: topRight, edge: .bottom)
            else { return false }
        }

        self = updated
        return true
    }

    /// 把包含 `target` 的分栏里叠放的窗口全部展开，按 `axis` 等分排列。
    ///
    /// 只有一个窗口时没有可排列的内容，返回 `false`。如果目标外层已经是同方向的 split，
    /// 新窗口直接插到那一层，并且只平分目标原本的占比，避免产生同轴嵌套。
    @discardableResult
    public mutating func arrangeGroup(containing target: UUID, axis: PaneAxis) -> Bool {
        switch content {
        case .group(let group):
            guard group.contains(target), group.count > 1 else { return false }
            let fraction = 1 / CGFloat(group.count)
            content = .split(
                axis: axis,
                children: group.sessionIDs.map {
                    Child(node: .terminal($0), fraction: fraction)
                }
            )
            return true

        case .split(let currentAxis, var children):
            guard let index = children.firstIndex(where: { $0.node.contains(sessionID: target) }) else {
                return false
            }

            if currentAxis == axis,
               let group = children[index].node.group,
               group.count > 1 {
                let fraction = children[index].fraction / CGFloat(group.count)
                let arranged = group.sessionIDs.map {
                    Child(node: .terminal($0), fraction: fraction)
                }
                children.replaceSubrange(index...index, with: arranged)
                content = .split(axis: currentAxis, children: children)
                return true
            }

            guard children[index].node.arrangeGroup(containing: target, axis: axis) else { return false }
            content = .split(axis: currentAxis, children: children)
            return true
        }
    }

    // MARK: - 会话组：并入 / 切换

    /// 把一个会话放进「包含 `target` 的那个分栏」的会话组里，落在小标签条的第 `index` 位。
    ///
    /// - 它本来就在这个组里 → 组内挪位置；
    /// - 它在同一棵树的别处 → 先从原分栏摘掉（原分栏空了就收起）再并入；
    /// - 它不在这棵树里 → 直接并入（跨 tab 的情形，调用方负责先从原树摘掉）。
    @discardableResult
    public mutating func join(sessionID moving: UUID, into target: UUID, at index: Int?) -> Bool {
        guard let targetGroup = group(containing: target) else { return false }

        if targetGroup.contains(moving) {
            return mutateGroup(containing: target) { $0.move(moving, to: index) }
        }

        if contains(sessionID: moving) {
            guard remove(sessionID: moving) else { return false }
            guard group(containing: target) != nil else { return false }
        }
        return mutateGroup(containing: target) { $0.insert(moving, at: index) }
    }

    /// 切换某个分栏当前显示的会话。
    @discardableResult
    public mutating func activate(sessionID: UUID) -> Bool {
        mutateGroup(containing: sessionID) { $0.activate(sessionID) }
    }

    @discardableResult
    private mutating func mutateGroup(containing sessionID: UUID, _ body: (inout PaneGroup) -> Void) -> Bool {
        switch content {
        case .group(var group):
            guard group.contains(sessionID) else { return false }
            body(&group)
            content = .group(group)
            return true

        case .split(let axis, var children):
            for index in children.indices {
                if children[index].node.mutateGroup(containing: sessionID, body) {
                    content = .split(axis: axis, children: children)
                    return true
                }
            }
            return false
        }
    }

    // MARK: - 删除

    /// 摘掉一个会话。它所在分栏的组里还有别人时只是少一个小标签；
    /// 是那个分栏的最后一个会话时，整个分栏拿掉，只剩一个子节点的 split 自动收起。
    ///
    /// 根节点就是那个只剩一个会话的分栏时返回 `false`（树不能为空，由调用方连整个 tab 一起删）。
    @discardableResult
    public mutating func remove(sessionID target: UUID) -> Bool {
        switch content {
        case .group(var group):
            guard group.contains(target), group.count > 1 else { return false }
            group.remove(target)
            content = .group(group)
            return true

        case .split(let axis, var children):
            // 子分栏里只剩这一个会话 → 整个分栏拿掉。
            if let index = children.firstIndex(where: {
                $0.node.isLeaf && $0.node.group?.count == 1 && $0.node.contains(sessionID: target)
            }) {
                children.remove(at: index)
                if children.count == 1 {
                    // 收起：本节点直接顶替成唯一子节点的内容（id 不变，上层引用不受影响）。
                    content = children[0].node.content
                } else {
                    content = .split(axis: axis, children: Self.renormalized(children))
                }
                normalize()
                return true
            }

            for index in children.indices {
                if children[index].node.remove(sessionID: target) {
                    content = .split(axis: axis, children: children)
                    normalize()
                    return true
                }
            }
            return false
        }
    }

    // MARK: - 移动

    /// 同一棵树内把一个会话搬到另一个分栏旁边（开出新分栏）。
    @discardableResult
    public mutating func move(sessionID moving: UUID, relativeTo target: UUID, edge: PaneEdge) -> Bool {
        guard moving != target,
              contains(sessionID: moving),
              contains(sessionID: target)
        else { return false }

        // 已经是目标旁边的独立分栏时，视觉结果不会变化。若仍然先删再插，虽然最终树形一样，
        // 叶子节点的 id 却会全部换掉；SwiftUI 会据此拆装长期持有的终端 NSView，留下空的灰色容器。
        guard !isAlreadyPositioned(sessionID: moving, relativeTo: target, edge: edge) else { return false }

        guard remove(sessionID: moving) else { return false }
        return insert(sessionID: moving, relativeTo: target, edge: edge)
    }

    /// `moving` 是否已经作为独立叶子紧挨着目标，且方向与当前 split 一致。
    ///
    /// 移动的是多窗口分栏里的一个会话时不能判成原位：那次拖动的意图正是把它从组里拆成新分栏。
    private func isAlreadyPositioned(sessionID moving: UUID, relativeTo target: UUID, edge: PaneEdge) -> Bool {
        guard group(containing: moving)?.count == 1 else { return false }

        switch content {
        case .group:
            return false

        case .split(let axis, let children):
            if axis == edge.axis,
               let movingIndex = children.firstIndex(where: {
                   $0.node.isLeaf && $0.node.contains(sessionID: moving)
               }),
               let targetIndex = children.firstIndex(where: {
                   $0.node.isLeaf && $0.node.contains(sessionID: target)
               }) {
                return edge.insertsBefore
                    ? movingIndex + 1 == targetIndex
                    : movingIndex == targetIndex + 1
            }

            // 两个会话同在一棵更深的子树里时，原位关系由那一层判断。
            guard let child = children.first(where: {
                $0.node.contains(sessionID: moving) && $0.node.contains(sessionID: target)
            }) else { return false }
            return child.node.isAlreadyPositioned(sessionID: moving, relativeTo: target, edge: edge)
        }
    }

    // MARK: - 占比

    /// 整体替换某个 split 的占比数组（拖分割线用）。传入的数组会被归一化。
    @discardableResult
    public mutating func setFractions(_ fractions: [CGFloat], forSplit splitID: UUID) -> Bool {
        guard case .split(let axis, var children) = content else { return false }

        if id == splitID {
            guard fractions.count == children.count else { return false }
            for index in children.indices {
                children[index].fraction = max(fractions[index], 0)
            }
            content = .split(axis: axis, children: Self.renormalized(children))
            return true
        }

        for index in children.indices {
            if children[index].node.setFractions(fractions, forSplit: splitID) {
                content = .split(axis: axis, children: children)
                return true
            }
        }
        return false
    }

    /// 双击某条分隔线时，把它两侧的相邻分栏恢复为各占这对空间的一半。
    ///
    /// `dividerIndex` 是分隔线左侧（横排）或上侧（竖排）子节点的下标；同一 split 里
    /// 其他子节点的占比保持不变。找不到目标 split 或下标越界时返回 `false`。
    @discardableResult
    public mutating func equalizeAdjacentChildren(atDivider dividerIndex: Int, forSplit splitID: UUID) -> Bool {
        guard case .split(let axis, var children) = content else { return false }

        if id == splitID {
            guard children.indices.contains(dividerIndex),
                  children.indices.contains(dividerIndex + 1)
            else { return false }

            let half = (children[dividerIndex].fraction + children[dividerIndex + 1].fraction) / 2
            children[dividerIndex].fraction = half
            children[dividerIndex + 1].fraction = half
            content = .split(axis: axis, children: children)
            return true
        }

        for index in children.indices {
            if children[index].node.equalizeAdjacentChildren(atDivider: dividerIndex, forSplit: splitID) {
                content = .split(axis: axis, children: children)
                return true
            }
        }
        return false
    }

    // MARK: - 规范化

    /// 把同轴嵌套拍平（占比相乘）。删除分栏时可能产生这种嵌套，视觉上等价但操作起来别扭。
    public mutating func normalize() {
        guard case .split(let axis, var children) = content else { return }

        for index in children.indices {
            children[index].node.normalize()
        }

        var flattened: [Child] = []
        for child in children {
            if case .split(let childAxis, let grandChildren) = child.node.content, childAxis == axis {
                flattened.append(contentsOf: grandChildren.map {
                    Child(node: $0.node, fraction: $0.fraction * child.fraction)
                })
            } else {
                flattened.append(child)
            }
        }

        if flattened.count == 1 {
            content = flattened[0].node.content
        } else {
            content = .split(axis: axis, children: Self.renormalized(flattened))
        }
    }

    /// 占比之和归一。删掉分栏后腾出的空间就是这样按比例分给其余分栏的。
    private static func renormalized(_ children: [Child]) -> [Child] {
        let total = children.reduce(0) { $0 + $1.fraction }
        guard total > 0 else {
            let even = 1 / CGFloat(children.count)
            return children.map { Child(node: $0.node, fraction: even) }
        }
        return children.map { Child(node: $0.node, fraction: $0.fraction / total) }
    }
}
