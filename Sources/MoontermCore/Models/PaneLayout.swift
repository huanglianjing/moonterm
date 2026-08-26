import CoreGraphics
import Foundation

// MARK: - 方向

/// 分栏方向。`horizontal` 表示子分栏左右排列，`vertical` 表示上下排列。
public enum PaneAxis: String, Equatable, Codable, Sendable {
    case horizontal
    case vertical
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
