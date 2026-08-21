import Foundation

/// 密码存取的抽象。
///
/// 当前实现 `PlaintextFileSecretStore` 把密码**明文**存在
/// `~/Library/Application Support/Moonterm/secrets.json`（权限 0600）。
/// 换成钥匙串只需新写一个符合本协议的类型，然后在 `ConfigStore` 初始化时替换掉，
/// 其余代码（UI、会话、命令行构造）都不用改。
public protocol SecretStore: AnyObject {
    /// 取不到时返回空串，调用方用 `isEmpty` 判断「没配密码」。
    func password(for hostID: UUID) -> String
    func setPassword(_ password: String, for hostID: UUID)
    func removePassword(for hostID: UUID)
}

/// 明文 JSON 实现。
///
/// 安全性说明：文件权限是 0600，同机器上的其他用户读不到，但**本用户的任何进程都能读**，
/// 且不受钥匙串保护。这是产品上的显式选择，README 里有对应说明。
public final class PlaintextFileSecretStore: SecretStore {

    private let fileURL: URL
    /// hostID.uuidString -> 明文密码
    private var secrets: [String: String] = [:]

    public init(directory: URL = MoontermPaths.applicationSupport) {
        self.fileURL = directory.appendingPathComponent("secrets.json")
        load()
    }

    public func password(for hostID: UUID) -> String {
        secrets[hostID.uuidString] ?? ""
    }

    public func setPassword(_ password: String, for hostID: UUID) {
        if password.isEmpty {
            secrets.removeValue(forKey: hostID.uuidString)
        } else {
            secrets[hostID.uuidString] = password
        }
        save()
    }

    public func removePassword(for hostID: UUID) {
        secrets.removeValue(forKey: hostID.uuidString)
        save()
    }

    // MARK: - 持久化

    private func load() {
        guard let data = SecureFile.read(fileURL) else { return }
        secrets = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try SecureFile.writeAtomically(try encoder.encode(secrets), to: fileURL)
        } catch {
            NSLog("Moonterm: 保存密码失败 %@", String(describing: error))
        }
    }
}
