import MoontermCore
import SwiftUI

/// 顶部 tab 条。一项 = 一台主机的一个 tab（里面可能有多个分栏）。
/// 这里唯一的拖拽语义是**排序**：tab 之间不合并，也不能拖进别的 tab 的分栏里。
struct TabBarView: View {

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var drag: DragController

    var body: some View {
        // 只有 tab 本身。新建连接一律走左侧竖栏的主机面板（⌘T 会把它展开）。
        ScrollView(.horizontal, showsIndicators: false) {
            // 拖拽期间只做视觉平移：被拖的那个跟着指针走，其余的滑开让位，
            // 真正的顺序等松手才由 `completeDrag()` 改。
            let shifts = drag.tabShifts()

            HStack(spacing: 1) {
                ForEach(appState.tabs) { tab in
                    let isDragging = drag.isDragging(.tab(id: tab.id))

                    TabItemView(
                        tab: tab,
                        statusColor: SessionStatus.aggregateColor(of: appState.sessions(in: tab).map { $0.state }),
                        isSelected: tab.id == appState.selectedTabID,
                        isDragging: isDragging
                    )
                    .reportFrame(TabFramesKey.self) { [DragController.TabFrame(id: tab.id, rect: $0)] }
                    .offset(x: isDragging ? drag.draggedTabTranslation : (shifts[tab.id] ?? 0))
                    // 被拖的那个要一比一跟手，不能有动画拖后腿；让位的那些才需要滑得顺。
                    .animation(
                        drag.isDraggingTab && !isDragging ? .easeOut(duration: 0.16) : nil,
                        value: shifts[tab.id] ?? 0
                    )
                    .zIndex(isDragging ? 1 : 0)
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 32)
        .background(ChromeStyle.bar)
        .reportFrame(TabBarFrameKey.self) { $0 }
        // 拖拽落点判定要用的几何信息。
        .onPreferenceChange(TabFramesKey.self) { frames in
            drag.tabFrames = frames.sorted { $0.rect.minX < $1.rect.minX }
        }
        .onPreferenceChange(TabBarFrameKey.self) { frame in
            drag.tabBarFrame = frame
        }
    }
}

/// 单个 tab。
private struct TabItemView: View {

    @EnvironmentObject private var appState: AppState

    let tab: TerminalTab
    let statusColor: Color
    let isSelected: Bool
    let isDragging: Bool

    @State private var isHovering = false

    /// tab 的高度。
    private static let height: CGFloat = 26
    /// 右端关闭方块的边长（命中范围）。比 tab 略矮，见 body 里那段注释。
    private static let closeSide: CGFloat = 20

    /// 关闭按钮什么时候露出来：鼠标在这个 tab 上，或者它就是当前 tab。
    private var isCloseVisible: Bool { isHovering || isSelected }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)

            Text(tab.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)

            // 里面装了不止一个窗口就给个提示，标题始终是主机名。
            if tab.sessionCount > 1 {
                Image(systemName: tab.paneCount > 1 ? "rectangle.split.2x1" : "square.on.square")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .help("\(tab.sessionCount) 个窗口 · \(tab.paneCount) 个分栏")
            }

            // 命中范围是一整块正方形，但边长取得比 tab 矮一点：铺满 26 点的话，
            // 图标周围那圈余量就成了标题和 ✕ 之间一道明显的空隙。
            // 看不见的时候不接点击 —— 那块地方挺大，不能让人误关。
            ChromeIconButton(
                systemName: "xmark",
                side: Self.closeSide,
                iconSize: 8,
                cornerRadius: 5
            ) {
                appState.close(tabID: tab.id)
            }
            .opacity(isCloseVisible ? 1 : 0)
            .allowsHitTesting(isCloseVisible)
            .help("关闭标签页")
        }
        // 左边给圆点留一点空（和分栏小标签一致），右边靠关闭方块自带的余量收边。
        .padding(.leading, 5)
        .padding(.trailing, 2)
        .frame(height: Self.height)
        // 宽度跟着标题走，短主机名就是个短 tab —— 定了 `minWidth` 的话，多出来的宽度
        // 只会变成标题和 ✕ 之间的一片空白。长标题到 200 点截断。
        .frame(maxWidth: 200)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(background)
        )
        // 跟着指针走的是这个 tab 本身，所以别画得太淡；用一点阴影表示「被拎起来了」。
        .opacity(isDragging ? 0.92 : 1)
        .shadow(color: .black.opacity(isDragging ? 0.35 : 0), radius: 4, y: 1)
        .contentShape(Rectangle())
        .onTapGesture { appState.selectedTabID = tab.id }
        .onMiddleClick { appState.close(tabID: tab.id) }
        .onHover { isHovering = $0 }
        .paneDrag(
            appState.drag,
            payload: .tab(id: tab.id),
            title: tab.title
        ) {
            appState.completeDrag()
        }
        .help(helpText)
        .contextMenu {
            Button(tab.sessionCount > 1 ? "重新连接全部窗口" : "重新连接") {
                appState.sessions(in: tab).forEach { $0.reconnect() }
            }
            Divider()
            Button("关闭标签页") { appState.close(tabID: tab.id) }
            Button("关闭其他标签页") { appState.closeOtherTabs(keeping: tab.id) }
        }
    }

    private var helpText: String {
        let sessions = appState.sessions(in: tab)
        let endpoint = tab.host.endpointDescription
        if sessions.count == 1, let session = sessions.first {
            return "\(endpoint) — \(session.state.label)（拖动可重排，中键关闭）"
        }
        let windows = sessions
            .map { "\(tab.windowName(of: $0.id)) — \($0.state.label)" }
            .joined(separator: "\n")
        return "\(endpoint)\n\(windows)"
    }

    private var background: Color {
        if isSelected { return ChromeStyle.selected(emphasized: false) }
        return isHovering ? ChromeStyle.hover : .clear
    }
}
