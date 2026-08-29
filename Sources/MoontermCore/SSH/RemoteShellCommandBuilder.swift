import Foundation

/// 构造「在远端跑一段 shell 脚本」的 ssh 命令行。脚本本身从 stdin 灌进去。
///
/// 纯函数，没有副作用，便于单测。目前只有监控面板用（`RemoteMetricsStream`）。
///
/// 和 `SFTPCommandBuilder.makePlan` 是同一条边界：**只复用终端那条已经认证过的
/// ControlMaster socket**，不自己开新连接、不提问。所以密码只在终端那次连接时经过 askpass，
/// 监控全程不碰密码；master 不在时立刻失败，而不是在后台悄悄拉一条没人管的连接。
public enum RemoteShellCommandBuilder {

    /// 远端命令固定是 `sh -s`：从 stdin 读脚本。
    ///
    /// 这样脚本里的引号、`$`、`|` 都不用为「本地 argv → 远端登录 shell」逐层转义，
    /// 也不在乎远端登录 shell 是 bash 还是 csh —— 只要有个 `sh`。
    public static let remoteCommand = ["sh", "-s"]

    /// - Parameters:
    ///   - config: 主机配置（只用到端口、用户名、地址）。
    ///   - controlPath: 终端会话那条 ssh 开出来的 ControlMaster socket。
    public static func makePlan(config: HostConfig, controlPath: String) -> SSHLaunchPlan {
        let arguments: [String] = [
            "-p", String(config.port),
            // 只复用现成的 master，不自己开新的。
            "-o", "ControlMaster=no",
            "-o", "ControlPath=\(controlPath)",
            // 绝不交互提问：走 master 时没有认证环节，master 不在时直接报错退出。
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=15",
            // 不要 tty。分配了 tty 的话远端会把我们的输出按行做回车换行改写，
            // 还会在窗口尺寸变化时收到信号；这里只要一条干净的字节流。
            "-T",
            "\(config.username)@\(config.host)"
        ] + remoteCommand

        return SSHLaunchPlan(
            executable: SSHCommandBuilder.sshExecutable,
            arguments: arguments,
            // 环境全部继承（ssh 要靠 `HOME` 找 `~/.ssh`）。不需要强制 locale ——
            // 远端的 locale 由脚本自己 `export LC_ALL=C` 钉住，本地这套环境影响不到它。
            environment: []
        )
    }
}
