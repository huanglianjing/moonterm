import MoontermCore
import SwiftUI

/// 新建 / 编辑一台主机。
struct HostEditorView: View {

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var draft: HostConfig
    @State private var portText: String
    @State private var password: String
    @State private var errorMessage: String?
    /// 编辑已存在的主机时，保存后直接连接的按钮才有意义。
    private let isExisting: Bool

    init(host: HostConfig) {
        _draft = State(initialValue: host)
        _portText = State(initialValue: String(host.port))
        _password = State(initialValue: "")
        self.isExisting = !host.host.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isExisting ? "编辑主机" : "新建主机")
                .font(.headline)
                .padding(12)

            Divider()

            Form {
                TextField("名称", text: $draft.name, prompt: Text("可留空，默认用 用户名@地址"))
                TextField("地址", text: $draft.host, prompt: Text("10.0.0.1 或 example.com"))
                TextField("端口", text: $portText, prompt: Text("22"))
                TextField("用户名", text: $draft.username, prompt: Text("root"))
                SecureField("密码", text: $password, prompt: Text("留空则用密钥 / 手动输入"))

                // 分组可以不选。一个分组都还没建时这一项没有意义，直接不显示。
                if !appState.configStore.groups.isEmpty {
                    Picker("分组", selection: $draft.groupID) {
                        Text("不分组").tag(UUID?.none)
                        Divider()
                        ForEach(appState.configStore.groups) { group in
                            Text(group.displayName).tag(Optional(group.id))
                        }
                    }
                }

                Toggle("首次连接自动信任主机密钥", isOn: $draft.acceptNewHostKey)
            }
            .formStyle(.grouped)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }

            Divider()

            HStack {
                Text("密码以明文保存在 ~/Library/Application Support/Moonterm/secrets.json")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save(thenConnect: false) }
                    .keyboardShortcut(.defaultAction)
                Button("保存并连接") { save(thenConnect: true) }
            }
            .padding(12)
        }
        .frame(width: 520)
        .onAppear {
            // 已存在的主机把已保存的密码填回来，方便修改。
            password = appState.configStore.password(for: draft)
        }
    }

    private func save(thenConnect: Bool) {
        guard let port = Int(portText.trimmingCharacters(in: .whitespaces)) else {
            errorMessage = "端口必须是数字"
            return
        }

        var candidate = draft.normalized()
        candidate.port = port

        do {
            try candidate.validate()
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        appState.configStore.save(candidate, password: password)
        dismiss()

        if thenConnect {
            appState.open(host: candidate)
        }
    }
}
