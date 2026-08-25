import Foundation

/// Moonterm 在磁盘上用到的位置。
public enum MoontermPaths {

    /// `~/Library/Application Support/Moonterm`，目录权限 0700。
    public static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Moonterm", isDirectory: true)
    }

    /// 主机配置（不含密码）。
    public static var hostsFile: URL {
        applicationSupport.appendingPathComponent("hosts.json")
    }

    /// 明文密码（权限 0600）。
    public static var secretsFile: URL {
        applicationSupport.appendingPathComponent("secrets.json")
    }

    /// 一个会话的 ControlMaster socket 路径（每调一次是一个新的）。
    ///
    /// 放在临时目录里 —— macOS 上 `NSTemporaryDirectory()` 是**每用户私有**的 0700 目录
    /// （和 `AskpassBridge` 放临时密码文件是同一处），所以别人抢不到这个路径。
    /// 换成 `/tmp` 就不行了：那儿谁都能写，别人可以先占住这个名字，
    /// 让我们的 sftp 连到一个假的 socket 上去。
    ///
    /// 名字故意取短：unix socket 的路径有 104 字节上限（`sun_path`），超了 ssh 直接报错。
    /// 这里全长大约 70 字节，留得住余量。
    public static func newControlSocketPath() -> String {
        let name = "moonterm-ctl-\(UUID().uuidString.prefix(8)).sock"
        return (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
    }
}
