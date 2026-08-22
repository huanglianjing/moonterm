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
        /// 起手位置。tab 拖拽时被拖的那个 tab 要按位移跟着指针走。
        var startLocation: CGPoint
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
    /// 起手那一刻的 tab 几何快照。
    ///
    /// 拖拽期间 tab 只做**视觉平移**（`.offset`），模型里的顺序等松手才改，所以这份快照全程有效。
    /// 插入位必须按快照算：实时矩形里含着平移量，拿它算等于把输出接回输入，tab 会来回抖。
    private var tabFramesAtDragStart: [TabFrame] = []

    struct TabFrame: Equatable {
        let id: UUID
        let rect: CGRect
    }

    // MARK: - 生命周期

    func update(payload: Payload, title: String, location: CGPoint) {
        if state?.payload != payload {
            // 起手（或中途换了拖拽对象）：记下起点，并把 tab 几何拍个快照。
            tabFramesAtDragStart = tabFrames
            state = State(payload: payload, title: title, startLocation: location, location: location)
        }
        var next = state ?? State(payload: payload, title: title, startLocation: location, location: location)
        next.payload = payload
        next.title = title
        next.location = location
        next.target = resolveTarget(payload: payload, at: location)
        state = next
    }

    func end() {
        state = nil
        tabFramesAtDragStart = []
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

    /// 指针在某个 tab 的左半边就插它前面，右半边就插它后面。按起手快照算，见 `tabFramesAtDragStart`。
    private func insertIndex(at point: CGPoint) -> Int {
        let frames = tabFramesAtDragStart.isEmpty ? tabFrames : tabFramesAtDragStart
        for (index, frame) in frames.enumerated() where point.x < frame.rect.midX {
            return index
        }
        return frames.count
    }

    // MARK: - tab 实时平移

    /// 拖 tab 时各 tab 该平移多少（按 tab id，横向点数）。没在拖 tab 就是空的。
    ///
    /// 只是**视觉预览**：模型里的顺序等松手才由 `moveTab` 改。位移按快照里各 tab 的实际宽度
    /// 重新累加，所以宽窄不一的 tab 也能滑到正确的位置。
    func tabShifts() -> [UUID: CGFloat] {
        guard let state,
              case .tab(let draggedID) = state.payload,
              case .tabBar(let insertIndex) = state.target,
              let from = tabFramesAtDragStart.firstIndex(where: { $0.id == draggedID })
        else { return [:] }

        var reordered = tabFramesAtDragStart
        let moved = reordered.remove(at: from)
        // `insertIndex` 是「插到原列表第几项之前」，摘掉自己之后目标下标要往前挪一格。
        let destination = min(max(insertIndex > from ? insertIndex - 1 : insertIndex, 0), reordered.count)
        reordered.insert(moved, at: destination)

        // 快照里相邻两项的间隙就是 tab 条 HStack 的 spacing。
        let spacing = tabFramesAtDragStart.count > 1
            ? max(tabFramesAtDragStart[1].rect.minX - tabFramesAtDragStart[0].rect.maxX, 0)
            : 0

        var shifts: [UUID: CGFloat] = [:]
        var x = tabFramesAtDragStart[0].rect.minX
        for frame in reordered {
            shifts[frame.id] = x - frame.rect.minX
            x += frame.rect.width + spacing
        }
        return shifts
    }

    /// 被拖的那个 tab 跟着指针走的横向位移。没在拖 tab 就是 0。
    var draggedTabTranslation: CGFloat {
        guard let state, case .tab = state.payload else { return 0 }
        return state.location.x - state.startLocation.x
    }

    /// 正在拖 tab。平移动画只在拖拽期间开着：松手那一下顺序真的变了，
    /// 平移量必须**立刻**归零，否则 tab 会先跳一格再滑回来。
    var isDraggingTab: Bool {
        guard let state, case .tab = state.payload else { return false }
        return true
    }

    // MARK: - 高亮矩形

    /// 落点提示要画在哪儿（全局坐标）。`nil` 表示当前没有有效落点。
    func highlightRect(for target: Target) -> CGRect? {
        switch target {
        case .none:
            return nil

        case .tabBar:
            // tab 重排不画插入线：各 tab 直接实时滑到新位置（`tabShifts()`），落点自己就看得见。
            return nil

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
