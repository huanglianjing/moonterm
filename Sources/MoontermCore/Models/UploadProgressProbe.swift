import Foundation

/// 用远端目标文件的当前大小推算普通文件上传进度。
///
/// 覆盖已有文件时，上传进程可能还没来得及截断目标，第一次查询仍会读到旧大小。
/// 在看到大小发生变化之前忽略这个旧值，避免进度刚开始就错误跳到 100%。
public struct UploadProgressProbe: Equatable {

    private let initialRemoteSize: UInt64?
    private var hasObservedWrite: Bool

    /// - Parameter initialRemoteSize: 上传前目标文件的大小；目标不存在或大小未知时传 nil。
    public init(initialRemoteSize: UInt64?) {
        self.initialRemoteSize = initialRemoteSize
        self.hasObservedWrite = initialRemoteSize == nil
    }

    /// 接收一次远端大小查询结果。
    ///
    /// - Returns: 可以作为已上传字节数的值；仍像是覆盖前的旧文件时返回 nil。
    public mutating func accept(remoteSize: UInt64) -> UInt64? {
        if !hasObservedWrite {
            guard remoteSize != initialRemoteSize else { return nil }
            hasObservedWrite = true
        }
        return remoteSize
    }
}
