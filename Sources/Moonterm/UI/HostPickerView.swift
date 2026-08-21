import SwiftUI

/// tab 条上 `+` 号的弹出层：选一台已保存的主机开新 tab。
struct HostPickerView: View {

    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if appState.configStore.hosts.isEmpty {
                Text("还没有保存任何主机")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(appState.configStore.hosts) { host in
                    Button {
                        appState.isHostPickerPresented = false
                        appState.open(host: host)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(host.displayName)
                                Text(host.endpointDescription)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            Button("新建主机…") {
                appState.isHostPickerPresented = false
                appState.beginCreatingHost()
            }
            .buttonStyle(.plain)

            Button("管理主机…") {
                appState.isHostPickerPresented = false
                appState.isHostManagerPresented = true
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 260)
    }
}
