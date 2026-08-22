import MoontermCore
import SwiftUI

/// 顶部 tab 条。一项 = 一台主机的一个 tab（里面可能有多个分栏）。
/// 这里唯一的拖拽语义是**排序**：tab 之间不合并，也不能拖进别的 tab 的分栏里。
struct TabBarView: View {

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var drag: DragController

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(appState.tabs) { tab in
                        TabItemView(
                            tab: tab,
                            statusColor: SessionStatus.aggregateColor(of: appState.sessions(in: tab).map { $0.state }),
                            isSelected: tab.id == appState.selectedTabID,
                            isDragging: drag.isDragging(.tab(id: tab.id))
                        )
                        .reportFrame(TabFramesKey.self) { [DragController.TabFrame(id: tab.id, rect: $0)] }
                    }
                }
                .padding(.horizontal, 4)
            }

            Rectangle()
                .fill(ChromeStyle.hairline)
                .frame(width: 1, height: 22)

            Button {
                appState.isHostPickerPresented = true
            } label: {
                Image(systemName: "plus")
                    .frame(width: 28, height: 26)
            }
            .buttonStyle(.plain)
            .help("新建连接（⌘T）")
            .popover(isPresented: $appState.isHostPickerPresented, arrowEdge: .bottom) {
                HostPickerView()
                    .environmentObject(appState)
            }
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
        .opacity(isDragging ? 0.4 : 1)
        .contentShape(Rectangle())
        .onTapGesture { appState.selectedTabID = tab.id }
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
            return "\(endpoint) — \(session.state.label)（拖动可重排）"
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
