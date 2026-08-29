import MoontermCore
import SwiftUI

/// 主机管理面板（⌘,）：增删改、复制、连接。
///
/// 编辑用的是本视图自己的 `@State`（嵌套 sheet），不复用 `AppState.hostBeingEdited` ——
/// 那个 binding 挂在被本面板遮住的视图上，从这里触发不会弹出来。
struct HostManagerView: View {

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    /// 这张 sheet 是独立窗口，主窗口那层确认弹窗盖不到它，所以自己再持一份。
    @StateObject private var confirmations = ConfirmationCenter()

    @State private var selection: UUID?
    @State private var hostBeingEdited: HostConfig?

    private var hosts: [HostConfig] { appState.configStore.hosts }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("主机")
                    .font(.headline)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)

            Divider()

            if hosts.isEmpty {
                VStack(spacing: 12) {
                    Text("还没有保存任何主机")
                        .foregroundStyle(.secondary)
                    Button("新建主机…") { hostBeingEdited = HostConfig() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(hosts) { host in
                        row(for: host)
                            .tag(host.id)
                    }
                    .onMove { source, destination in
                        appState.configStore.move(fromOffsets: source, toOffset: destination)
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            toolbar
        }
        .frame(width: 540, height: 420)
        .destructiveConfirmations(confirmations)
        .sheet(item: $hostBeingEdited) { host in
            HostEditorView(host: host)
                .environmentObject(appState)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                hostBeingEdited = HostConfig()
            } label: {
                Image(systemName: "plus")
            }
            .help("新建主机")

            Button {
                requestDeletion(of: selectedHost)
            } label: {
                Image(systemName: "minus")
            }
            .disabled(selectedHost == nil)
            .help("删除主机")

            Button("编辑") {
                hostBeingEdited = selectedHost
            }
            .disabled(selectedHost == nil)

            Button("复制") {
                if let host = selectedHost {
                    appState.configStore.duplicate(id: host.id)
                }
            }
            .disabled(selectedHost == nil)

            Spacer()

            Button("连接") {
                connect(selectedHost)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedHost == nil)
        }
        .padding(12)
    }

    private var selectedHost: HostConfig? {
        guard let selection else { return nil }
        return hosts.first { $0.id == selection }
    }

    private func connect(_ host: HostConfig?) {
        guard let host else { return }
        appState.open(host: host)
        dismiss()
    }

    private func requestDeletion(of host: HostConfig?) {
        guard let host else { return }

        confirmations.ask(
            title: "删除「\(host.displayName)」？",
            confirmTitle: "删除"
        ) {
            appState.configStore.remove(id: host.id)
            if selection == host.id { selection = nil }
        }
    }

    private func row(for host: HostConfig) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName)
                Text(host.endpointDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // 这个面板是一份平铺的表，所以把所属分组标出来，免得和侧栏里的分段对不上号。
            if let groupID = host.groupID, let group = appState.configStore.group(id: groupID) {
                Text(group.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            if appState.configStore.password(for: host).isEmpty {
                Text("未存密码")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { connect(host) }
        .contextMenu {
            Button("连接") { connect(host) }
            Button("编辑…") { hostBeingEdited = host }
            Button("复制") { appState.configStore.duplicate(id: host.id) }
            Divider()
            Button("删除…") { requestDeletion(of: host) }
        }
    }
}
