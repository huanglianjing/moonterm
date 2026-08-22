import Foundation

/// 列表的多选状态（主机面板在用）。语义照 Finder / Finder 类列表来：
///
/// - 普通点击：只选这一个，并把它记为锚点
/// - ⌘ 点：单独加减这一个，锚点跟到这儿
/// - ⇧ 点：锚点到它之间整段重选，锚点**不动**（所以可以反复 ⇧ 点着调范围）
///
/// 顺序（哪一项在前）由调用方传进来，本类型不持有列表本身 —— 列表随时会被增删改。
public struct HostSelection: Equatable {

    /// 点击时按着什么。
    public enum Click: Equatable {
        /// 什么都没按。
        case plain
        /// ⌘：加减单个。
        case toggle
        /// ⇧：从锚点扩选。
        case extend
    }

    public private(set) var selected: Set<UUID> = []
    /// ⇧ 扩选的起点：上一次「不带 ⇧ 的那下」点的是谁。
    public private(set) var anchor: UUID?

    public init() {}

    public var count: Int { selected.count }

    public func contains(_ id: UUID) -> Bool {
        selected.contains(id)
    }

    public mutating func click(_ id: UUID, kind: Click, in order: [UUID]) {
        switch kind {
        case .plain:
            selected = [id]
            anchor = id

        case .toggle:
            if selected.contains(id) {
                selected.remove(id)
            } else {
                selected.insert(id)
            }
            anchor = id

        case .extend:
            // 还没有锚点（第一下就按着 ⇧），或锚点已经被删了：退化成普通点击。
            guard let anchor,
                  let from = order.firstIndex(of: anchor),
                  let to = order.firstIndex(of: id)
            else {
                selected = [id]
                self.anchor = id
                return
            }
            let range = from <= to ? from...to : to...from
            selected = Set(order[range])
        }
    }

    /// 右键菜单该作用在谁身上：落在选区里就是整个选区，落在选区外只管这一个（macOS 的老规矩）。
    ///
    /// 返回值按 `order` 排序，不按选中的先后 —— 批量连接时开出来的 tab 顺序才和看到的一致。
    public func targets(rightClicking id: UUID, in order: [UUID]) -> [UUID] {
        guard selected.contains(id), selected.count > 1 else { return [id] }
        return order.filter { selected.contains($0) }
    }

    /// 主机被删掉后清理选区。锚点也跟着没了，免得下一次 ⇧ 点从一个不存在的地方开始扩。
    public mutating func remove(_ ids: [UUID]) {
        selected.subtract(ids)
        if let anchor, ids.contains(anchor) {
            self.anchor = nil
        }
    }
}
