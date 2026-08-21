import Foundation

/// 只给本用户可读的文件读写工具。配置与密码都走这里，保证落盘权限是 0600。
enum SecureFile {

    /// 创建目录（若不存在），权限 0700。
    static func ensureDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } else {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }

    /// 原子写入：先写同目录下的临时文件（0600），再 rename 覆盖目标。
    /// 中途崩溃不会留下半个文件。
    static func writeAtomically(_ data: Data, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")

        try data.write(to: tmp, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)

        // rename(2) 在同一文件系统内是原子的；replaceItemAt 会保留目标的元数据。
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func read(_ url: URL) -> Data? {
        FileManager.default.contents(atPath: url.path)
    }
}
