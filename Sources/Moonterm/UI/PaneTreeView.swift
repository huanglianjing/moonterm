import AppKit
import MoontermCore
import SwiftUI

/// 把一个 tab 的分栏树摆成界面。
///
/// `isActive` 表示这个 tab 当前是否可见：只有可见的 tab 才上报几何信息（拖拽落点判定用），
/// 也只有它才画焦点边框。隐藏的 tab 依然完整渲染 —— 终端视图必须留在层级里，否则 PTY 会被杀。
struct PaneTreeView: View {

    let tab: TerminalTab
    let isActive: Bool

    var body: some View {
        PaneNodeView(node: tab.root, tab: tab, isActive: isActive)
    }
}

// MARK: - 递归节点

private struct PaneNodeView: View {

    let node: PaneNode
    let tab: TerminalTab
    let isActive: Bool

    var body: some View {
        switch node.content {
        case .group(let group):
            PaneLeafView(group: group, tab: tab, isActive: isActive)
        case .split(let axis, let children):
            SplitView(splitID: node.id, axis: axis, children: children, tab: tab, isActive: isActive)
        }
    }
}

// MARK: - 分栏容器

private struct SplitView: View {

    /// 分割线厚度，同时也是拖拽热区。
    static let dividerThickness: CGFloat = 6
    /// 分栏最短边：拖分割线时不能把任何一栏压得比这更小。
    static let minPaneLength: CGFloat = 120

    let splitID: UUID
    let axis: PaneAxis
    let children: [PaneNode.Child]
    let tab: TerminalTab
    let isActive: Bool

    @EnvironmentObject private var appState: AppState
    /// 拖分割线时记住是哪条线、起手占比是多少：每帧拿它加上位移算绝对值，
    /// 避免把上一帧的输出又当输入而累积误差。
    @State private var resizeBase: (dividerIndex: Int, fractions: [CGFloat])?

    var body: some View {
        GeometryReader { proxy in
            let total = axis == .horizontal ? proxy.size.width : proxy.size.height
            let available = max(total - Self.dividerThickness * CGFloat(children.count - 1), 0)
            stack(available: available)
        }
    }

    @ViewBuilder
    private func stack(available: CGFloat) -> some View {
        if axis == .horizontal {
            HStack(spacing: 0) { panes(available: available) }
        } else {
            VStack(spacing: 0) { panes(available: available) }
        }
    }

    @ViewBuilder
    private func panes(available: CGFloat) -> some View {
        ForEach(Array(children.enumerated()), id: \.element.node.id) { index, child in
            // 取整到整点：终端按字符格排版，半个点的宽度只会让内容来回抖。
            let length = max((child.fraction * available).rounded(), 0)

            PaneNodeView(node: child.node, tab: tab, isActive: isActive)
                .frame(
                    width: axis == .horizontal ? length : nil,
                    height: axis == .vertical ? length : nil
                )

            if index < children.count - 1 {
                PaneDivider(
                    axis: axis,
                    thickness: Self.dividerThickness,
                    onChanged: { translation in
                        resize(dividerIndex: index, translation: translation, available: available)
                    },
                    onEnded: { resizeBase = nil },
                    onDoubleClick: {
                        resizeBase = nil
                        appState.centerDivider(at: index, splitID: splitID, tabID: tab.id)
                    }
                )
            }
        }
    }

    /// 拖分割线：只在相邻两栏之间搬占比，别的分栏不受影响。
    ///
    /// `translation` 必须是**全局坐标**里的位移 —— 分割线本身会随占比移动，
    /// 用它自己的局部坐标系算位移等于把输出接回输入，线就会跟着鼠标来回跳。
    private func resize(dividerIndex: Int, translation: CGFloat, available: CGFloat) {
        guard available > 0 else { return }

        let base: [CGFloat]
        if let resizeBase, resizeBase.dividerIndex == dividerIndex {
            base = resizeBase.fractions
        } else {
            base = children.map { $0.fraction }
            resizeBase = (dividerIndex, base)
        }
        guard base.indices.contains(dividerIndex + 1) else { return }

        // 全程用「点」计算再换回占比，避免小数占比反复归一化带来的抖动。
        let pairLength = (base[dividerIndex] + base[dividerIndex + 1]) * available
        let minLength = min(Self.minPaneLength, pairLength / 2 - 1)
        guard pairLength > 2, minLength > 0 else { return }

        let wanted = base[dividerIndex] * available + translation
        let leading = min(max(wanted.rounded(), minLength), pairLength - minLength)

        var updated = base
        updated[dividerIndex] = leading / available
        updated[dividerIndex + 1] = (pairLength - leading) / available
        appState.setFractions(updated, splitID: splitID, tabID: tab.id)
    }
}

// MARK: - 分割线

private struct PaneDivider: View {

    let axis: PaneAxis
    let thickness: CGFloat
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void
    let onDoubleClick: () -> Void

    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(isHovering ? ChromeStyle.dividerHovered : ChromeStyle.divider)
            .frame(
                width: axis == .horizontal ? thickness : nil,
                height: axis == .vertical ? thickness : nil
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                // 坐标空间必须是 .global：分割线自己会动，局部坐标系算出来的位移是自激的。
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        onChanged(axis == .horizontal ? value.translation.width : value.translation.height)
                    }
                    .onEnded { _ in onEnded() }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded(onDoubleClick)
            )
            .help("拖动调整比例，双击恢复居中")
    }
}

// MARK: - 单个分栏

private struct PaneLeafView: View {

    @EnvironmentObject private var appState: AppState

    let group: PaneGroup
    let tab: TerminalTab
    let isActive: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 每个分栏都有标题栏 —— 新 tab 里那个全屏分栏也一样（就叫「窗口1」）。
            PaneHeaderBar(group: group, tab: tab, isActive: isActive)
            ChromeHairline()

            // 这个分栏里所有会话都留在层级里，只用透明度决定谁可见（和切 tab 同一个道理）。
            ZStack {
                ForEach(group.sessionIDs, id: \.self) { sessionID in
                    if let session = appState.session(id: sessionID) {
                        let visible = sessionID == group.activeID
                        TerminalContainer(session: session)
                            .opacity(visible ? 1 : 0)
                            .allowsHitTesting(visible && isActive)
                            .zIndex(visible ? 1 : 0)
                    }
                }
            }
        }
        .overlay(focusRing)
        .reportFrame(PaneFramesKey.self) { isActive ? [group.activeID: $0] : [:] }
    }

    /// 多个分栏时才需要提示「键盘打在哪一栏」。
    private var focusRing: some View {
        let visible = isActive && tab.paneCount > 1 && group.contains(tab.focusedSessionID)
        return Rectangle()
            .strokeBorder(ChromeStyle.focusRing, lineWidth: 2)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(false)
    }
}

// MARK: - 分栏标题栏

/// 分栏顶部那条标题栏：每个窗口一个小标签，只占自己名字的宽度；
/// 左侧的 `+` 在**本分栏**里再叠一个同主机的窗口，最右侧的 `…` 一次展开常用布局。
private struct PaneHeaderBar: View {

    @EnvironmentObject private var appState: AppState

    let group: PaneGroup
    let tab: TerminalTab
    let isActive: Bool

    /// 各标签的矩形，供拖拽落点判定用（子视图上报，本视图汇总后再往上报）。
    @State private var chips: [DragController.Chip] = []
    /// `Menu` 拿不到自定义按钮样式里的悬停状态，只能在外面自己记。
    @State private var isLayoutMenuHovering = false

    /// 这条栏的高度，同时也是那个 `+` 方块的边长。比 tab 条略矮 ——
    /// 它是分栏内部的东西，压满和 tab 条一样高会跟 tab 抢层级。
    fileprivate static let height: CGFloat = 30

    var body: some View {
        HStack(spacing: 2) {
            ForEach(group.sessionIDs, id: \.self) { sessionID in
                if let session = appState.session(id: sessionID) {
                    PaneChip(
                        session: session,
                        name: tab.windowName(of: sessionID),
                        isShown: sessionID == group.activeID,
                        isFocused: isActive && tab.focusedSessionID == sessionID
                    )
                    .reportFrame(ChipFramesKey.self) { [DragController.Chip(sessionID: sessionID, rect: $0)] }
                }
            }

            // 命中范围撑成一整块正方形（边长 = 这条栏的高度），悬停时整块亮一下。
            ChromeIconButton(
                systemName: "plus",
                side: Self.height,
                iconSize: 8
            ) {
                appState.addWindow(toPaneOf: group.activeID)
            }
            .help("在这个分栏新建窗口（\(tab.title)）")

            Spacer(minLength: 0)

            Menu {
                Button("左右排列", systemImage: "rectangle.split.2x1") {
                    appState.arrangeWindows(inPaneOf: group.activeID, axis: .horizontal)
                }
                .disabled(group.sessionIDs.count < 2)

                Button("上下排列", systemImage: "rectangle.split.1x2") {
                    appState.arrangeWindows(inPaneOf: group.activeID, axis: .vertical)
                }
                .disabled(group.sessionIDs.count < 2)

                Divider()

                Button("左右分栏", systemImage: "rectangle.split.2x1") {
                    appState.split(from: group.activeID, preset: .sideBySide)
                }
                Button("上下分栏", systemImage: "rectangle.split.1x2") {
                    appState.split(from: group.activeID, preset: .stacked)
                }
                Button("四宫格分栏", systemImage: "square.grid.2x2") {
                    appState.split(from: group.activeID, preset: .grid)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 9, weight: .bold))
                    .chromeIconCell(side: Self.height, hovering: isLayoutMenuHovering)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: Self.height, height: Self.height)
            .onHover { isLayoutMenuHovering = $0 }
            .help("分栏布局")
        }
        .padding(.horizontal, 3)
        .frame(height: Self.height)
        .background(ChromeStyle.paneHeader)
        .onPreferenceChange(ChipFramesKey.self) { frames in
            chips = frames.sorted { $0.rect.minX < $1.rect.minX }
        }
        .reportFrame(PaneHeadersKey.self) { rect in
            isActive
                ? [DragController.PaneHeader(
                    anchor: group.activeID,
                    rect: rect,
                    chips: chips,
                    sessionCount: group.sessionIDs.count
                )]
                : []
        }
    }
}

/// 一个小标签 = 一个窗口。
private struct PaneChip: View {

    @EnvironmentObject private var appState: AppState

    let session: SSHSession
    /// 窗口名：默认「窗口1」「窗口2」…，改过名就是改过的那个。主机名在 tab 上，这里不重复。
    let name: String
    /// 是不是这个分栏当前显示的那个。
    let isShown: Bool
    let isFocused: Bool

    @State private var isHovering = false

    /// 小标签的高度。字号和 tab 一样，但比 tab 矮一档。
    fileprivate static let height: CGFloat = 26
    /// 右端关闭方块的边长（命中范围）。取得比标签矮一点：
    /// 铺满整个高度的话，图标周围那圈余量就成了名字和 ✕ 之间一道明显的空隙。
    private static let closeSide: CGFloat = 22
    /// 圆角。底和那圈绿边共用，改名输入框也跟着它。
    fileprivate static let cornerRadius: CGFloat = 4
    /// 窗口名的字号，和 tab 标题一样大。
    fileprivate static let fontSize: CGFloat = 12

    private var isRenaming: Bool { appState.sessionBeingRenamed == session.id }

    /// 关闭按钮什么时候露出来：鼠标在这个小标签上，或者它就是本分栏当前显示的那个。
    private var isCloseVisible: Bool { isHovering || isShown }

    var body: some View {
        // 重命名时整个标签换成输入框：留着原来的点击与拖拽手势会把输入打断。
        if isRenaming {
            PaneNameField(
                initialName: name,
                onCommit: { appState.rename(sessionID: session.id, to: $0) },
                onCancel: { appState.cancelRenaming(sessionID: session.id) }
            )
        } else {
            chip
        }
    }

    private var chip: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(session.state.indicatorColor)
                .frame(width: 6, height: 6)

            // 宽度跟着名字走：给 Text 套 maxWidth 会让它把剩余空间全占掉，
            // 短名字左右就多出一大片空白。长度上限交给模型层（`TerminalTab.maximumNameLength`）。
            Text(name)
                .font(.system(size: PaneChip.fontSize))
                .lineLimit(1)
                .truncationMode(.middle)

            // 一直占着位置，只改透明度 —— 否则鼠标一进来标签就变宽。
            // 命中范围是小标签右端一整块正方形；看不见时不接点击，别误关窗口。
            ChromeIconButton(
                systemName: "xmark",
                side: Self.closeSide,
                iconSize: 7
            ) {
                appState.closeSession(sessionID: session.id)
            }
            .opacity(isCloseVisible ? 1 : 0)
            .allowsHitTesting(isCloseVisible)
            .help("关闭（⌘W）")
        }
        // 当前显示的那个标签：黑底 + 一圈绿边 + 绿字，和它下面那块终端读作一件事。
        // 名字和 ✕ 一起变绿（状态圆点有自己的颜色，不受影响）。
        .foregroundStyle(isShown ? ChromeStyle.paneChipText(emphasized: isFocused) : Color.primary)
        .padding(.leading, 5)
        .frame(height: Self.height)
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .fill(background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(ChromeStyle.paneChipBorder(emphasized: isFocused), lineWidth: 1)
                .opacity(isShown ? 1 : 0)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // 双击改名。放在单击之前，SwiftUI 才会优先按双击识别。
        .onTapGesture(count: 2) { appState.beginRenaming(sessionID: session.id) }
        .onTapGesture(perform: select)
        .onMiddleClick { appState.closeSession(sessionID: session.id) }
        .paneDrag(
            appState.drag,
            payload: .pane(sessionID: session.id),
            title: name
        ) {
            appState.completeDrag()
        }
        .help("\(session.config.endpointDescription) — \(session.state.label)（双击改名，中键关闭，拖动可在本标签页内重新布局）")
        .contextMenu {
            Button("重命名…") { appState.beginRenaming(sessionID: session.id) }
            Button("重新连接") { session.reconnect() }
            Divider()
            Button("关闭") { appState.closeSession(sessionID: session.id) }
        }
    }

    private var background: Color {
        if isShown { return ChromeStyle.paneChipBackground }
        return isHovering ? ChromeStyle.hover : .clear
    }

    private func select() {
        appState.activate(sessionID: session.id)
        session.takeKeyboardFocus()
    }
}

// MARK: - 改名输入框

/// 就地改名：占着小标签的位置，回车或点别处提交，Esc 放弃，清空则恢复「窗口N」。
private struct PaneNameField: View {

    let initialName: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var draft = ""
    /// 提交与放弃都只能发生一次：Esc 之后输入框会失焦，别再把草稿又提交一遍。
    @State private var isSettled = false
    @FocusState private var isFocused: Bool

    /// 字号，和小标签上的名字保持一致 —— 宽度是按这个字号量出来的，两边不一致就会跳一下。
    private static let fontSize: CGFloat = PaneChip.fontSize

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: Self.fontSize))
            .focused($isFocused)
            // 宽度按当前内容量出来，只多留一个光标的位置 —— 固定宽度的方框在短名字上空得难看。
            .frame(width: fieldWidth, height: PaneChip.height)
            .padding(.horizontal, 5)
            .background(
                RoundedRectangle(cornerRadius: PaneChip.cornerRadius)
                    .fill(Color.black.opacity(0.45))
            )
            // 边框跟着小标签走那圈绿：它占的就是小标签的位置，蓝边在这儿会突兀。
            // 字保持默认的白 —— 正在编辑和已经定下来的名字得看得出区别。
            .overlay(
                RoundedRectangle(cornerRadius: PaneChip.cornerRadius)
                    .strokeBorder(ChromeStyle.paneChipBorder(emphasized: true), lineWidth: 1)
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
            .help("回车确认，Esc 取消；清空则恢复默认名字")
    }

    private func settle(_ body: () -> Void) {
        guard !isSettled else { return }
        isSettled = true
        body()
    }

    /// 用 AppKit 量一下当前草稿的宽度：SwiftUI 里没有比这更省事的「按内容定宽」写法。
    private var fieldWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: Self.fontSize)
        let measured = (draft as NSString).size(withAttributes: [.font: font]).width
        // +7 是光标的位置；名字很长时不再跟着长，输入框内部自己滚动。
        return min(max(measured + 7, 26), 150)
    }
}
