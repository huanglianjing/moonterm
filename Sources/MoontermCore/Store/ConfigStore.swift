import Combine
import Foundation

/// 主机配置的内存副本 + 持久化。任何修改都会立刻落盘。
///
/// 密码不在这里，走 `secrets`（`SecretStore`）。
///
/// **顺序只有一份**：`hosts` 的数组顺序。分组只是把这份顺序切成几段展示（见 `sections`），
/// 所以「排到某个分组末尾」等价于「排到数组末尾」—— 显示时按分组过滤，
/// 数组里排在同组所有人后面就是组内最后一个。
public final class ConfigStore: ObservableObject {

    /// 文件格式带版本号，将来改结构时好做迁移。
    private struct Document: Codable {
        var version: Int
        var hosts: [HostConfig]
        /// v1 的文件里没有这个字段，解出来是 nil，等于「一个分组都没有」。
        var groups: [HostGroup]?
    }

    private static let currentVersion = 2

    @Published public private(set) var hosts: [HostConfig] = []
    /// 分组，数组顺序即显示顺序。
    @Published public private(set) var groups: [HostGroup] = []

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

    public func group(id: UUID) -> HostGroup? {
        groups.first { $0.id == id }
    }

    public func password(for host: HostConfig) -> String {
        secrets.password(for: host.id)
    }

    /// 某个分组里的主机，按显示顺序。`nil` = 未分组的那些。
    public func hosts(inGroup groupID: UUID?) -> [HostConfig] {
        hosts.filter { $0.groupID == groupID }
    }

    /// 列表从上到下的分段：各分组依次排开，未分组的垫在最后（`group == nil` 那段）。
    public var sections: [(group: HostGroup?, hosts: [HostConfig])] {
        groups.map { ($0, hosts(inGroup: $0.id)) } + [(nil, hosts(inGroup: nil))]
    }

    /// 列表里看到的主机顺序（折叠状态不算在内，那是界面的事）。
    public var displayOrderedHostIDs: [UUID] {
        sections.flatMap { $0.hosts.map { $0.id } }
    }

    /// 这几台主机**能移到**哪几段（右键「移到分组」要列的东西），未分组排在最后。
    ///
    /// - 一个分组都没建：空数组 —— 没有任何去处，菜单那边给一条灰着的说明。
    /// - 都在同一段里：那一段不算去处，移到自己已经在的地方没有意义。
    /// - 散落在不同段里：全都算去处，怎么归拢都说得通。
    public func moveDestinations(forHostIDs ids: [UUID]) -> [HostMoveDestination] {
        guard !groups.isEmpty else { return [] }

        let sections = Set(ids.compactMap { host(id: $0) }.map { $0.groupID })
        let shared: UUID? = sections.count == 1 ? sections.first ?? nil : nil
        // 都在未分组里，那「未分组」就不是去处了。
        let skipUngrouped = sections.count == 1 && shared == nil

        var result = groups.filter { $0.id != shared }.map { HostMoveDestination.group($0) }
        if !skipUngrouped {
            result.append(.ungrouped)
        }
        return result
    }

    // MARK: - 修改主机

    /// 新增或按 id 覆盖，并保存密码。密码传空串表示不用密码（走 ssh 默认认证方式）。
    ///
    /// 新建的一律排到最后 —— 也就是它所属分组的末尾（没选分组就是整个列表的最下面）。
    public func save(_ host: HostConfig, password: String) {
        var normalized = host.normalized()
        // 指向一个已经不存在的分组（比如编辑期间分组被删了）就当没分组，
        // 否则这台主机哪一段都进不去，等于凭空消失。
        if let groupID = normalized.groupID, group(id: groupID) == nil {
            normalized.groupID = nil
        }

        if let index = hosts.firstIndex(where: { $0.id == normalized.id }) {
            let changedGroup = hosts[index].groupID != normalized.groupID
            hosts[index] = normalized
            // 在编辑框里换了分组：排到新分组末尾。留在原下标会插在新同伴中间，看着像随机位置。
            if changedGroup {
                hosts.append(hosts.remove(at: index))
            }
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

    /// 复制一份配置（含密码、含所属分组），名字加「副本」后缀。
    ///
    /// 副本**紧挨着原主机**放，不是排到分组末尾 —— 复制出来的东西要能立刻看见。
    /// 数组里挨着就是显示上挨着（同一分组、就在它下一个），见类型注释里那句「顺序只有一份」。
    @discardableResult
    public func duplicate(id: UUID) -> HostConfig? {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return nil }
        let original = hosts[index]

        var copy = original
        copy.id = UUID()
        copy.name = "\(original.displayName) 副本"
        copy = copy.normalized()

        hosts.insert(copy, at: index + 1)
        secrets.setPassword(secrets.password(for: original.id), for: copy.id)
        persist()
        return copy
    }

    // MARK: - 分组

    @discardableResult
    public func addGroup(name: String = HostGroup.defaultName) -> HostGroup {
        let group = HostGroup(name: name).normalized()
        groups.append(group)
        persist()
        return group
    }

    /// 改名。空名字照存，显示时由 `HostGroup.displayName` 兜底。
    public func renameGroup(id: UUID, to name: String) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = name.trimmingCharacters(in: .whitespaces)
        persist()
    }

    public func setGroup(id: UUID, collapsed: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == id }), groups[index].isCollapsed != collapsed else { return }
        groups[index].isCollapsed = collapsed
        persist()
    }

    /// 删分组。**里面的主机一台都不删**，全部挪到「未分组」的末尾 ——
    /// 删收纳盒不该顺手把东西扔了，真想删主机有单独的删除菜单。
    public func removeGroup(id: UUID) {
        guard groups.contains(where: { $0.id == id }) else { return }
        groups.removeAll { $0.id == id }

        let orphans = hosts.filter { $0.groupID == id }.map { host -> HostConfig in
            var copy = host
            copy.groupID = nil
            return copy
        }
        hosts.removeAll { $0.groupID == id }
        hosts.append(contentsOf: orphans)
        persist()
    }

    /// 拖动分组排序。`before` 为 nil 表示排到最后一个分组之后。
    public func moveGroup(id: UUID, before anchorID: UUID?) {
        guard id != anchorID, let from = groups.firstIndex(where: { $0.id == id }) else { return }
        let moving = groups.remove(at: from)
        if let anchorID, let index = groups.firstIndex(where: { $0.id == anchorID }) {
            groups.insert(moving, at: index)
        } else {
            groups.append(moving)
        }
        persist()
    }

    // MARK: - 拖动排序

    /// 拖动主机：把这些主机搬进 `groupID`（nil = 未分组），插到 `anchorID` 之前。
    /// `anchorID` 为 nil 表示放到那个分组的末尾。
    ///
    /// `hostIDs` 的先后决定它们落地后的相对顺序（多选拖动时按列表顺序传进来）。
    public func move(hostIDs: [UUID], toGroup groupID: UUID?, before anchorID: UUID?) {
        // 分组不存在就当未分组，别把主机丢进一个看不见的段里。
        let destination = groupID.flatMap { group(id: $0)?.id }
        let moving = hostIDs.compactMap { id in hosts.first { $0.id == id } }
        guard !moving.isEmpty else { return }
        // 落点就在被拖的这几台里面：原地不动。
        if let anchorID, hostIDs.contains(anchorID) { return }

        let ids = Set(hostIDs)
        var remaining = hosts.filter { !ids.contains($0.id) }
        let relocated = moving.map { host -> HostConfig in
            var copy = host
            copy.groupID = destination
            return copy
        }

        if let anchorID, let index = remaining.firstIndex(where: { $0.id == anchorID }) {
            remaining.insert(contentsOf: relocated, at: index)
        } else {
            remaining.append(contentsOf: relocated)
        }
        hosts = remaining
        persist()
    }

    /// 主机管理面板（⌘,）里那个扁平列表的拖动排序。语义与 SwiftUI 的
    /// `move(fromOffsets:toOffset:)` 一致：`destination` 是**原数组**中的插入位置。
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
            let document = try JSONDecoder().decode(Document.self, from: data)
            groups = document.groups ?? []

            // 指向已经不存在的分组（手改过文件、或旧版本留下的残留）就退回未分组。
            let known = Set(groups.map { $0.id })
            hosts = document.hosts.map { host in
                guard let groupID = host.groupID, !known.contains(groupID) else { return host }
                var fixed = host
                fixed.groupID = nil
                return fixed
            }
        } catch {
            NSLog("Moonterm: 读取 %@ 失败：%@", fileURL.path, String(describing: error))
        }
    }

    private func persist() {
        let document = Document(version: Self.currentVersion, hosts: hosts, groups: groups)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try SecureFile.writeAtomically(try encoder.encode(document), to: fileURL)
        } catch {
            NSLog("Moonterm: 写入 %@ 失败：%@", fileURL.path, String(describing: error))
        }
    }
}
