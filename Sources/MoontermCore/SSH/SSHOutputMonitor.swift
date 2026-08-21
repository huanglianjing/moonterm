import Foundation

/// 盯着 ssh 的输出，做两件事：
///
/// 1. **失败归因**：把 ssh 的英文报错翻译成一句人话，进程退出时用它显示原因。
/// 2. **密码兜底**：askpass 是主路径；万一没走通（ssh 直接在终端里问密码），
///    这里检测到提示符就把密码写回 PTY。
///
/// 纯逻辑，不碰 UI 也不碰进程，便于单测。
public final class SSHOutputMonitor {

    /// 输出滚动窗口，只保留尾部，够判断提示符和报错就行。
    private static let windowSize = 4096

    private var window = ""
    private let password: String

    /// 最近一次识别出的失败原因（人话）。进程退出时读它。
    public private(set) var diagnostic: String?

    /// 密码是否已经兜底注入过。只注入一次，避免密码错了反复灌。
    public private(set) var didInjectPassword = false

    /// 注入窗口。由会话层控制：连接建立一段时间后关掉，
    /// 免得把远端的 `sudo` 密码提示误当成 ssh 的提示。
    public var passwordInjectionEnabled = true

    public init(password: String) {
        self.password = password
    }

    /// 吃掉一段来自 PTY 的输出。
    /// - Returns: 需要写回 PTY 的内容（密码 + 回车），不需要则 nil。
    public func consume(_ bytes: ArraySlice<UInt8>) -> String? {
        // ssh 的提示与报错都是 ASCII，lossy 解码足够；远端的中文输出坏掉也无所谓，
        // 因为窗口只用来做模式匹配，不用于显示。
        window += String(decoding: bytes, as: UTF8.self)
        if window.count > Self.windowSize {
            window = String(window.suffix(Self.windowSize))
        }

        if let reason = Self.classifyFailure(in: window) {
            diagnostic = reason
        }

        guard passwordInjectionEnabled,
              !didInjectPassword,
              !password.isEmpty,
              Self.looksLikeSSHPasswordPrompt(window)
        else {
            return nil
        }

        didInjectPassword = true
        // 注入后清空窗口，防止同一段提示被重复匹配。
        window = ""
        return password + "\n"
    }

    /// 会话结束后重置，供重连复用。
    public func reset() {
        window = ""
        diagnostic = nil
        didInjectPassword = false
        passwordInjectionEnabled = true
    }

    // MARK: - 模式匹配

    /// 判断输出尾部是不是 **ssh 自己**在问密码。
    ///
    /// 判定放在「最后一行」上而不是整段尾部，因为 ssh 的提示语只有固定几种形态：
    ///
    /// - `user@host's password:`
    /// - `Password:`（keyboard-interactive / PAM）
    /// - `Enter passphrase for key '…':`
    ///
    /// 这样远端 shell 里恰好以 `password:` 结尾的普通输出（`$ echo password:`）不会误触，
    /// `[sudo] password for xxx:` 也不会 —— 把 SSH 密码灌给 sudo 是安全事故。
    public static func looksLikeSSHPasswordPrompt(_ text: String) -> Bool {
        let tail = String(text.suffix(512)).lowercased()
        guard !tail.contains("[sudo]") else { return false }

        // 私钥 passphrase 的提示语很独特，不会在普通输出里出现，直接整段匹配。
        if tail.contains("enter passphrase for") { return true }

        // 提示符后面没有换行，所以取去掉尾部空白后的最后一行。终端里 \r 也算换行。
        // 注意：Swift 把 "\r\n" 当**一个** Character，按 Character 比较 \n / \r 是拆不开行的，
        // 所以先把换行统一成 \n 再拆。
        let normalized = tail
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lastLine = normalized
            .split(separator: "\n")
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? normalized

        if lastLine == "password:" { return true }
        if lastLine.hasSuffix("'s password:") { return true }
        return false
    }

    /// 把 ssh 的报错映射成中文。找不到已知标记返回 nil。
    public static func classifyFailure(in text: String) -> String? {
        for (marker, reason) in failureMarkers where text.contains(marker) {
            return reason
        }
        return nil
    }

    /// 顺序有意义：越具体的放前面。
    private static let failureMarkers: [(String, String)] = [
        ("REMOTE HOST IDENTIFICATION HAS CHANGED",
         "服务端主机密钥变了，可能是重装系统或存在中间人；确认无误后删除 ~/.ssh/known_hosts 中的旧记录"),
        ("Host key verification failed",
         "主机密钥校验失败：与 ~/.ssh/known_hosts 中的记录不一致"),
        ("Too many authentication failures",
         "认证尝试次数过多，被服务端断开"),
        ("Permission denied",
         "认证失败：用户名或密码不正确"),
        ("Could not resolve hostname",
         "无法解析主机名，检查地址或 DNS"),
        ("nodename nor servname provided",
         "无法解析主机名，检查地址或 DNS"),
        ("Connection refused",
         "连接被拒绝：目标端口没有服务在监听，或被防火墙拦掉了"),
        ("Operation timed out",
         "连接超时：网络不通或被丢包"),
        ("Connection timed out",
         "连接超时：网络不通或被丢包"),
        ("No route to host",
         "网络不可达"),
        ("Network is unreachable",
         "网络不可达"),
        ("Connection reset by peer",
         "连接被服务端重置"),
        ("Connection closed by remote host",
         "连接被服务端关闭"),
        ("Broken pipe",
         "连接中断"),
        ("kex_exchange_identification",
         "握手失败：对端可能不是 SSH 服务，或拒绝了本机连接")
    ]
}
