import Foundation

/// 远端目录里的一项。
///
/// 字段是从 sftp 客户端自己格式化的 `ls -lan` 一行里解析出来的（见 `SFTPListingParser`），
/// 所以时间只有**字符串**没有 `Date`：sftp 打的是 `Aug 25 13:22`（近半年）或 `Jan  1  2020`（更早），
/// 前者根本没有年份。硬解成 `Date` 只能靠猜年份，还得赌远端时区；列表里照原样显示反而不丢信息。
public struct RemoteFileEntry: Identifiable, Hashable {

    public enum Kind: Hashable {
        case directory
        case file
        /// 符号链接。指向目录还是文件，`ls` 这一行看不出来（服务端给的是 lstat 结果）。
        case symlink
    }

    /// 绝对路径，同时当身份用 —— 同一个目录里名字不会重复，跨目录也不会撞。
    public var id: String { path }

    public let path: String
    /// 最后一段名字。
    public let name: String
    public let kind: Kind
    /// 字节数。目录的大小没有意义，但服务端照样给，原样留着。
    public let size: UInt64
    /// `drwxr-xr-x` 那一段。
    public let modeText: String
    /// 属主与属组。sftp 拿不到时是数字，甚至可能是 `?`。
    public let owner: String
    public let group: String
    /// 修改时间的原文，见类型注释。
    public let dateText: String

    public init(
        path: String,
        name: String,
        kind: Kind,
        size: UInt64,
        modeText: String,
        owner: String,
        group: String,
        dateText: String
    ) {
        self.path = path
        self.name = name
        self.kind = kind
        self.size = size
        self.modeText = modeText
        self.owner = owner
        self.group = group
        self.dateText = dateText
    }

    /// 点开头就算隐藏（POSIX 的规矩）。
    public var isHidden: Bool { name.hasPrefix(".") }

    /// 能不能展开。符号链接也给展开的机会 —— 指向目录的链接很常见，
    /// 真不是目录时列一次目录就会报错，那时再告诉用户比一开始就不给点更好。
    public var isExpandable: Bool { kind != .file }

    /// 列表右侧那个大小。目录不显示 —— 那个数字（macOS 上是 256、Linux 上是 4096）
    /// 只会让人误以为是「里面东西的总大小」。
    public var displaySize: String? {
        guard kind != .directory else { return nil }
        return Self.formatBytes(size)
    }

    /// 二进制单位（KiB/MiB），但标签写成 K/M —— 侧栏窄，字要短。
    public static func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "K", "M", "G", "T", "P"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == 0 { return "\(bytes) B" }
        // 到 10 以上就不要小数了：侧栏里 `9.7 M` 和 `128 M` 一样宽才好扫。
        return value < 10
            ? String(format: "%.1f %@", value, units[index])
            : String(format: "%.0f %@", value, units[index])
    }
}
