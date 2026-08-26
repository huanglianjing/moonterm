import Foundation

/// 远端文件修改前、根据刚列出的目录内容所做的判定。
public enum RemoteFileMutationValidator {

    /// 重命名的目标是否已经被文件、目录或符号链接占用。
    ///
    /// sftp 的 `rename` 可能直接替换已有的空目录，所以不能把「进程退出码为 0」当成目标不存在；
    /// 必须先列父目录，明确确认名字没有被占用后才能发重命名命令。
    public static func renameDestinationExists(
        _ destination: String,
        in entries: [RemoteFileEntry]
    ) -> Bool {
        let destination = RemotePath.normalize(destination)
        return entries.contains { RemotePath.normalize($0.path) == destination }
    }
}
