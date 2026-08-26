/// 用 sftp 删除非空目录前的发现与命令排序状态。
///
/// sftp 只有 `rm` 和 `rmdir`，没有递归删除参数，所以调用方要逐级 `ls`，把结果交给这里；
/// 全部发现完之后才能拿到“文件在前、目录由深到浅”的删除命令。符号链接按文件删除，绝不跟进去。
public struct SFTPRecursiveDeletionPlan {

    private var pendingDirectories: [String]
    private var files: [String] = []
    private var directories: [String]

    public init(rootDirectory: String) {
        let root = RemotePath.normalize(rootDirectory)
        self.pendingDirectories = [root]
        self.directories = [root]
    }

    /// 下一次该列哪个目录；nil 表示整棵子树已经发现完。
    public var nextDirectory: String? { pendingDirectories.last }

    /// 记录一次列目录结果。不是当前等待的目录时返回 false，状态不变。
    @discardableResult
    public mutating func record(contents: [RemoteFileEntry], of directory: String) -> Bool {
        let directory = RemotePath.normalize(directory)
        guard pendingDirectories.last == directory else { return false }
        pendingDirectories.removeLast()

        for entry in contents {
            if entry.kind == .directory {
                directories.append(entry.path)
                pendingDirectories.append(entry.path)
            } else {
                files.append(entry.path)
            }
        }
        return true
    }

    /// 完整删除脚本。发现尚未完成时返回 nil，避免漏删没列到的内容。
    public var deletionCommands: [String]? {
        guard pendingDirectories.isEmpty else { return nil }
        return files.map(SFTPCommandBuilder.removeFile)
            + directories.reversed().map(SFTPCommandBuilder.removeDirectory)
    }
}
