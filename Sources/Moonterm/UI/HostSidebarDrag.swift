import CoreGraphics
import Foundation
import SwiftUI

/// 侧栏主机列表里一行的身份。落点判定只需要这些，不需要整份配置。
enum HostRowIdentity: Equatable {
    case groupHeader(UUID)
    /// 「未分组」那条标题行。
    case ungroupedHeader
    /// 一台主机，以及它当前所在的分组（nil = 未分组）。
    case host(id: UUID, group: UUID?)
}

/// 侧栏里拖主机 / 拖分组的临时状态。
///
/// 和 tab、分栏那套（`DragController`）**分开**：两边的落点集合毫无交集，混在一起只会让
/// 双方的判定都变复杂。侧栏这份也不需要跨视图共享，就挂在侧栏自己身上。
///
/// 坐标统一用 SwiftUI 的 `.global`：行矩形由 `GeometryReader` 上报，指针位置由行视图把
/// AppKit 的局部坐标加上自己的全局原点换算过来（见 `update(payload:title:from:localPoint:)`）。
final class HostDragController: ObservableObject {

    /// 正在拖什么。
    enum Payload: Equatable {
        /// 一台或多台主机。多选时整片一起搬，顺序就是列表里看到的顺序。
        case hosts([UUID])
        /// 一个分组（连里面的主机一起动）。
        case group(UUID)
    }

    /// 松手后会发生什么。
    enum Target: Equatable {
        case none
        /// 主机搬进 `group`（nil = 未分组），插到 `before` 之前（nil = 那一段的末尾）。
        case hosts(group: UUID?, before: UUID?)
        /// 分组插到 `before` 之前（nil = 最后一个分组之后）。
        case group(before: UUID?)
    }

    /// 落点长什么样。
    enum Indicator: Equatable {
        /// 一条插入线，画在这个 y（全局坐标）上，横向铺满列表。
        case line(y: CGFloat)
        /// 整行高亮：整片落进这个分组。
        case box(CGRect)
    }

    struct State: Equatable {
        var payload: Payload
        /// 跟着指针走的那个「幽灵」上写什么。
        var title: String
        var location: CGPoint
        var target: Target = .none
        var indicator: Indicator?
    }

    @Published private(set) var state: State?

    // 下面两份是几何快照，由列表视图通过 preference 回填。**不是** `@Published`：
    // 它们变化不需要触发重绘，只在拖拽时被读一读。
    /// 列表里各行的矩形，按从上到下排好。
    var rows: [RowFrame] = []
    /// 整块列表区域（含末尾空白）。指针跑出去就没有落点 —— 拖到终端区不该改顺序。
    var listFrame: CGRect = .zero

    struct RowFrame: Equatable {
        let identity: HostRowIdentity
        let rect: CGRect
    }

    // MARK: - 生命周期

    /// 行视图报告拖动。`localPoint` 是**行内**坐标，这里用行矩形换算成全局坐标 ——
    /// 拖拽期间模型不变、行也不动，所以这份快照全程有效。
    func update(payload: Payload, title: String, from identity: HostRowIdentity, localPoint: CGPoint) {
        guard let origin = rows.first(where: { $0.identity == identity })?.rect.origin else { return }
        update(payload: payload, title: title, at: CGPoint(x: origin.x + localPoint.x, y: origin.y + localPoint.y))
    }

    func update(payload: Payload, title: String, at location: CGPoint) {
        let resolved = resolveTarget(payload: payload, at: location)
        state = State(
            payload: payload,
            title: title,
            location: location,
            target: resolved.target,
            indicator: resolved.indicator
        )
    }

    func end() {
        state = nil
    }

    func isDragging(_ payload: Payload) -> Bool {
        state?.payload == payload
    }

    /// 正在被拖的主机（多选时是一整片）。这些行画淡一点。
    func isDraggingHost(_ id: UUID) -> Bool {
        guard let state, case .hosts(let ids) = state.payload else { return false }
        return ids.contains(id)
    }

    // MARK: - 落点判定

    private func resolveTarget(payload: Payload, at point: CGPoint) -> (target: Target, indicator: Indicator?) {
        // 拖出列表就没有落点：指针回来还能接着拖，松手则什么都不做。
        guard listFrame.contains(point) else { return (.none, nil) }

        switch payload {
        case .hosts(let ids):
            let resolved = hostTarget(at: point)
            // 落点就在被拖的这几台里面 = 原地不动，那就别画线，让用户看出来这一下没用。
            if case .hosts(_, let before) = resolved.target, let before, ids.contains(before) {
                return (.none, nil)
            }
            return resolved

        case .group(let id):
            return groupTarget(dragging: id, at: point)
        }
    }

    /// 主机的落点。落在标题行上 = 整片放进那一段；落在主机行上 = 按上下半边插到它前 / 后。
    private func hostTarget(at point: CGPoint) -> (target: Target, indicator: Indicator?) {
        guard let last = rows.last else { return (.hosts(group: nil, before: nil), nil) }

        // 落在最后一行下面（列表末尾那块空白）：接到未分组的末尾，也就是整个列表最下面。
        guard point.y <= last.rect.maxY else {
            return (.hosts(group: nil, before: nil), .line(y: last.rect.maxY))
        }

        // 比第一行还高时退回第 0 行，按它的上半边处理。
        let index = rows.lastIndex { point.y >= $0.rect.minY } ?? 0
        let row = rows[index]

        switch row.identity {
        case .groupHeader(let groupID):
            return (.hosts(group: groupID, before: firstHostID(inGroup: groupID)), .box(row.rect))

        case .ungroupedHeader:
            return (.hosts(group: nil, before: firstHostID(inGroup: nil)), .box(row.rect))

        case .host(let id, let group):
            if point.y < row.rect.midY {
                return (.hosts(group: group, before: id), .line(y: row.rect.minY))
            }
            // 下半边 = 插到它后面：同一段里的下一台之前；没有下一台就是这一段的末尾。
            let next = nextHost(after: index, inGroup: group)
            return (.hosts(group: group, before: next?.id), .line(y: next?.rect.minY ?? row.rect.maxY))
        }
    }

    /// 分组的落点。分组只在「分组区」里排序，永远排在未分组那段之上。
    private func groupTarget(dragging id: UUID, at point: CGPoint) -> (target: Target, indicator: Indicator?) {
        let headers = rows.compactMap { row -> (id: UUID, rect: CGRect)? in
            guard case .groupHeader(let groupID) = row.identity else { return nil }
            return (groupID, row.rect)
        }

        for header in headers where point.y < header.rect.midY {
            // 插到自己前面 = 原地不动。
            guard header.id != id else { return (.none, nil) }
            return (.group(before: header.id), .line(y: header.rect.minY))
        }

        // 落在所有分组下面：排到最后一个分组之后。已经在最后就没什么可做的。
        guard headers.last?.id != id else { return (.none, nil) }
        return (.group(before: nil), .line(y: groupsBottomY))
    }

    /// 分组区的下边界：未分组那段的第一行，没有未分组主机就是列表最后一行的底边。
    private var groupsBottomY: CGFloat {
        let firstUngrouped = rows.first { row in
            switch row.identity {
            case .ungroupedHeader: return true
            case .host(_, let group): return group == nil
            case .groupHeader: return false
            }
        }
        return firstUngrouped?.rect.minY ?? rows.last?.rect.maxY ?? listFrame.minY
    }

    private func firstHostID(inGroup groupID: UUID?) -> UUID? {
        for row in rows {
            if case .host(let id, let group) = row.identity, group == groupID { return id }
        }
        return nil
    }

    private func nextHost(after index: Int, inGroup groupID: UUID?) -> (id: UUID, rect: CGRect)? {
        for row in rows[(index + 1)...] {
            switch row.identity {
            case .host(let id, let group) where group == groupID:
                return (id, row.rect)
            case .host:
                // 到了别的分组，说明本段已经结束。
                return nil
            case .groupHeader, .ungroupedHeader:
                return nil
            }
        }
        return nil
    }
}

// MARK: - 几何回填

/// 列表里各行的矩形。
struct HostRowFramesKey: PreferenceKey {
    static var defaultValue: [HostDragController.RowFrame] = []

    static func reduce(value: inout [HostDragController.RowFrame], nextValue: () -> [HostDragController.RowFrame]) {
        value.append(contentsOf: nextValue())
    }
}

/// 整块列表区域。
struct HostListFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

// MARK: - 落点提示

/// 盖在主机列表上的一层：插入线 / 整段高亮，外加跟着指针走的「幽灵」。
///
/// 只观察 `HostDragController`，每帧重画的就这一层。
struct HostDropIndicator: View {

    @ObservedObject var drag: HostDragController

    var body: some View {
        GeometryReader { proxy in
            if let state = drag.state {
                // 手势与各行矩形都是全局坐标，这里换算回本层坐标。
                let frame = proxy.frame(in: .global)

                ZStack(alignment: .topLeading) {
                    if let indicator = state.indicator {
                        self.indicator(indicator, in: frame)
                    }

                    ghost(title: state.title)
                        .position(
                            x: state.location.x - frame.minX + 10,
                            y: state.location.y - frame.minY + 12
                        )
                }
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func indicator(_ indicator: HostDragController.Indicator, in frame: CGRect) -> some View {
        switch indicator {
        case .line(let y):
            // 两行之间的插入线。
            Rectangle()
                .fill(ChromeStyle.accent)
                .frame(width: max(frame.width - 8, 1), height: 2)
                .position(x: frame.width / 2, y: y - frame.minY)

        case .box(let rect):
            // 整段高亮：松手会放进这个分组。
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(ChromeStyle.accent, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX - frame.minX, y: rect.midY - frame.minY)
        }
    }

    private func ghost(title: String) -> some View {
        Text(title)
            .font(.system(size: 11))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.primary.opacity(0.18))
            )
            .opacity(0.92)
    }
}
