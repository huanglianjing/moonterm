import SwiftUI

struct ContentView: View {

    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            TabBarView()
            Divider()
            terminalArea
        }
        .frame(minWidth: 760, minHeight: 460)
        .navigationTitle(appState.windowTitle)
        .sheet(isPresented: $appState.isHostManagerPresented) {
            HostManagerView()
                .environmentObject(appState)
        }
    }

    private var terminalArea: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)

            if appState.sessions.isEmpty {
                EmptyStateView()
            }

            // 所有会话的终端视图**都留在层级里**，只用透明度决定谁可见。
            // 用 if/else 切换会销毁 NSView，从而杀掉 PTY —— 那样切 tab 就断线了。
            ForEach(appState.sessions) { session in
                let isSelected = session.id == appState.selectedSessionID
                TerminalContainer(session: session)
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(isSelected)
                    .zIndex(isSelected ? 1 : 0)
            }
        }
        .sheet(item: $appState.hostBeingEdited) { host in
            HostEditorView(host: host)
                .environmentObject(appState)
        }
        .onChange(of: appState.selectedSessionID) { _ in
            focusSelectedTerminal()
        }
        .onAppear {
            focusSelectedTerminal()
        }
    }

    /// 切 tab 后把键盘焦点交给当前终端，否则输入会落到别处。
    private func focusSelectedTerminal() {
        guard let view = appState.selectedSession?.terminalView else { return }
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
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
