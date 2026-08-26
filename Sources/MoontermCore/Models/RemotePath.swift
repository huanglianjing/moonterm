import Foundation

/// 远端（POSIX）路径的拼接与拆解。
///
/// 不用 `URL` 也不用 `NSString.appendingPathComponent`：那些按**本地** macOS 文件系统的规矩来，
/// 会把 `//` 折叠、会对百分号做转义、还会在意大小写；远端路径只是一串字节，规则要自己定死。
public enum RemotePath {

    public static let root = "/"

    /// 去掉重复斜杠与结尾斜杠（`/` 本身除外），`.` 段丢掉，`..` 段回退一级。
    ///
    /// 相对路径（不以 `/` 开头）原样保留相对性 —— 展开 `~` 是 `expandTilde` 的活儿。
    public static func normalize(_ path: String) -> String {
        let isAbsolute = path.hasPrefix(root)
        var stack: [String] = []
        for segment in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch segment {
            case ".":
                continue
            case "..":
                // 绝对路径在根上再 `..` 就停在根；相对路径留着 `..`，否则会静默指错地方。
                if let last = stack.last, last != ".." {
                    stack.removeLast()
                } else if !isAbsolute {
                    stack.append("..")
                }
            default:
                stack.append(String(segment))
            }
        }
        let joined = stack.joined(separator: "/")
        if isAbsolute { return root + joined }
        return joined.isEmpty ? "." : joined
    }

    /// 把一个名字接到目录后面。`name` 是绝对路径时直接用它。
    public static func join(_ directory: String, _ name: String) -> String {
        if name.hasPrefix(root) { return normalize(name) }
        if directory.isEmpty { return normalize(name) }
        return normalize(directory + root + name)
    }

    /// 父目录。根的父目录还是根（往上点不动了，而不是变成空串）。
    public static func parent(of path: String) -> String {
        let normalized = normalize(path)
        guard normalized != root else { return root }
        guard let index = normalized.lastIndex(of: "/") else { return "." }
        if index == normalized.startIndex { return root }
        return String(normalized[normalized.startIndex..<index])
    }

    /// 最后一段。根返回 `/` —— 面包屑上总得有个东西能点。
    public static func name(of path: String) -> String {
        let normalized = normalize(path)
        guard normalized != root else { return root }
        guard let index = normalized.lastIndex(of: "/") else { return normalized }
        return String(normalized[normalized.index(after: index)...])
    }

    /// 能不能作为远端路径里的**一段名字**。
    ///
    /// 空串、`.`、`..` 会改变路径语义，`/` 会把一段拆成多段，NUL 则无法出现在 POSIX 文件名里。
    /// 空格和通配符都是合法名字，交给 `SFTPCommandBuilder.quote` 原样保护，不能顺手禁掉。
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\0")
    }

    /// 最后一段，但**不规范化**。
    ///
    /// 解析 `ls` 输出必须用这个：那里面有 `.` 和 `..` 两项，而规范化会把
    /// `/tmp/x/.` 解成 `/tmp/x`、`/tmp/x/..` 解成 `/tmp` —— 于是列表里凭空多出
    /// 「x」和「tmp」两个条目，`.`/`..` 反而滤不掉了。
    public static func lastComponent(of path: String) -> String {
        var trimmed = Substring(path)
        // 结尾斜杠先剥掉，否则最后一段是空的。
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        guard trimmed != root else { return root }
        guard let index = trimmed.lastIndex(of: "/") else { return String(trimmed) }
        return String(trimmed[trimmed.index(after: index)...])
    }

    /// 从根到自己的每一级，顺序由外到内：`/a/b` → `["/", "/a", "/a/b"]`。
    ///
    /// 文件树「展开到某个深路径」要按这个顺序逐级列目录，面包屑也用同一份。
    public static func ancestors(of path: String) -> [String] {
        let normalized = normalize(path)
        guard normalized.hasPrefix(root) else { return [normalized] }
        var result = [root]
        var current = root
        for segment in normalized.split(separator: "/", omittingEmptySubsequences: true) {
            current = current == root ? root + segment : current + root + segment
            result.append(current)
        }
        return result
    }

    /// 展开开头的 `~`（`~` 或 `~/x`）。`home` 未知时返回 nil —— 宁可不定位，也别猜到别人家目录去。
    ///
    /// 只认自己的 `~`，不管 `~someone` 那种别人的家目录：那要问远端的 passwd，这里拿不到。
    public static func expandTilde(_ path: String, home: String?) -> String? {
        guard path.hasPrefix("~") else { return normalize(path) }
        guard let home, !home.isEmpty else { return nil }
        if path == "~" { return normalize(home) }
        guard path.hasPrefix("~/") else { return nil }
        return join(home, String(path.dropFirst(2)))
    }

    /// 是不是 `ancestor` 底下（含相等）。用来判断「终端的当前目录还在不在我已经展开的这棵子树里」。
    public static func isDescendant(_ path: String, of ancestor: String) -> Bool {
        let path = normalize(path)
        let ancestor = normalize(ancestor)
        if path == ancestor { return true }
        if ancestor == root { return path.hasPrefix(root) }
        return path.hasPrefix(ancestor + root)
    }
}
