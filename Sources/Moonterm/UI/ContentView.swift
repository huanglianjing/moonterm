import SwiftUI

struct ContentView: View {

    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            TabBarView()
            ChromeHairline()
            terminalArea
        }
        .frame(minWidth: 760, minHeight: 460)
        // 拖拽提示要能盖住 tab 条和终端区，所以叠在最外层。
        .overlay(DropIndicatorOverlay())
        .navigationTitle(appState.windowTitle)
        .sheet(isPresented: $appState.isHostManagerPresented) {
            HostManagerView()
                .environmentObject(appState)
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
        .sheet(item: $appState.hostBeingEdited) { host in
            HostEditorView(host: host)
                .environmentObject(appState)
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
            session.takeKeyboardFocus()
        }
    }
}

/// 没有任何 tab 时的界面：直接把已保存的主机列出来，点一下就连。
private struct EmptyStateView: View {

    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)

            Text("Moonterm")
                .font(.title2)

            if appState.configStore.hosts.isEmpty {
                Text("还没有保存任何主机")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(appState.configStore.hosts) { host in
                        Button {
                            appState.open(host: host)
                        } label: {
                            HStack {
                                Text(host.displayName)
                                Spacer()
                                Text(host.endpointDescription)
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 11))
                            }
                            .padding(.vertical, 5)
                            .padding(.horizontal, 10)
                            .frame(width: 380, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.primary.opacity(0.06))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxHeight: 240)
            }

            HStack(spacing: 10) {
                Button("新建主机…") { appState.beginCreatingHost() }
                Button("管理主机…") { appState.isHostManagerPresented = true }
            }
        }
        .padding(32)
    }
}
