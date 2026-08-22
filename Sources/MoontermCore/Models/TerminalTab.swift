import Foundation

/// tab 条上的一项：**一台固定的主机** + 一棵分栏树 + 当前聚焦的会话。
///
/// 一个 tab 只装这一台主机的终端，新建与划分分栏都只能发生在这个 tab 内部；
/// tab 条上的 tab 只能拖动排序，不会互相合并。
///
/// 一个 tab 里可以有多个分栏（`root` 是 `.split`），一个分栏里还可以叠放多个窗口
/// （用分栏顶部的小标签条切换）。每个窗口在本 tab 内有一个「窗口 N」的名字。
public struct TerminalTab: Identifiable, Equatable {

    public let id: UUID
    /// 这个 tab 绑定的主机。建好之后不再变，所以标题也是稳定的。
    public let host: HostConfig
    public var root: PaneNode
    /// 键盘焦点所在的会话。始终是 `root` 里存在的会话。
    public var focusedSessionID: UUID

    /// 各窗口的编号（窗口 1、窗口 2…），按会话 id 索引。
    /// 编号在本 tab 内唯一；窗口关掉后编号会被释放，下次新建补最小空缺。
    private var windowNumbers: [UUID: Int]

    public init(id: UUID = UUID(), host: HostConfig, sessionID: UUID) {
        self.id = id
        self.host = host
        self.root = .terminal(sessionID)
        self.focusedSessionID = sessionID
        self.windowNumbers = [sessionID: 1]
    }

    /// tab 标题就是主机名 —— tab 与主机一一对应，没有别的可能。
    public var title: String { host.displayName }

    public var sessionIDs: [UUID] { root.sessionIDs }
    /// 各分栏当前显示的会话。
    public var activeSessionIDs: [UUID] { root.activeSessionIDs }
    /// 分栏个数。
    public var paneCount: Int { root.paneCount }
    /// 窗口总数（一个分栏里可能叠了好几个）。
    public var sessionCount: Int { root.sessionCount }

    public func contains(sessionID: UUID) -> Bool { root.contains(sessionID: sessionID) }

    // MARK: - 窗口编号

    /// 给新窗口分配编号：取本 tab 内**未被占用的最小正整数**。
    /// 已经有编号的会话原样返回，不会改名。
    @discardableResult
    public mutating func assignWindowNumber(to sessionID: UUID) -> Int {
        if let existing = windowNumbers[sessionID] { return existing }
        let used = Set(windowNumbers.values)
        var candidate = 1
        while used.contains(candidate) { candidate += 1 }
        windowNumbers[sessionID] = candidate
        return candidate
    }

    /// 窗口关掉后把编号释放出来，让下次新建能补上这个空缺。
    public mutating func releaseWindowNumber(of sessionID: UUID) {
        windowNumbers.removeValue(forKey: sessionID)
    }

    public func windowNumber(of sessionID: UUID) -> Int? {
        windowNumbers[sessionID]
    }

    /// 分栏小标签上显示的名字。没登记过编号（理论上不会）时按视觉顺序兜底，不至于没名字。
    public func windowName(of sessionID: UUID) -> String {
        if let number = windowNumbers[sessionID] { return "窗口\(number)" }
        let fallback = (sessionIDs.firstIndex(of: sessionID) ?? 0) + 1
        return "窗口\(fallback)"
    }
}
