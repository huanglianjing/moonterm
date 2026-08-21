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
}
