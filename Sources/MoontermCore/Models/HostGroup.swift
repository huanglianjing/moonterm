import Foundation

/// 主机能被移到的一段。见 `ConfigStore.moveDestinations(forHostIDs:)`。
public enum HostMoveDestination: Hashable {
    case group(HostGroup)
    /// 所有分组下面那一段。
    case ungrouped
}

/// 主机分组：侧栏里的一层收纳。所有分组排在上面，未分组的主机垫在所有分组下面。
///
/// 分组**不带任何连接参数** —— 它不是「继承设置」的容器，只管装哪些主机、按什么顺序显示。
/// 成员关系由 `HostConfig.groupID` 单向指过来，分组这边不存主机列表：
/// 顺序只有一份（`ConfigStore.hosts` 的数组顺序），免得两处顺序对不上还得同步。
public struct HostGroup: Identifiable, Codable, Hashable {
    public var id: UUID
    public var name: String
    /// 折叠起来了（只剩标题行）。跟配置一起存，下次打开照旧。
    public var isCollapsed: Bool

    /// 新建分组的默认名字。新建后立刻进入改名状态，所以这个名字通常只存在一瞬间。
    public static let defaultName = "新分组"

    public init(id: UUID = UUID(), name: String = "", isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
    }

    /// 列表里展示的名字。空名字兜底成默认名 —— 否则会出现一行看不见、点不着的标题。
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? Self.defaultName : trimmed
    }

    public func normalized() -> HostGroup {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespaces)
        return copy
    }

    // MARK: - Codable
    //
    // 和 `HostConfig` 一样手写 decode：缺字段退回默认值，手改过的 hosts.json 也读得出来。

    private enum CodingKeys: String, CodingKey {
        case id, name, isCollapsed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.isCollapsed = try c.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
    }
}
