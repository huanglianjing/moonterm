import Combine
import Foundation

/// 主机配置的内存副本 + 持久化。任何修改都会立刻落盘。
///
/// 密码不在这里，走 `secrets`（`SecretStore`）。
public final class ConfigStore: ObservableObject {

    /// 文件格式带版本号，将来改结构时好做迁移。
    private struct Document: Codable {
        var version: Int
        var hosts: [HostConfig]
    }

    private static let currentVersion = 1

    @Published public private(set) var hosts: [HostConfig] = []

    public let secrets: SecretStore

    private let fileURL: URL

    public init(
        fileURL: URL = MoontermPaths.hostsFile,
        secrets: SecretStore = PlaintextFileSecretStore()
    ) {
        self.fileURL = fileURL
        self.secrets = secrets
        load()
    }

    // MARK: - 查询

    public func host(id: UUID) -> HostConfig? {
        hosts.first { $0.id == id }
    }

    public func password(for host: HostConfig) -> String {
        secrets.password(for: host.id)
    }

    // MARK: - 修改

    /// 新增或按 id 覆盖，并保存密码。密码传空串表示不用密码（走 ssh 默认认证方式）。
    public func save(_ host: HostConfig, password: String) {
        let normalized = host.normalized()
        if let index = hosts.firstIndex(where: { $0.id == normalized.id }) {
            hosts[index] = normalized
        } else {
            hosts.append(normalized)
        }
        secrets.setPassword(password, for: normalized.id)
        persist()
    }

    public func remove(id: UUID) {
        hosts.removeAll { $0.id == id }
        secrets.removePassword(for: id)
        persist()
    }

    /// 复制一份配置（含密码），名字加「副本」后缀。
    @discardableResult
    public func duplicate(id: UUID) -> HostConfig? {
        guard let original = host(id: id) else { return nil }
        var copy = original
        copy.id = UUID()
        copy.name = "\(original.displayName) 副本"
        save(copy, password: secrets.password(for: original.id))
        return copy
    }

    /// 拖动排序。语义与 SwiftUI 的 `move(fromOffsets:toOffset:)` 一致：
    /// `destination` 是**原数组**中的插入位置。
    ///
    /// 没有直接用那个方法，因为它是 SwiftUI 给集合加的扩展，而本模块不依赖 SwiftUI。
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.compactMap { hosts.indices.contains($0) ? hosts[$0] : nil }
        guard !moving.isEmpty else { return }

        var remaining = hosts
        for index in source.sorted(by: >) where remaining.indices.contains(index) {
            remaining.remove(at: index)
        }

        // 被移走的元素里，位于插入点之前的那些会让插入位置左移。
        let insertionIndex = destination - source.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: min(max(insertionIndex, 0), remaining.count))

        hosts = remaining
        persist()
    }

    // MARK: - 持久化

    private func load() {
        guard let data = SecureFile.read(fileURL) else { return }
        do {
            hosts = try JSONDecoder().decode(Document.self, from: data).hosts
        } catch {
            NSLog("Moonterm: 读取 %@ 失败：%@", fileURL.path, String(describing: error))
        }
    }

    private func persist() {
        let document = Document(version: Self.currentVersion, hosts: hosts)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try SecureFile.writeAtomically(try encoder.encode(document), to: fileURL)
        } catch {
            NSLog("Moonterm: 写入 %@ 失败：%@", fileURL.path, String(describing: error))
        }
    }
}
