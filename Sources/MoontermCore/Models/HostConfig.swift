import Foundation

/// 一台被保存下来的 SSH 主机配置。
///
/// 注意：这里**不含密码**。密码由 `SecretStore` 单独保管（见 `PlaintextFileSecretStore`），
/// 这样将来换成钥匙串只需替换 `SecretStore` 的实现，配置文件格式不受影响。
public struct HostConfig: Identifiable, Codable, Hashable {
    public var id: UUID
    /// 显示名。为空时用 `user@host` 兜底。
    public var name: String
    /// ip 或域名。
    public var host: String
    public var port: Int
    public var username: String
    /// 首次连接自动接受服务端主机密钥（`StrictHostKeyChecking=accept-new`）。
    /// 关掉则用 `ask`，需要在终端里手动回答 yes/no。
    public var acceptNewHostKey: Bool

    public init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "",
        port: Int = 22,
        username: String = "",
        acceptNewHostKey: Bool = true
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.acceptNewHostKey = acceptNewHostKey
    }

    /// tab 与列表里展示的名字。
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        if username.isEmpty { return host }
        return "\(username)@\(host)"
    }

    /// 供人阅读的连接串，例如 `root@10.0.0.1:2222`。
    public var endpointDescription: String {
        let base = username.isEmpty ? host : "\(username)@\(host)"
        return port == 22 ? base : "\(base):\(port)"
    }

    // MARK: - 校验

    public enum ValidationError: LocalizedError, Equatable {
        case emptyHost
        case emptyUsername
        case invalidPort(Int)
        /// 以 `-` 开头的主机名会被 ssh 当成选项解析。
        case hostLooksLikeOption(String)

        public var errorDescription: String? {
            switch self {
            case .emptyHost:
                return "请填写主机地址"
            case .emptyUsername:
                return "请填写用户名"
            case .invalidPort(let port):
                return "端口 \(port) 无效，应在 1–65535 之间"
            case .hostLooksLikeOption(let host):
                return "主机地址不能以 - 开头：\(host)"
            }
        }
    }

    public func validate() throws {
        let host = self.host.trimmingCharacters(in: .whitespaces)
        if host.isEmpty { throw ValidationError.emptyHost }
        if host.hasPrefix("-") { throw ValidationError.hostLooksLikeOption(host) }
        if username.trimmingCharacters(in: .whitespaces).isEmpty { throw ValidationError.emptyUsername }
        if !(1...65535).contains(port) { throw ValidationError.invalidPort(port) }
    }

    /// 保存前把用户输入里的空白清掉。
    public func normalized() -> HostConfig {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespaces)
        copy.host = host.trimmingCharacters(in: .whitespaces)
        copy.username = username.trimmingCharacters(in: .whitespaces)
        return copy
    }

    // MARK: - Codable
    //
    // 手写 decode，缺字段时退回默认值，避免旧版本或手改过的 hosts.json 直接读不出来。

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, acceptNewHostKey
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        self.port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        self.username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        self.acceptNewHostKey = try c.decodeIfPresent(Bool.self, forKey: .acceptNewHostKey) ?? true
    }
}
