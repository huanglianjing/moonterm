import MoontermCore
import SwiftUI

/// tab 条上 `+` 号的弹出层：选一台已保存的主机开新 tab。
///
/// 只有「新建 tab」会走到这里 —— tab 内部分栏一律沿用该 tab 绑定的主机，不再选。
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
                        open(host)
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
                dismiss()
                appState.beginCreatingHost()
            }
            .buttonStyle(.plain)

            Button("管理主机…") {
                dismiss()
                appState.isHostManagerPresented = true
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 260)
    }

    private func open(_ host: HostConfig) {
        dismiss()
        appState.open(host: host)
    }

    private func dismiss() {
        appState.isHostPickerPresented = false
    }
}
