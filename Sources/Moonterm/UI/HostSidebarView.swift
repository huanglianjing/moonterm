import AppKit
import MoontermCore
import SwiftUI

/// 竖栏「主机」图标展开的面板：分组在上、未分组的主机垫在最下面，单击选中、双击连接。
///
/// 选择语义照 Finder：⌘ 点单独加减一台，⇧ 点从锚点整段扩选；右键落在选区里就对整个选区操作。
/// 拖动也照 Finder：拖一台已经选中的主机 = 拖整片选区；拖分组标题 = 连里面的主机一起换位置。
///
/// 这里只放常用的几件事（连接、新建、分组、编辑、复制、删除）。排序之外的低频批量操作
/// 留在 ⌘, 的完整面板里。
struct HostSidebarView: View {

    @EnvironmentObject private var appState: AppState
    /// 拖拽状态。只有这个面板用，所以就挂在这儿，不进 `AppState`。
    @StateObject private var drag = HostDragController()

    /// 选中的主机。选择那套语义（重选 / 加减 / 扩选）是 `MoontermCore` 里的纯逻辑，有单测。
    @State private var selection = HostSelection()
    /// 待确认删除的主机，可能是一批。空 = 没在删。删主机会连密码一起删，不能点一下就没了。
    @State private var hostsPendingDeletion: [HostConfig] = []
    /// 待确认删除的分组。里面的主机不会跟着删，只是移到未分组。
    @State private var groupPendingDeletion: HostGroup?
    /// 正在就地改名的分组。新建分组后立刻进这个状态 —— 新建和改名是同一条路。
    @State private var groupBeingRenamed: UUID?
    /// 鼠标在标题栏那个 `+` 上。`Menu` 自己不给悬停状态，只能自己接。
    @State private var isPlusHovering = false
    /// 每点一次主机行就递增；AppKit 接收层据此拿回焦点，让删除键作用于当前主机选区。
    @State private var keyboardFocusRequest = 0

    private var store: ConfigStore { appState.configStore }

    var body: some View {
        VStack(spacing: 0) {
            header
            ChromeHairline()

            if rows.isEmpty {
                empty
            } else {
                list
            }
        }
        .frame(maxHeight: .infinity)
        .background(ChromeStyle.sidebar)
        .background(
            HostPanelKeyboardCatcher(
                focusRequest: keyboardFocusRequest,
                onDelete: requestSelectionDeletion,
                onDuplicate: duplicateSelection
            )
            .frame(width: 0, height: 0)
        )
        // 只监听、不命中：终端、tab 条或别的区域仍收到原点击，同时主机选区立刻收起。
        .background(HostPanelSelectionBoundary { selection.clear() })
        .alert(
            deletionTitle,
            isPresented: Binding(
                get: { !hostsPendingDeletion.isEmpty },
                set: { if !$0 { hostsPendingDeletion = [] } }
            ),
            presenting: hostsPendingDeletion
        ) { targets in
            Button("删除", role: .destructive) {
                targets.forEach { store.remove(id: $0.id) }
                selection.remove(targets.map { $0.id })
            }
            Button("取消", role: .cancel) {}
        }
        .alert(
            "删除分组「\(groupPendingDeletion?.displayName ?? "")」？",
            isPresented: Binding(
                get: { groupPendingDeletion != nil },
                set: { if !$0 { groupPendingDeletion = nil } }
            ),
            presenting: groupPendingDeletion
        ) { group in
            Button("删除分组", role: .destructive) {
                store.removeGroup(id: group.id)
            }
            Button("取消", role: .cancel) {}
        } message: { group in
            let count = store.hosts(inGroup: group.id).count
            Text(count == 0
                 ? "分组是空的，删掉不影响任何主机。"
                 : "里面的 \(count) 台主机不会被删除，会移到「未分组」的最下面。")
        }
    }

    private var deletionTitle: String {
        if hostsPendingDeletion.count > 1 {
            return "删除选中的 \(hostsPendingDeletion.count) 台主机？"
        }
        return "删除「\(hostsPendingDeletion.first?.displayName ?? "")」？"
    }

    // MARK: - 行

    /// 从上到下看到的每一行。分组在上、未分组垫底；折叠的分组不铺开里面的主机。
    private var rows: [HostSidebarRowKind] {
        var result: [HostSidebarRowKind] = []
        for group in store.groups {
            result.append(.group(group))
            if !group.isCollapsed {
                result.append(contentsOf: store.hosts(inGroup: group.id).map { .host($0) })
            }
        }
        let ungrouped = store.hosts(inGroup: nil)
        // 一个分组都没有时不必给「未分组」加标题：那时整个列表就是一份平铺的主机表。
        if !store.groups.isEmpty && !ungrouped.isEmpty {
            result.append(.ungroupedHeader)
        }
        result.append(contentsOf: ungrouped.map { .host($0) })
        return result
    }

    /// ⇧ 扩选的顺序按**看到的顺序**算，所以折叠起来的主机不算在内。
    private var visibleHostIDs: [UUID] {
        rows.compactMap { row in
            if case .host(let host) = row { return host.id }
            return nil
        }
    }

    // MARK: - 头尾

    private var header: some View {
        HStack(spacing: 4) {
            Text(SidebarPanel.hosts.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Menu {
                Button("添加主机…") {
                    selection.clear()
                    appState.beginCreatingHost()
                }
                Button("添加分组") {
                    selection.clear()
                    addGroup()
                }
            } label: {
                // 和 tab 上那些 ✕ 同一块方形底。**没有**按下压暗那一层：`Menu` 不给按下状态，
                // 换成 `.menuStyle(.button)` + 自定义 buttonStyle 之后菜单直接弹不出来了，
                // 不值得为一帧的视觉效果拿点得开菜单去换 —— 菜单立刻弹出来本身就是回应。
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .chromeIconCell(side: 22, hovering: isPlusHovering)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22, height: 22)
            .onHover { isPlusHovering = $0 }
            .help("添加主机或分组")
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .simultaneousGesture(TapGesture().onEnded { selection.clear() })
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text("还没有保存任何主机")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("新建主机…") { appState.beginCreatingHost() }
                .controlSize(.small)

            Button("新建分组") { addGroup() }
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 列表 + 它下面的空白。空白那块要**撑满剩余高度**才点得到 ——
    /// 光把 ScrollView 拉满没用，能接事件的是里面的内容，内容只有几行高的话下面全是死区。
    private var list: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(rows) { row in
                        view(for: row)
                            .reportFrame(HostRowFramesKey.self) {
                                [HostDragController.RowFrame(identity: row.identity, rect: $0)]
                            }
                    }

                    // 空白处点一下 = 全部取消选中；拖到这儿松手 = 挪到列表最下面（未分组末尾）。
                    Color.clear
                        .frame(minHeight: 8)
                        .frame(maxHeight: .infinity)
                        .onLeftClick { _, _ in selection.clear() }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                // 减掉上下 padding，正好填满一屏；多算了会凭空多出几像素可滚。
                .frame(minHeight: max(0, proxy.size.height - 8), alignment: .top)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .reportFrame(HostListFrameKey.self) { $0 }
            // 拖拽落点判定要用的几何信息。行的顺序按 y 排好，判定里直接当「从上到下」用。
            .onPreferenceChange(HostRowFramesKey.self) { frames in
                drag.rows = frames.sorted { $0.rect.minY < $1.rect.minY }
            }
            .onPreferenceChange(HostListFrameKey.self) { frame in
                drag.listFrame = frame
            }
            .overlay(HostDropIndicator(drag: drag))
        }
    }

    @ViewBuilder
    private func view(for row: HostSidebarRowKind) -> some View {
        switch row {
        case .group(let group):
            HostGroupHeaderRow(
                group: group,
                hostCount: store.hosts(inGroup: group.id).count,
                isRenaming: groupBeingRenamed == group.id,
                isBeingDragged: drag.isDragging(.group(group.id)),
                onToggle: {
                    selection.clear()
                    store.setGroup(id: group.id, collapsed: !group.isCollapsed)
                },
                onDrag: { phase in handleGroupDrag(group, phase: phase) },
                onRename: { name in
                    store.renameGroup(id: group.id, to: name)
                    groupBeingRenamed = nil
                },
                onCancelRename: { groupBeingRenamed = nil }
            )
            .contextMenu { menu(for: group) }

        case .ungroupedHeader:
            HostSectionHeaderRow(title: "未分组")

        case .host(let host):
            HostSidebarRow(
                host: host,
                isSelected: selection.contains(host.id),
                isIndented: host.groupID != nil,
                isBeingDragged: drag.isDraggingHost(host.id),
                onClick: { clickCount, modifiers in
                    keyboardFocusRequest &+= 1
                    if clickCount > 1 {
                        connect([host])
                    } else {
                        click(host, modifiers: modifiers)
                    }
                },
                onDrag: { phase in handleHostDrag(host, phase: phase) }
            )
            .contextMenu { menu(for: host) }
        }
    }

    // MARK: - 选择

    /// 修饰键翻译成选择语义。⌘ 和 ⇧ 一起按时以 ⌘ 为准（macOS 各家列表都这么处理）。
    private func click(_ host: HostConfig, modifiers: NSEvent.ModifierFlags) {
        let kind: HostSelection.Click
        if modifiers.contains(.command) {
            kind = .toggle
        } else if modifiers.contains(.shift) {
            kind = .extend
        } else {
            kind = .plain
        }
        selection.click(host.id, kind: kind, in: visibleHostIDs)
    }

    // MARK: - 拖动

    private func handleHostDrag(_ host: HostConfig, phase: LeftDragPhase) {
        switch phase {
        case .changed(let point):
            let ids = draggedHostIDs(grabbing: host)
            drag.update(
                payload: .hosts(ids),
                title: ids.count > 1 ? "\(ids.count) 台主机" : host.displayName,
                from: .host(id: host.id, group: host.groupID),
                localPoint: point
            )
        case .ended:
            commitDrag()
        }
    }

    private func handleGroupDrag(_ group: HostGroup, phase: LeftDragPhase) {
        switch phase {
        case .changed(let point):
            drag.update(
                payload: .group(group.id),
                title: group.displayName,
                from: .groupHeader(group.id),
                localPoint: point
            )
        case .ended:
            commitDrag()
        }
    }

    /// 拖一台已经在选区里的主机 = 拖整片选区（Finder 的规矩）；否则只拖它自己。
    /// 顺序按列表顺序，落地后的相对次序才和拖之前看到的一致。
    private func draggedHostIDs(grabbing host: HostConfig) -> [UUID] {
        guard selection.contains(host.id), selection.count > 1 else { return [host.id] }
        return store.displayOrderedHostIDs.filter { selection.contains($0) }
    }

    private func commitDrag() {
        let state = drag.state
        drag.end()
        guard let state else { return }

        switch (state.payload, state.target) {
        case (.hosts(let ids), .hosts(let group, let before)):
            store.move(hostIDs: ids, toGroup: group, before: before)

        case (.group(let id), .group(let before)):
            store.moveGroup(id: id, before: before)

        default:
            // 落在列表外面（或落点就是原位）：什么都不做。
            break
        }
    }

    // MARK: - 操作

    /// 一台一个新 tab，按列表顺序开；最后开的那个成为当前 tab。
    private func connect(_ targets: [HostConfig]) {
        targets.forEach { appState.open(host: $0) }
    }

    private func addGroup() {
        let group = store.addGroup()
        // 新建完直接进改名状态：省掉「先建再改」两步，也不用为它单开一个弹窗。
        groupBeingRenamed = group.id
    }

    private func requestSelectionDeletion() {
        guard hostsPendingDeletion.isEmpty,
              groupPendingDeletion == nil,
              groupBeingRenamed == nil
        else { return }

        let targets = store.displayOrderedHostIDs
            .filter { selection.contains($0) }
            .compactMap { store.host(id: $0) }
        guard !targets.isEmpty else { return }
        hostsPendingDeletion = targets
    }

    /// `⌘D` 和右键菜单里的「复制」保持同一边界：多选时不猜该复制哪台。
    private func duplicateSelection() {
        guard selection.count == 1,
              let id = store.displayOrderedHostIDs.first(where: { selection.contains($0) })
        else { return }
        store.duplicate(id: id)
    }

    @ViewBuilder
    private func menu(for host: HostConfig) -> some View {
        let targets = menuTargets(for: host)

        if targets.count > 1 {
            Button("连接选中的 \(targets.count) 台") { connect(targets) }
            Divider()
            moveMenu(for: targets)
            Divider()
            Button("删除选中的 \(targets.count) 台…") { hostsPendingDeletion = targets }
        } else {
            Button("连接") { connect(targets) }
            Button("编辑…") { appState.beginEditing(host: host) }
            Button("复制") { store.duplicate(id: host.id) }
            Divider()
            moveMenu(for: targets)
            Divider()
            Button("删除…") { hostsPendingDeletion = targets }
        }
    }

    /// 不想拖的时候也能换分组 —— 分组一多，拖到看不见的地方并不方便。
    ///
    /// 只列**真的能去**的地方：一个分组都没建时就一条灰着的说明；选中的几台都在同一段里时，
    /// 那一段不出现（移到自己已经在的地方没有意义）；散落在不同段时全都列出来。
    @ViewBuilder
    private func moveMenu(for targets: [HostConfig]) -> some View {
        // 去处的取舍是 `ConfigStore` 那边的纯逻辑（有单测），这里只管画。
        let destinations = store.moveDestinations(forHostIDs: targets.map { $0.id })

        Menu("移到分组") {
            if destinations.isEmpty {
                // 一个分组都还没建：留一条灰着的说明，比一个空菜单好懂。
                Button("未创建分组") {}
                    .disabled(true)
            } else {
                ForEach(destinations, id: \.self) { destination in
                    switch destination {
                    case .group(let group):
                        Button(group.displayName) { move(targets, toGroup: group.id) }

                    case .ungrouped:
                        // 未分组永远排在最后，前面有分组时才需要这条分隔线。
                        if destinations.count > 1 {
                            Divider()
                        }
                        Button("未分组") { move(targets, toGroup: nil) }
                    }
                }
            }
        }
    }

    private func move(_ targets: [HostConfig], toGroup group: UUID?) {
        store.move(hostIDs: targets.map { $0.id }, toGroup: group, before: nil)
    }

    @ViewBuilder
    private func menu(for group: HostGroup) -> some View {
        Button("在此分组新建主机…") { appState.beginCreatingHost(inGroup: group.id) }
        Button(group.isCollapsed ? "展开" : "折叠") {
            store.setGroup(id: group.id, collapsed: !group.isCollapsed)
        }
        Button("重命名") { groupBeingRenamed = group.id }
        Divider()
        Button("删除分组…") { groupPendingDeletion = group }
    }

    private func menuTargets(for host: HostConfig) -> [HostConfig] {
        let ids = selection.targets(rightClicking: host.id, in: visibleHostIDs)
        return ids.compactMap { id in store.host(id: id) }
    }
}

// MARK: - 主机面板键盘焦点

/// 主机行的点击由 AppKit 命中层接收，不会自动成为键盘第一响应者。这个零尺寸视图在选中主机后
/// 接住 Backspace / Delete，并把删除交给面板现有的批量确认流程；点回终端后焦点会自然还给终端。
private struct HostPanelKeyboardCatcher: NSViewRepresentable {

    let focusRequest: Int
    let onDelete: () -> Void
    let onDuplicate: () -> Void

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.lastFocusRequest = focusRequest
        view.onDelete = onDelete
        view.onDuplicate = onDuplicate
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.onDelete = onDelete
        nsView.onDuplicate = onDuplicate
        guard nsView.lastFocusRequest != focusRequest else { return }
        nsView.lastFocusRequest = focusRequest

        // mouseDown 回调发生时视图层级可能还在更新，下一轮 runloop 再拿焦点更稳定。
        DispatchQueue.main.async { [weak nsView] in
            guard let nsView, let window = nsView.window else { return }
            window.makeFirstResponder(nsView)
        }
    }

    final class KeyView: NSView {

        var lastFocusRequest = 0
        var onDelete: (() -> Void)?
        var onDuplicate: (() -> Void)?
        private var duplicateShortcutMonitor: Any?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoringDuplicateShortcut()
            guard window != nil else { return }

            // 菜单快捷键匹配发生在 first responder 的 keyDown 之前。和 AppDelegate 接 ⌘W
            // 一样从本地监视器抢先判断，才能保证这里的 ⌘D 不被别的菜单项接走。
            duplicateShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      window?.firstResponder === self,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command],
                      event.charactersIgnoringModifiers?.lowercased() == "d"
                else { return event }
                onDuplicate?()
                return nil
            }
        }

        override func keyDown(with event: NSEvent) {
            // 51 是 Backspace，117 是 Forward Delete；Fn+Backspace 到这里时也会成为 117。
            let disallowedModifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard disallowedModifiers.isEmpty, event.keyCode == 51 || event.keyCode == 117 else {
                super.keyDown(with: event)
                return
            }
            onDelete?()
        }

        private func stopMonitoringDuplicateShortcut() {
            if let duplicateShortcutMonitor {
                NSEvent.removeMonitor(duplicateShortcutMonitor)
                self.duplicateShortcutMonitor = nil
            }
        }

        deinit {
            stopMonitoringDuplicateShortcut()
        }
    }
}

// MARK: - 面板外点击

/// 透明的面板边界，只用本地事件监视器观察鼠标落点，不参与命中测试。
///
/// SwiftTerm 是 AppKit 的 NSView，SwiftUI 父级手势收不到它的点击；从事件入口观察才能让
/// 「点终端取消主机选中」可靠生效，同时又不截断终端原本的鼠标选择与聚焦。
private struct HostPanelSelectionBoundary: NSViewRepresentable {

    let onClickOutside: () -> Void

    func makeNSView(context: Context) -> BoundaryView {
        let view = BoundaryView()
        view.onClickOutside = onClickOutside
        return view
    }

    func updateNSView(_ nsView: BoundaryView, context: Context) {
        nsView.onClickOutside = onClickOutside
    }

    static func dismantleNSView(_ nsView: BoundaryView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class BoundaryView: NSView {

        var onClickOutside: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                guard let self, let panelWindow = window else { return event }

                if event.window === panelWindow {
                    let point = convert(event.locationInWindow, from: nil)
                    if !bounds.contains(point) {
                        onClickOutside?()
                    }
                } else if event.window?.sheetParent === panelWindow {
                    onClickOutside?()
                }
                return event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            stopMonitoring()
        }
    }
}

// MARK: - 行的种类

/// 列表里的一行。`ForEach` 用它当数据源，`identity` 是拖拽落点判定用的那份身份。
private enum HostSidebarRowKind: Identifiable {
    case group(HostGroup)
    case ungroupedHeader
    case host(HostConfig)

    var id: String {
        switch self {
        case .group(let group): return "group-\(group.id)"
        case .ungroupedHeader: return "ungrouped"
        case .host(let host): return "host-\(host.id)"
        }
    }

    var identity: HostRowIdentity {
        switch self {
        case .group(let group): return .groupHeader(group.id)
        case .ungroupedHeader: return .ungroupedHeader
        case .host(let host): return .host(id: host.id, group: host.groupID)
        }
    }
}

// MARK: - 分组标题行

/// 分组标题行。点一下折叠/展开，拖动可以给分组换位置。
///
/// 折叠**在松手时才生效**（`clickOnRelease`）：折叠和拖动共用同一片区域，按下就折叠的话
/// 一开拖列表就先跳一下，落点全乱。
private struct HostGroupHeaderRow: View {

    let group: HostGroup
    let hostCount: Int
    let isRenaming: Bool
    let isBeingDragged: Bool
    let onToggle: () -> Void
    let onDrag: (LeftDragPhase) -> Void
    let onRename: (String) -> Void
    let onCancelRename: () -> Void

    @State private var isHovering = false

    var body: some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovering && !isRenaming ? ChromeStyle.hover : .clear)
            )
            .contentShape(Rectangle())
            .opacity(isBeingDragged ? 0.4 : 1)
            .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var content: some View {
        if isRenaming {
            // 改名时不挂点击层：否则这层会把点击吃掉，光标点不进输入框。
            HStack(spacing: 4) {
                chevron
                HostGroupNameField(
                    initialName: group.name,
                    onCommit: onRename,
                    onCancel: onCancelRename
                )
            }
        } else {
            label
                .onLeftMouse(click: { _, _ in onToggle() }, drag: onDrag, clickOnRelease: true)
                .help("\(hostCount) 台主机（点一下折叠/展开，拖动可换位置）")
        }
    }

    private var label: some View {
        HStack(spacing: 4) {
            chevron

            Text(group.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            // 主机台数只放在 tooltip 里，行上不挂数字 —— 列表要干净。
            Spacer(minLength: 0)
        }
    }

    private var chevron: some View {
        Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 10)
    }
}

/// 「未分组」那条标题行。纯标签：它既不能折叠也不能拖 —— 未分组永远垫在最下面。
private struct HostSectionHeaderRow: View {

    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 分组就地改名：回车或点别处确认，Esc 放弃，清空则退回默认名。
private struct HostGroupNameField: View {

    let initialName: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var draft = ""
    /// 提交与放弃都只能发生一次：Esc 之后输入框会失焦，别再把草稿又提交一遍。
    @State private var isSettled = false
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .focused($isFocused)
            .frame(height: 16)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.black.opacity(0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(ChromeStyle.accent, lineWidth: 1)
            )
            .onAppear {
                draft = initialName
                isFocused = true
            }
            .onSubmit { settle { onCommit(draft) } }
            .onExitCommand { settle(onCancel) }
            .onChange(of: isFocused) { focused in
                // 点到别处 = 确认，和 Finder 改文件名一致。
                guard !focused else { return }
                settle { onCommit(draft) }
            }
            .help("回车确认，Esc 取消")
    }

    private func settle(_ body: () -> Void) {
        guard !isSettled else { return }
        isSettled = true
        body()
    }
}

// MARK: - 主机行

/// 列表里的一行主机。单击选中，双击连接（每次双击都是一个新 tab，同一台主机开几个都行）。
private struct HostSidebarRow: View {

    let host: HostConfig
    let isSelected: Bool
    /// 在某个分组里：名字往右缩一格，看出层级。
    let isIndented: Bool
    let isBeingDragged: Bool
    /// 点击次数 + 修饰键，选择与打开的判定都交给列表那边做。
    let onClick: (Int, NSEvent.ModifierFlags) -> Void
    let onDrag: (LeftDragPhase) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(host.displayName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(host.endpointDescription)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, isIndented ? 18 : 6)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(background)
        )
        .opacity(isBeingDragged ? 0.4 : 1)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onLeftMouse(click: onClick, drag: onDrag)
        .help("\(host.endpointDescription)（单击选中，双击连接；⌘ / ⇧ 点可多选，拖动可排序、换分组）")
    }

    private var background: Color {
        if isSelected { return ChromeStyle.selectedRow }
        return isHovering ? ChromeStyle.hover : .clear
    }
}

/// 面板右边缘：拖着改宽度。
///
/// 和分栏分割线一个道理，位移必须取**全局坐标** —— 这条边自己会跟着宽度移动，
/// 用局部坐标算等于把输出接回输入。
struct SidebarResizeHandle: View {

    @EnvironmentObject private var appState: AppState

    /// 起手时的宽度：每帧拿它加位移算绝对值，避免误差累积。
    @State private var base: CGFloat?
    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(isHovering ? ChromeStyle.dividerHovered : ChromeStyle.divider)
            .frame(width: 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = base ?? appState.sidebarWidth
                        base = start
                        appState.setSidebarWidth(start + value.translation.width)
                    }
                    .onEnded { _ in base = nil }
            )
    }
}
