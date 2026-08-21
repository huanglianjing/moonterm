import SwiftUI

/// 顶部 tab 条。
struct TabBarView: View {

    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(appState.sessions) { session in
                        TabItemView(
                            session: session,
                            isSelected: session.id == appState.selectedSessionID,
                            onSelect: { appState.selectedSessionID = session.id },
                            onClose: { appState.close(sessionID: session.id) },
                            onReconnect: { session.reconnect() },
                            onCloseOthers: { appState.closeOthers(keeping: session.id) }
                        )
                    }
                }
                .padding(.horizontal, 4)
            }

            Divider()
                .frame(height: 22)

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
        .background(.bar)
    }
}

/// 单个 tab。
private struct TabItemView: View {

    @ObservedObject var session: SSHSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onReconnect: () -> Void
    let onCloseOthers: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)

            Text(session.tabTitle)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isSelected ? 1 : 0)
            .help("关闭标签页（⌘W）")
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .frame(minWidth: 110, maxWidth: 200)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(background)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .help("\(session.config.endpointDescription) — \(session.state.label)")
        .contextMenu {
            Button("重新连接", action: onReconnect)
            Divider()
            Button("关闭标签页", action: onClose)
            Button("关闭其他标签页", action: onCloseOthers)
        }
    }

    private var background: Color {
        if isSelected { return Color(nsColor: .controlAccentColor).opacity(0.18) }
        return isHovering ? Color.primary.opacity(0.06) : .clear
    }

    private var statusColor: Color {
        switch session.state {
        case .connecting: return .orange
        case .connected: return .green
        case .disconnected: return .secondary
        case .failed: return .red
        }
    }
}
