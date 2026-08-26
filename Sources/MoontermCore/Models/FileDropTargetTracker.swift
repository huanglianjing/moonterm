import Foundation

/// 追踪文件拖放期间仍处于命中状态的具体行，并给出最后进入那一行对应的实际上传目录。
///
/// SwiftUI 在鼠标跨过相邻落点时不保证「旧行离开」和「新行进入」的回调顺序。尤其两行映射到
/// 同一个父目录时，若只存目录，旧行稍晚到达的离开事件会误清掉新行刚写入的高亮。
/// 这里以行路径区分事件：一行离开只移除自己，不能影响同目录下仍命中的另一行。
public struct FileDropTargetTracker: Equatable, Sendable {

    private struct Target: Equatable, Sendable {
        let rowPath: String
        let destination: String
    }

    /// 按进入顺序排列；最后一个就是当前最具体的落点。
    private var activeTargets: [Target] = []

    public init() {}

    /// nil 表示没有任何具体文件行处于命中状态，调用方可退回列表空白区的根目录落点。
    public var destination: String? { activeTargets.last?.destination }

    /// 更新某一行的命中状态。同一行重复进入会移到末尾，代表它是当前最新、最具体的落点。
    public mutating func setTarget(rowPath: String, destination: String, isTargeted: Bool) {
        activeTargets.removeAll { $0.rowPath == rowPath }
        if isTargeted {
            activeTargets.append(Target(rowPath: rowPath, destination: destination))
        }
    }

    /// 整次拖放离开文件树或结束时清空，避免 LazyVStack 回收行后留下过期落点。
    public mutating func clear() {
        activeTargets.removeAll()
    }
}
