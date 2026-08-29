import SwiftUI

/// 左侧竖栏上的功能。以后加端口转发之类的，在这里补一个 case
/// （外加 `HostSidebarView` 那样的面板视图）就行，竖栏本身不用改。
///
/// `rawValue` 会写进 UserDefaults（记住上次展开的是哪个），所以**不要改已有的字符串**。
enum SidebarPanel: String, CaseIterable, Identifiable {

    case hosts
    case files
    case monitor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hosts: return "主机"
        case .files: return "文件"
        case .monitor: return "监控"
        }
    }

    var icon: String {
        switch self {
        case .hosts: return "server.rack"
        case .files: return "folder"
        case .monitor: return "waveform.path.ecg"
        }
    }

    var help: String {
        switch self {
        case .hosts: return "管理主机（⌘B 开关）"
        case .files: return "浏览当前主机的文件（⇧⌘B 开关）"
        case .monitor: return "查看当前主机的资源占用（⌥⌘B 开关）"
        }
    }
}

/// 最左边那条常驻竖栏：一列图标，点一下在右边展开对应面板，再点收起。
///
/// 它和展开的面板都占**布局空间**（不是浮层），所以展开时终端区会被挤窄 —— 终端跟着 reflow。
struct ActivityBarView: View {

    @EnvironmentObject private var appState: AppState

    /// 竖栏宽度。够放一个 30 点高的图标行，再窄就点不准了。
    static let width: CGFloat = 40

    var body: some View {
        VStack(spacing: 2) {
            ForEach(SidebarPanel.allCases) { panel in
                ActivityBarButton(
                    panel: panel,
                    isActive: appState.activeSidebar == panel
                ) {
                    appState.toggleSidebar(panel)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(ChromeStyle.activityBar)
    }
}

/// 竖栏上的一个图标。
private struct ActivityBarButton: View {

    let panel: SidebarPanel
    let isActive: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: panel.icon)
                .font(.system(size: 15))
                .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.6))
                .frame(width: ActivityBarView.width, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(fill)
                        // 底色比图标行窄一点，免得糊到竖栏两边。
                        .padding(.horizontal, 5)
                )
                // 展开时最左边一条竖亮条：只换底色在这么窄的竖栏上不好认。
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(ChromeStyle.focusRing)
                        .frame(width: 2)
                        .opacity(isActive ? 1 : 0)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(panel.help)
    }

    private var fill: Color {
        if isActive { return ChromeStyle.selected(emphasized: false) }
        return isHovering ? ChromeStyle.hover : .clear
    }
}
