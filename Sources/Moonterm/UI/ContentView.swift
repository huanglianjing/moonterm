import SwiftUI

struct ContentView: View {

    @EnvironmentObject private var appState: AppState

    /// 主窗口的删除确认弹窗。挂在这一层才盖得住 tab 条和终端；侧栏、文件面板都只是发起方。
    @StateObject private var confirmations = ConfirmationCenter()

    var body: some View {
        // 左边两条竖的（常驻竖栏 + 展开的面板）都占布局空间，展开时终端区被挤窄。
        HStack(spacing: 0) {
            ActivityBarView()
            ChromeVerticalHairline()

            sidebar

            VStack(spacing: 0) {
                TabBarView()
                ChromeHairline()
                terminalArea
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        // 拖拽提示要能盖住 tab 条和终端区，所以叠在最外层。
        .overlay(DropIndicatorOverlay())
        .environmentObject(confirmations)
        // 确认弹窗压在最上面（连拖拽提示也压住），弹着的时候底下什么都点不到。
        .destructiveConfirmations(confirmations)
        .navigationTitle(appState.windowTitle)
        .sheet(isPresented: $appState.isHostManagerPresented) {
            HostManagerView()
                .environmentObject(appState)
        }
        // 新建/编辑主机是从侧栏发起的，所以挂在最外层，不跟着终端区走。
        .sheet(item: $appState.hostBeingEdited) { host in
            HostEditorView(host: host)
                .environmentObject(appState)
        }
    }

    /// 竖栏展开的那块面板，外加右边缘那条可拖的把手。
    @ViewBuilder
    private var sidebar: some View {
        if let panel = appState.activeSidebar {
            Group {
                switch panel {
                case .hosts:
                    HostSidebarView()
                case .files:
                    FileSidebarView()
                case .monitor:
                    MonitorSidebarView()
                }
            }
            .frame(width: appState.sidebarWidth)

            SidebarResizeHandle()
        }
    }

    private var terminalArea: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)

            if appState.tabs.isEmpty {
                EmptyStateView()
            }

            // 所有 tab 的分栏树**都留在层级里**，只用透明度决定谁可见。
            // 用 if/else 切换会销毁 NSView，从而杀掉 PTY —— 那样切 tab 就断线了。
            ForEach(appState.tabs) { tab in
                let isSelected = tab.id == appState.selectedTabID
                PaneTreeView(tab: tab, isActive: isSelected)
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(isSelected)
                    .zIndex(isSelected ? 1 : 0)
            }
        }
        // 可见 tab 的各分栏矩形与小标签条，拖拽落点判定要用。
        .onPreferenceChange(PaneFramesKey.self) { frames in
            appState.drag.paneFrames = frames
        }
        .onPreferenceChange(PaneHeadersKey.self) { headers in
            appState.drag.paneHeaders = headers
        }
        .onPreferenceChange(PaneDividersKey.self) { dividers in
            appState.drag.paneDividers = dividers
        }
        .onChange(of: appState.selectedTabID) { _ in
            focusTerminal()
        }
        .onChange(of: appState.selectedTab?.focusedSessionID) { _ in
            focusTerminal()
        }
        .onAppear {
            focusTerminal()
        }
    }

    /// 切 tab / 切分栏后把键盘焦点交给当前终端，否则输入会落到别处。
    private func focusTerminal() {
        guard let session = appState.focusedSession else { return }
        DispatchQueue.main.async {
            // 正在改分栏名字时别抢：焦点得留在那个输入框里。
            guard appState.sessionBeingRenamed == nil else { return }
            session.takeKeyboardFocus()
        }
    }
}

/// 没有任何 tab 时的占位提示。
///
/// 只是一句话 —— 主机列表在左侧竖栏的面板里，中间不再放第二份。
private struct EmptyStateView: View {

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)

            Text("Moonterm")
                .font(.title2)

            Text("在左边的主机列表里双击一台开始")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(32)
    }
}
