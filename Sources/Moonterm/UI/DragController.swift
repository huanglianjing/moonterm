import Combine
import CoreGraphics
import MoontermCore
import SwiftUI

/// 拖拽（tab 重排 / 分栏重新布局）过程中的临时状态。
///
/// **故意不挂在 `AppState` 上**：这里的值每一帧都在变，如果转发给 `AppState`，
/// 整棵分栏树（连同所有终端视图）都会跟着每帧重算 body。观察它的只有 tab 条和落点高亮层。
///
/// 坐标统一用 `.global`（窗口坐标）：手势与各视图的 `GeometryProxy` 都取同一个空间，
/// 省掉命名坐标空间在 macOS 13 上已废弃的那套 API。
final class DragController: ObservableObject {

    /// 正在拖什么。
    ///
    /// 两种载荷的落点集合是**互斥**的：tab 只能落在 tab 条上（重排），
    /// 分栏窗口只能落在分栏区里（重新布局），谁都不能越界 —— 见 `resolveTarget`。
    enum Payload: Equatable {
        /// tab 条上的一项（一台主机，可能包含多个分栏、多个窗口）。
        case tab(id: UUID)
        /// 分栏小标签条上的一个窗口。
        case pane(sessionID: UUID)
    }

    /// 松手后会发生什么。
    enum Target: Equatable {
        case none
        /// 落在 tab 条上：插到第 `insertIndex` 项之前（等于 tab 数就是插到末尾）。
        case tabBar(insertIndex: Int)
        /// 落在某个分栏的小标签条上：并进那个分栏，排在第 `insertIndex` 位。
        case paneHeader(anchor: UUID, insertIndex: Int)
        /// 落在某个分栏的内容区上。
        case pane(sessionID: UUID, zone: PaneDropZone)
    }

    /// 小标签条上的一个标签。
    struct Chip: Equatable {
        let sessionID: UUID
        let rect: CGRect
    }

    /// 一个分栏的小标签条。
    struct PaneHeader: Equatable {
        /// 这个分栏当前显示的会话，用来定位分栏。
        let anchor: UUID
        let rect: CGRect
        let chips: [Chip]
    }

    struct State: Equatable {
        var payload: Payload
        /// 跟随指针的「幽灵」上显示的名字。
        var title: String
        var location: CGPoint
        var target: Target = .none
    }

    @Published private(set) var state: State?

    // 下面这些是几何快照，由视图通过 preference 回填。**不是** `@Published`：
    // 它们变化不需要触发重绘，只在拖拽时被读取。
    /// 当前可见 tab 里各分栏的矩形（含小标签条），按分栏当前显示的会话索引。
    var paneFrames: [UUID: CGRect] = [:]
    /// 当前可见 tab 里各分栏的小标签条。
    var paneHeaders: [PaneHeader] = []
    /// tab 条上各 tab 的矩形，按显示顺序。
    var tabFrames: [TabFrame] = []
    /// 整条 tab 条的矩形。
    var tabBarFrame: CGRect = .zero

    struct TabFrame: Equatable {
        let id: UUID
        let rect: CGRect
    }

    // MARK: - 生命周期

    func update(payload: Payload, title: String, location: CGPoint) {
        var next = state ?? State(payload: payload, title: title, location: location)
        next.payload = payload
        next.title = title
        next.location = location
        next.target = resolveTarget(payload: payload, at: location)
        state = next
    }

    func end() {
        state = nil
    }

    func isDragging(_ payload: Payload) -> Bool {
        state?.payload == payload
    }

    // MARK: - 落点判定

    private func resolveTarget(payload: Payload, at point: CGPoint) -> Target {
        switch payload {
        case .tab:
            // tab 固定绑一台主机，只能在 tab 条上排序 —— 落到分栏区一律无效。
            guard tabBarFrame.contains(point) else { return .none }
            return .tabBar(insertIndex: insertIndex(at: point))

        case .pane:
            // 分栏窗口只能在自己 tab 的分栏区里重新布局 —— 落到 tab 条上一律无效。
            // （`paneFrames` / `paneHeaders` 只有当前可见 tab 会上报，所以天然跨不了 tab。）
            guard !tabBarFrame.contains(point) else { return .none }

            // 小标签条在分栏矩形内部，先判它。
            if let header = paneHeaders.first(where: { $0.rect.contains(point) }) {
                return .paneHeader(anchor: header.anchor, insertIndex: insertIndex(at: point, in: header))
            }

            guard let hit = paneFrames.first(where: { $0.value.contains(point) }) else { return .none }
            return .pane(sessionID: hit.key, zone: PaneDropZone.resolve(point: point, in: hit.value))
        }
    }

    /// 指针在某个小标签的左半边就插它前面，右半边就插它后面。
    private func insertIndex(at point: CGPoint, in header: PaneHeader) -> Int {
        for (index, chip) in header.chips.enumerated() where point.x < chip.rect.midX {
            return index
        }
        return header.chips.count
    }

    /// 指针在某个 tab 的左半边就插它前面，右半边就插它后面。
    private func insertIndex(at point: CGPoint) -> Int {
        for (index, frame) in tabFrames.enumerated() where point.x < frame.rect.midX {
            return index
        }
        return tabFrames.count
    }

    // MARK: - 高亮矩形

    /// 落点提示要画在哪儿（全局坐标）。`nil` 表示当前没有有效落点。
    func highlightRect(for target: Target) -> CGRect? {
        switch target {
        case .none:
            return nil

        case .tabBar(let insertIndex):
            guard !tabFrames.isEmpty else { return nil }
            let x: CGFloat
            if insertIndex < tabFrames.count {
                x = tabFrames[insertIndex].rect.minX
            } else {
                x = tabFrames[tabFrames.count - 1].rect.maxX
            }
            let rect = tabBarFrame
            return CGRect(x: x - 1.5, y: rect.minY + 3, width: 3, height: max(rect.height - 6, 1))

        case .paneHeader(let anchor, let insertIndex):
            // 小标签之间的插入位。
            guard let header = paneHeaders.first(where: { $0.anchor == anchor }) else { return nil }
            let x: CGFloat
            if insertIndex < header.chips.count {
                x = header.chips[insertIndex].rect.minX
            } else {
                x = header.chips.last?.rect.maxX ?? header.rect.minX + 4
            }
            return CGRect(x: x - 1.5, y: header.rect.minY + 2, width: 3, height: max(header.rect.height - 4, 1))

        case .pane(let sessionID, let zone):
            guard let frame = paneFrames[sessionID] else { return nil }
            switch zone {
            case .center:
                return frame
            case .edge(let edge):
                return Self.half(of: frame, on: edge)
            }
        }
    }

    /// 分栏矩形靠某条边的一半 —— 也就是新分栏将要占据的位置。
    static func half(of frame: CGRect, on edge: PaneEdge) -> CGRect {
        switch edge {
        case .leading:
            return CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .trailing:
            return CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .top:
            return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2)
        case .bottom:
            return CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2)
        }
    }
}

// MARK: - 几何回填

/// 当前可见 tab 的各分栏矩形。隐藏 tab 不上报，避免 key 打架。
struct PaneFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 当前可见 tab 里各分栏的小标签条。
struct PaneHeadersKey: PreferenceKey {
    static var defaultValue: [DragController.PaneHeader] = []

    static func reduce(value: inout [DragController.PaneHeader], nextValue: () -> [DragController.PaneHeader]) {
        value.append(contentsOf: nextValue())
    }
}

/// 一条小标签条内部各标签的矩形（只在那条标签条内部消费）。
struct ChipFramesKey: PreferenceKey {
    static var defaultValue: [DragController.Chip] = []

    static func reduce(value: inout [DragController.Chip], nextValue: () -> [DragController.Chip]) {
        value.append(contentsOf: nextValue())
    }
}

/// tab 条上各 tab 的矩形。
struct TabFramesKey: PreferenceKey {
    static var defaultValue: [DragController.TabFrame] = []

    static func reduce(value: inout [DragController.TabFrame], nextValue: () -> [DragController.TabFrame]) {
        value.append(contentsOf: nextValue())
    }
}

/// 整条 tab 条的矩形。
struct TabBarFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

extension View {

    /// 把自己的矩形（全局坐标）上报给 `DragController`。
    func reportFrame<K: PreferenceKey>(_ key: K.Type, transform: @escaping (CGRect) -> K.Value) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: key, value: transform(proxy.frame(in: .global)))
            }
        )
    }

    /// tab 与分栏子标题条共用的拖拽手势。
    func paneDrag(
        _ controller: DragController,
        payload: DragController.Payload,
        title: String,
        onDrop: @escaping () -> Void
    ) -> some View {
        gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { value in
                    controller.update(payload: payload, title: title, location: value.location)
                }
                .onEnded { value in
                    // 松手位置也要算一遍，免得最后一下移动没被 onChanged 收到。
                    controller.update(payload: payload, title: title, location: value.location)
                    onDrop()
                }
        )
    }
}
