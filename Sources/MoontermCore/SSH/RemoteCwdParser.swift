import Foundation

/// 猜远端 shell 当前在哪个目录。
///
/// 为什么只能「猜」：ssh 是被 PTY 包起来的一个黑盒，我们看得见的只有远端**主动吐出来**的东西。
/// 两条线索，按可信度排：
///
/// 1. **OSC 7**（`\e]7;file://host/path\a`）—— 专门用来报当前目录的转义序列，有就一定准。
///    但远端得自己配（zsh 的 `chpwd` 钩子、bash 的 `PROMPT_COMMAND`），Linux 发行版默认都不带。
/// 2. **xterm 标题**（`\e]0;user@host: ~/dir\a`）—— Debian / Ubuntu 的 bash 默认 PS1 就带这一段，
///    覆盖面反而比 OSC 7 大。但它是「标题」，远端爱写什么写什么，所以只认长得像路径的。
///
/// 两条都没有就只能落在家目录，让用户自己点。纯字符串处理，无副作用，有单测。
public enum RemoteCwdParser {

    /// 解析 OSC 7 的值。SwiftTerm 把 `\e]7;` 后面那串原样交过来，形如 `file://hostname/path`。
    ///
    /// 主机名一段**直接忽略**：远端报的是它自己认为的名字，和我们连过去用的地址常常不一样
    /// （跳板机、别名、容器里的短主机名），拿来做校验只会误伤。
    public static func fromOSC7(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }

        var rest: Substring
        if let range = value.range(of: "://") {
            // 跳过 scheme 与 authority：`file://host` 之后的第一个 `/` 才是路径的开头。
            let afterScheme = value[range.upperBound...]
            guard let slash = afterScheme.firstIndex(of: "/") else { return nil }
            rest = afterScheme[slash...]
        } else if value.hasPrefix("/") {
            // 有些实现偷懒，只发路径不发 scheme。
            rest = value[...]
        } else {
            return nil
        }

        // 路径是百分号编码的（空格是 `%20`）。解不出来就用原文 —— 没编码过的实现也不少。
        let decoded = String(rest).removingPercentEncoding ?? String(rest)
        return sanitize(decoded)
    }

    /// 从 xterm 标题里抠路径。
    ///
    /// 认这几种：`user@host: ~/dir`、以及整个标题就是一个路径的情况。
    ///
    /// 取**第一个** `: ` 之后的**全部** —— 前缀是 `user@host` 那种，里头不会有 `": "`，
    /// 而路径里可以有冒号（`/data: backups` 这种目录名是合法的）。按最后一个切就会把它切断。
    public static func fromTitle(_ title: String?) -> String? {
        guard let title, !title.isEmpty else { return nil }

        var candidate = title.trimmingCharacters(in: .whitespaces)
        if let range = candidate.range(of: ": ") {
            candidate = String(candidate[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        // 必须看起来就是个路径。远端把标题写成 `vim foo.txt` 或者 `root@web1` 的时候，
        // 宁可什么都不报，也别把一个不存在的目录塞给文件面板。
        guard candidate.hasPrefix("/") || candidate == "~" || candidate.hasPrefix("~/") else { return nil }
        return sanitize(candidate)
    }

    /// 合并两条线索，并把 `~` 展开成真路径。
    ///
    /// - Parameter home: 远端家目录（由 sftp 刚连上时的 `pwd` 得到）。不知道时 `~` 这类线索只能作废。
    /// - Returns: 绝对路径；两条线索都不可用时 nil。
    public static func resolve(osc7: String?, title: String?, home: String?) -> String? {
        for candidate in [fromOSC7(osc7), fromTitle(title)] {
            guard let candidate else { continue }
            guard let expanded = RemotePath.expandTilde(candidate, home: home) else { continue }
            guard expanded.hasPrefix(RemotePath.root) else { continue }
            return expanded
        }
        return nil
    }

    /// 去掉结尾换行/空白与结尾斜杠。转义序列的载荷里带个 `\r` 很常见。
    private static func sanitize(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
