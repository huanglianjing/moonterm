import Foundation

/// 构造 `/usr/bin/sftp` 的命令行，以及喂给它的批处理脚本。
///
/// 纯函数，没有副作用，便于单测。真正跑进程的是 `SFTPRunner`。
///
/// 为什么是 sftp 而不是 `ssh host ls`：`ls` 的输出格式各家系统不一样（GNU 有 `--time-style`，
/// BSD 没有），而 sftp 在带 `-n` 时是**客户端自己**格式化的，格式与服务端实现无关。
/// 传输也一样 —— `get`/`put` 走 SFTP 协议，不依赖远端有什么工具。
public enum SFTPCommandBuilder {

    public static let sftpExecutable = "/usr/bin/sftp"

    /// 强制给 sftp 进程的环境变量（由 `SFTPRunner` 叠在继承来的环境上面，不是整套替换）。
    ///
    /// **必须是 UTF-8 的 locale**，否则 sftp 会把名字里所有非 ASCII 字节按八进制转义打出来
    /// （`中文.txt` 变成 `\344\270\255\346\226\207.txt`）—— 这不只是显示难看：
    /// 转义后的名字再拿回去 `get` 是找不到文件的。
    ///
    /// 从 `.app` 里启动时环境本来就没有 `LANG`（Finder 不给），所以不能指望继承。
    /// 用 `LC_ALL` 而不是 `LANG`：它压得住继承来的任何 `LC_*`，顺带把 `ls` 输出里的月份
    /// 也钉在英文上，`SFTPListingParser` 的字段划分就不会随用户语言变。
    public static let forcedEnvironment = ["LC_ALL=en_US.UTF-8"]

    // MARK: - 命令行

    /// 一次 sftp 调用的 argv 与工作方式。
    ///
    /// - Parameters:
    ///   - config: 主机配置（只用到端口、用户名、地址）。
    ///   - controlPath: 终端会话那条 ssh 开出来的 ControlMaster socket。**复用它就不用再认证一次**，
    ///                  密码只在终端那次连接时经过 askpass，文件面板全程不碰密码。
    public static func makePlan(config: HostConfig, controlPath: String) -> SSHLaunchPlan {
        let arguments: [String] = [
            // 从 stdin 读命令。批处理模式下每条命令会把 `sftp> <原命令>` 回显到 stdout ——
            // `SFTPRunner` 靠这些回显行把一次调用的输出切成每条命令一段。
            "-b", "-",
            // 只压掉版本横幅与传输统计；`sftp> ` 回显**不受它影响**（实测），分帧照样可用。
            "-q",
            "-P", String(config.port),
            // 只复用现成的 master，不自己开新的：master 不在时立刻失败，
            // 而不是在后台悄悄拉一条没人管的连接。
            "-o", "ControlMaster=no",
            "-o", "ControlPath=\(controlPath)",
            // 绝不交互提问。master 在时根本不需要认证；master 不在又没有密钥时，
            // 这条保证它直接报错退出，而不是挂在那儿等一个没人能看见的密码提示。
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=15",
            "\(config.username)@\(config.host)"
        ]

        return SSHLaunchPlan(
            executable: sftpExecutable,
            arguments: arguments,
            // 只覆盖 locale，其余（HOME、PATH …）继承 —— ssh 要靠 HOME 找 `~/.ssh`。
            // 不需要 askpass 那一套：走 master 时没有认证环节，`BatchMode=yes` 也不会去问密码。
            environment: forcedEnvironment
        )
    }

    // MARK: - 单条命令

    /// 列目录。
    ///
    /// `-n` **不能去掉**：不带 `-n`（也不带 `-h`）时 sftp 直接打印**服务端给的 longname**，
    /// 那串东西的格式由服务端实现决定；带 `-n` 走的是客户端本地格式化，格式固定，
    /// `SFTPListingParser` 就是照那个格式写的。`-a` 是为了把隐藏文件也拿回来
    /// （显不显示由界面那边过滤，不用为了切换重新列一次）。
    public static func list(directory: String) -> String {
        "ls -lan \(quote(directory))"
    }

    /// 问远端的家目录：sftp 刚连上时的工作目录就是家目录。
    public static let pwd = "pwd"

    /// 下载。`-p` 保留权限与时间戳；目录要加 `-r`。
    public static func get(remote: String, local: String, recursive: Bool) -> String {
        "get \(recursive ? "-rp" : "-p") \(quote(remote)) \(quote(local))"
    }

    /// 上传。参数顺序和 `get` 相反：先本地再远端。
    public static func put(local: String, remote: String, recursive: Bool) -> String {
        "put \(recursive ? "-rp" : "-p") \(quote(local)) \(quote(remote))"
    }

    /// 新建远端目录。
    public static func makeDirectory(_ path: String) -> String {
        "mkdir \(quote(path))"
    }

    /// 重命名文件、目录或符号链接。目标路径必须包含新名字，不能只传名字。
    public static func rename(from source: String, to destination: String) -> String {
        "rename \(quote(source)) \(quote(destination))"
    }

    /// 删除文件或符号链接。目录必须走 `removeDirectory`，sftp 的 `rm` 不支持递归参数。
    public static func removeFile(_ path: String) -> String {
        "rm \(quote(path))"
    }

    /// 删除空目录。非空目录要先把里面的文件和子目录清掉。
    public static func removeDirectory(_ path: String) -> String {
        "rmdir \(quote(path))"
    }

    /// 把路径包成 sftp 认的一个参数。
    ///
    /// 只需要转义 `\` 和 `"`：**双引号会把 glob 一起关掉**（实测过 —— 不加引号时
    /// `star*.txt` 会匹配到 `starX.txt`，加了引号只命中字面那个文件）。
    /// 所以千万**别**再给 `*` `?` `[` 补反斜杠，那样反而会让 sftp 去找一个名字里真带反斜杠的文件。
    public static func quote(_ path: String) -> String {
        var escaped = ""
        for character in path {
            if character == "\\" || character == "\"" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return "\"\(escaped)\""
    }

    // MARK: - 批处理脚本与分帧

    /// 把若干命令拼成喂给 stdin 的脚本。
    ///
    /// **故意不加 sftp 的 `-` 前缀**（那个前缀的意思是「这条错了也接着往下跑」）。批处理模式默认
    /// 一条出错就整批中断，而这正是想要的：
    ///
    /// - 加了 `-` 之后 sftp 一律以退出码 0 收场，「成没成」只能去猜 stderr 里那几行算不算错，
    ///   而 ssh 本身也会往 stderr 写警告（比如新主机密钥那条），一猜就会误判。
    /// - 「展开到某个深路径」列的是 `/`、`/a`、`/a/b` 这样**由外到内**的一串，中间某级列不了时，
    ///   比它更深的几级本来也进不去，跑完只是白费一次往返。
    ///
    /// 于是失败判定就干净了：退出码非 0 = 这批没跑完，stderr 第一行就是原因，
    /// 而 `splitBatchOutput` 里已经拿到的那几段照样能用。
    public static func batchScript(_ commands: [String]) -> String {
        commands.map { "\($0)\n" }.joined()
    }

    /// 把大量命令切成不会塞满 stdin 管道的小批次。
    ///
    /// 递归删除可能有几千条 `rm` / `rmdir`；`SFTPRunner` 是先写完整脚本再读输出，单批超过管道
    /// 缓冲就可能两边互等。单条命令即使超过上限也会独占一批，不能悄悄丢掉。
    public static func commandBatches(
        _ commands: [String],
        maximumScriptBytes: Int = 32 * 1024
    ) -> [[String]] {
        guard !commands.isEmpty else { return [] }
        let limit = max(maximumScriptBytes, 1)
        var result: [[String]] = []
        var current: [String] = []
        var currentBytes = 0

        for command in commands {
            let bytes = command.utf8.count + 1  // batchScript 会补一个换行。
            if !current.isEmpty, currentBytes + bytes > limit {
                result.append(current)
                current = []
                currentBytes = 0
            }
            current.append(command)
            currentBytes += bytes
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// 把一次调用的 stdout 按命令切开。
    ///
    /// 分帧靠的是 sftp 自己打的回显行 `sftp> <原命令>`（批处理模式下每条命令都会回显）。
    /// 错误信息走 stderr，所以 stdout 里除了回显行只有命令的正常输出，切分不会被搅乱。
    ///
    /// - Returns: 与 `commands` 一一对应；某条命令没有任何输出时是空串。
    ///            没轮到的那些（前面有命令失败、整批中断）是 nil。
    public static func splitBatchOutput(_ stdout: String, commands: [String]) -> [String?] {
        var result = [String?](repeating: nil, count: commands.count)
        /// 当前正在收集哪条命令的输出；nil = 还没遇到第一条回显。
        var current: Int?
        var buffer: [String] = []

        func flush() {
            if let current {
                result[current] = buffer.joined(separator: "\n")
            }
            buffer = []
        }

        for line in stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(line)
            // 只认**下一条**的回显，按顺序往前推：万一某条命令的输出里有一行恰好长得像回显，
            // 它也对不上下一条命令的原文，不会把分帧带偏。
            let next = current.map { $0 + 1 } ?? 0
            if commands.indices.contains(next), line == echoPrefix + commands[next] {
                flush()
                current = next
                continue
            }
            buffer.append(line)
        }
        flush()
        return result
    }

    private static let echoPrefix = "sftp> "

    /// 从 `pwd` 的输出里取远端家目录。sftp 打的是 `Remote working directory: /home/me`。
    public static func parsePwd(_ output: String) -> String? {
        let marker = "Remote working directory:"
        for line in output.split(separator: "\n") {
            guard let range = line.range(of: marker) else { continue }
            let path = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !path.isEmpty { return path }
        }
        return nil
    }

    /// 把 sftp 的 stderr 收成一句能给人看的话。
    ///
    /// sftp 的报错基本是一行一条（`Can't ls: "/x" not found`、`Permission denied`），
    /// 取第一条非空行就够；连接层的失败（master 不在）会多打几行，那时也是第一行最有信息量。
    public static func firstError(in stderr: String) -> String? {
        for line in stderr.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
