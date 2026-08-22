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

    var body: some View {
        HStack(spacing: 6) {
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

            Button {
                appState.close(tabID: tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isSelected ? 1 : 0)
            .help("关闭标签页")
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .frame(minWidth: 110, maxWidth: 200)
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
