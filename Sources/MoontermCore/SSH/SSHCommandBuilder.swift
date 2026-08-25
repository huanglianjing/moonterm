import Foundation

/// 启动一次 ssh 需要的全部参数。
public struct SSHLaunchPlan: Equatable {
    public let executable: String
    /// 直接交给 execve 的 argv（不经过 shell），所以不需要任何引号转义。
    public let arguments: [String]
    /// `KEY=VALUE` 形式的环境变量。
    public let environment: [String]

    public init(executable: String, arguments: [String], environment: [String]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}

/// 构造 `/usr/bin/ssh` 的命令行与环境变量。
///
/// 纯函数，没有副作用，便于单测。
public enum SSHCommandBuilder {

    public static let sshExecutable = "/usr/bin/ssh"

    /// 传给 askpass 助手的密码文件路径，通过环境变量交接。
    public static let secretFileEnvKey = "MOONTERM_SECRET_FILE"

    /// - Parameters:
    ///   - config: 主机配置。
    ///   - askpass: 密码非空时传入（askpass 助手路径 + 密码文件路径）；为 nil 表示不用密码，
    ///              交给 ssh 自己决定认证方式（公钥、agent、或在终端里手动输密码）。
    ///   - controlPath: 这条连接的 ControlMaster socket 路径，文件面板靠它复用同一条连接跑 sftp
    ///                  （详见下面 ControlMaster 那段注释）。nil = 不开多路复用。
    ///   - baseEnvironment: 终端仿真器给出的基础环境变量（TERM/LANG 等）。
    public static func makePlan(
        config: HostConfig,
        askpass: (helperPath: String, secretPath: String)?,
        controlPath: String? = nil,
        baseEnvironment: [String]
    ) -> SSHLaunchPlan {

        var arguments: [String] = [
            "-p", String(config.port),
            // 首连自动记录主机密钥；关掉则退回交互式询问。
            "-o", "StrictHostKeyChecking=\(config.acceptNewHostKey ? "accept-new" : "ask")",
            // 保活，避免 NAT/防火墙静默掉线。
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=15"
        ]

        if let controlPath {
            // 开一条 ControlMaster：文件面板的 sftp 复用**这一条已经认证过的连接**，
            // 于是列目录和传文件都不用再走一遍认证，密码全程只在这里出现一次。
            //
            // socket 路径是**每个会话一份**，不是每台主机一份 —— 同一 tab 里几个分栏各自独立。
            // 换成按主机共享的话，当 master 的那个分栏一断，同主机其他分栏会跟着一起掉。
            arguments += [
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=\(controlPath)"
            ]
        }

        if askpass != nil {
            // 配了密码就只走密码类认证：省掉公钥失败的等待，也不会弹私钥 passphrase。
            arguments += [
                "-o", "PreferredAuthentications=keyboard-interactive,password",
                "-o", "PubkeyAuthentication=no",
                // 密码错误时最多问两次就退出，避免反复灌密码。
                "-o", "NumberOfPasswordPrompts=2"
            ]
        }

        arguments += ["-l", config.username, config.host]

        var environment = baseEnvironment.filter { entry in
            // 用我们自己的 askpass 设置覆盖掉继承来的同名变量。
            !entry.hasPrefix("SSH_ASKPASS=")
                && !entry.hasPrefix("SSH_ASKPASS_REQUIRE=")
                && !entry.hasPrefix("\(secretFileEnvKey)=")
        }

        if environment.first(where: { $0.hasPrefix("PATH=") }) == nil {
            environment.append("PATH=/usr/bin:/bin:/usr/sbin:/sbin")
        }

        if let askpass = askpass {
            environment.append("SSH_ASKPASS=\(askpass.helperPath)")
            // OpenSSH 8.4+ 的 force：即使有控制终端也强制走 askpass，且不需要 DISPLAY。
            environment.append("SSH_ASKPASS_REQUIRE=force")
            environment.append("\(secretFileEnvKey)=\(askpass.secretPath)")
        }

        return SSHLaunchPlan(
            executable: sshExecutable,
            arguments: arguments,
            environment: environment
        )
    }
}
