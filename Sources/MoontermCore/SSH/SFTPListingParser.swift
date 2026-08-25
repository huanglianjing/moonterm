import Foundation

/// 解析 sftp `ls -lan` 的输出。
///
/// 格式是 sftp **客户端**排的（`-n` 的作用，见 `SFTPCommandBuilder.list`），所以与服务端实现无关：
///
/// ```
/// drwxr-xr-x    ? moondo   wheel         256 Aug 25 13:22 /tmp/x/.
/// -rw-r--r--    ? moondo   wheel           1 Aug 25 13:22 /tmp/x/name with  spaces.txt
/// -rw-r--r--    ? moondo   wheel           0 Jan  1  2020 /tmp/x/old.txt
/// lrwxr-xr-x    ? moondo   wheel           5 Aug 25 13:22 /tmp/x/link.txt
/// ```
///
/// 前 5 段是 mode / 硬链接数 / 属主 / 属组 / 字节数（硬链接数 SFTP 协议里没有，常常就是 `?`），
/// 接着**恰好 3 段**时间：近半年是 `Aug 25 13:22`，更早是 `Jan  1  2020`（`%e` 用空格补位，
/// 按空白切分后都是 3 段）。第 9 段开始全是名字 —— 名字里可以有空格，所以只能从左边数着切，
/// 不能整行 split 完取最后一个。
public enum SFTPListingParser {

    /// 时间占的段数，见类型注释。
    private static let dateFieldCount = 3
    /// 名字之前固定有多少段。
    private static let fieldsBeforeName = 5 + dateFieldCount

    /// - Parameter directory: 这次列的是哪个目录，用来拼每一项的绝对路径。
    /// - Returns: 目录排在文件前面，各自按名字排序。`.` 与 `..` 会被丢掉。
    public static func parse(_ stdout: String, directory: String) -> [RemoteFileEntry] {
        var entries: [RemoteFileEntry] = []

        for rawLine in stdout.split(separator: "\n") {
            let line = String(rawLine)
            guard let entry = parseLine(line, directory: directory) else { continue }
            entries.append(entry)
        }

        return sorted(entries)
    }

    /// 解析一行。不像一条记录（回显行、空行、sftp 的杂项输出）就返回 nil。
    static func parseLine(_ line: String, directory: String) -> RemoteFileEntry? {
        var fields: [String] = []
        // 手动扫一遍而不是 `split`：切到第 8 段就得停下，剩下的原文（含空格）整块是名字。
        var index = line.startIndex
        while fields.count < fieldsBeforeName {
            while index < line.endIndex, line[index] == " " { index = line.index(after: index) }
            guard index < line.endIndex else { return nil }
            let start = index
            while index < line.endIndex, line[index] != " " { index = line.index(after: index) }
            fields.append(String(line[start..<index]))
        }
        while index < line.endIndex, line[index] == " " { index = line.index(after: index) }
        let rawName = String(line[index...])
        guard !rawName.isEmpty else { return nil }

        let modeText = fields[0]
        // mode 那一段是 `strmode` 的输出：10 个字符，第一个是类型。
        // 放宽到 11 是给 ACL 标记（`+`/`@`）留个余地。不长这样的行就不是记录 ——
        // sftp 的提示语和回显行都在这一步被挡掉。
        guard (10...11).contains(modeText.count), let kind = kind(from: modeText) else { return nil }

        // 传绝对路径给 `ls` 时，名字回来是带完整路径的；传相对路径时只有基名。两种都取最后一段。
        // 一定要用不规范化的那个版本，否则 `.` 与 `..` 会被解析成上一级的名字，就滤不掉了。
        let name = RemotePath.lastComponent(of: rawName)
        guard name != ".", name != "..", name != RemotePath.root else { return nil }

        return RemoteFileEntry(
            path: RemotePath.join(directory, name),
            name: name,
            kind: kind,
            // 拿不到大小（`?`）就算 0：显示成 `0 B` 比让整行解析失败强。
            size: UInt64(fields[4]) ?? 0,
            modeText: modeText,
            owner: fields[2],
            group: fields[3],
            dateText: fields[5...(5 + dateFieldCount - 1)].joined(separator: " ")
        )
    }

    private static func kind(from modeText: String) -> RemoteFileEntry.Kind? {
        switch modeText.first {
        case "d": return .directory
        case "l": return .symlink
        // 普通文件、以及设备/管道/socket 这些（`b` `c` `p` `s`）都当文件看：
        // 它们既不能展开也不该拦着不给下载。
        case "-", "b", "c", "p", "s": return .file
        default: return nil
        }
    }

    /// 目录在前，然后按名字。名字比较**大小写不敏感 + 数字感知**，
    /// 这样 `log2` 排在 `log10` 前面，和 Finder 看起来一致。
    static func sorted(_ entries: [RemoteFileEntry]) -> [RemoteFileEntry] {
        entries.sorted { lhs, rhs in
            let lhsIsDirectory = lhs.kind == .directory
            let rhsIsDirectory = rhs.kind == .directory
            if lhsIsDirectory != rhsIsDirectory { return lhsIsDirectory }
            let order = lhs.name.compare(
                rhs.name,
                options: [.caseInsensitive, .numeric],
                range: nil,
                locale: nil
            )
            // 只差大小写时（`README` 与 `readme`）再按原文分个先后，否则排序结果不稳定。
            if order == .orderedSame { return lhs.name < rhs.name }
            return order == .orderedAscending
        }
    }
}
