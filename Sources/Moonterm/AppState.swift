import AppKit
import Combine
import CoreGraphics
import Foundation
import MoontermCore

/// 全局状态：活着的会话、tab 列表（每个 tab 绑定一台主机 + 一棵分栏树）、当前选中与聚焦项、字号，以及弹窗开关。
///
/// tab 与主机一一对应：新建 tab 才需要选主机，tab 内部的分栏与叠放窗口一律沿用本 tab 的主机，
/// 也不会跨 tab 搬动。
final class AppState: ObservableObject {

    let configStore: ConfigStore
    /// 拖拽状态。独立观察，避免拖拽每帧重算整棵分栏树。
    let drag = DragController()

    /// 所有活着的会话（不分 tab）。负责生命周期与字号，顺序无意义。
    @Published private(set) var sessions: [SSHSession] = []
    /// tab 条上的项，顺序即显示顺序。
    @Published private(set) var tabs: [TerminalTab] = []
    @Published var selectedTabID: UUID?

    /// 终端字号，持久化在 UserDefaults。
    @Published var fontSize: CGFloat {
        didSet {
            UserDefaults.standard.set(Double(fontSize), forKey: Self.fontSizeKey)
            sessions.forEach { $0.applyFontSize(fontSize) }
        }
    }

    /// 主机管理面板（⌘,）：排序、批量管理这些低频操作。日常连接走左侧竖栏的主机面板。
    @Published var isHostManagerPresented = false
    /// 正在编辑的主机（nil 表示没在编辑）。
    @Published var hostBeingEdited: HostConfig?
    /// 正在重命名的分栏（nil 表示没在重命名）。它的小标签会变成输入框。
    @Published private(set) var sessionBeingRenamed: UUID?

    /// 左侧竖栏当前展开的面板，nil = 收起（只留那条窄竖栏）。记在 UserDefaults 里，下次打开照旧。
    @Published var activeSidebar: SidebarPanel? {
        didSet {
            // 空串表示「用户主动收起的」，和「从没设置过」区分开：首次启动默认展开主机面板。
            UserDefaults.standard.set(activeSidebar?.rawValue ?? "", forKey: Self.sidebarPanelKey)
        }
    }

    /// 展开面板的宽度，可拖右边缘调整。
    @Published private(set) var sidebarWidth: CGFloat {
        didSet { UserDefaults.standard.set(Double(sidebarWidth), forKey: Self.sidebarWidthKey) }
    }

    static let minimumSidebarWidth: CGFloat = 160
    static let maximumSidebarWidth: CGFloat = 420
    static let defaultSidebarWidth: CGFloat = 220

    private static let fontSizeKey = "terminalFontSize"
    private static let sidebarPanelKey = "activeSidebarPanel"
    private static let sidebarWidthKey = "sidebarWidth"
    private var sessionObservations: [UUID: AnyCancellable] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private let focusMonitor = TerminalFocusMonitor()

    init(configStore: ConfigStore = ConfigStore()) {
        self.configStore = configStore
        let saved = UserDefaults.standard.double(forKey: Self.fontSizeKey)
        self.fontSize = saved > 0 ? CGFloat(saved) : AppFont.defaultSize

        // 没存过 = 首次启动：把主机面板先展开，不然新用户看不到从哪儿开始。
        if let stored = UserDefaults.standard.string(forKey: Self.sidebarPanelKey) {
            self.activeSidebar = SidebarPanel(rawValue: stored)
        } else {
            self.activeSidebar = .hosts
        }
        let storedWidth = UserDefaults.standard.double(forKey: Self.sidebarWidthKey)
        self.sidebarWidth = storedWidth > 0
            ? min(max(CGFloat(storedWidth), Self.minimumSidebarWidth), Self.maximumSidebarWidth)
            : Self.defaultSidebarWidth

        // 主机列表变化也要驱动界面重绘（视图只观察 AppState 一个对象）。
        configStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // 点某个分栏的终端 → 焦点跟过去。
        focusMonitor.start { [weak self] view in
            guard let self,
                  let session = self.sessions.first(where: { $0.terminalView === view }),
                  let tab = self.tab(containing: session.id),
                  // 隐藏的终端（别的 tab、或同一分栏里没被选中的小标签）本来点不到，
                  // 真被命中也忽略，别莫名切走。
                  tab.id == self.selectedTabID,
                  tab.root.group(containing: session.id)?.activeID == session.id
            else { return }
            self.focus(sessionID: session.id)
            session.takeKeyboardFocus()
        }
    }

    // MARK: - 查询

    func session(id: UUID) -> SSHSession? {
        sessions.first { $0.id == id }
    }

    var selectedTab: TerminalTab? {
        guard let selectedTabID else { return nil }
        return tabs.first { $0.id == selectedTabID }
    }

    /// 键盘焦点所在的会话 —— ⌘R / ⌘W / ⌘D 这些命令的作用对象。
    var focusedSession: SSHSession? {
        guard let tab = selectedTab else { return nil }
        return session(id: tab.focusedSessionID)
    }

    func tab(containing sessionID: UUID) -> TerminalTab? {
        tabs.first { $0.contains(sessionID: sessionID) }
    }

    /// 一个 tab 里所有分栏的会话，按视觉顺序。
    func sessions(in tab: TerminalTab) -> [SSHSession] {
        tab.sessionIDs.compactMap { session(id: $0) }
    }

    var windowTitle: String {
        guard let tab = selectedTab else { return "Moonterm" }
        return focusedSession?.remoteTitle ?? tab.title
    }

    // MARK: - 打开会话

    /// 打开一个新 tab，绑定这台主机。同一台主机可以开多个 tab。
    func open(host: HostConfig) {
        let session = makeSession(host: host)
        let tab = TerminalTab(host: host, sessionID: session.id)  // 这个会话就是「窗口1」
        tabs.append(tab)
        selectedTabID = tab.id
    }

    /// 在指定分栏旁边划一个新分栏（⌘D / ⇧⌘D）。用的是**本 tab 绑定的那台主机**。
    func split(from target: UUID, edge: PaneEdge) {
        guard let index = tabs.firstIndex(where: { $0.contains(sessionID: target) }) else { return }

        let session = makeSession(host: tabs[index].host)
        guard tabs[index].root.insert(sessionID: session.id, relativeTo: target, edge: edge) else {
            // 插不进去（理论上不会）：别把会话漏在树外面，收干净再退出。
            destroySession(session.id)
            return
        }
        tabs[index].assignWindowNumber(to: session.id)
        tabs[index].focusedSessionID = session.id
        selectedTabID = tabs[index].id
    }

    /// 在某个分栏里叠放一个新窗口（分栏标题栏上的 + 号）。同样用本 tab 的主机。
    func addWindow(toPaneOf anchor: UUID) {
        guard let index = tabs.firstIndex(where: { $0.contains(sessionID: anchor) }) else { return }

        let session = makeSession(host: tabs[index].host)
        guard tabs[index].root.join(sessionID: session.id, into: anchor, at: nil) else {
            destroySession(session.id)
            return
        }
        tabs[index].assignWindowNumber(to: session.id)
        tabs[index].focusedSessionID = session.id
        selectedTabID = tabs[index].id
    }

    private func makeSession(host: HostConfig) -> SSHSession {
        let session = SSHSession(
            config: host,
            password: configStore.password(for: host),
            fontSize: fontSize
        )
        // 会话内部状态变化要驱动 tab 条与子标题条重绘。
        sessionObservations[session.id] = session.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
        sessions.append(session)
        return session
    }

    // MARK: - 分栏布局
    //
    // 分栏只在**自己所在的 tab 内部**重新布局：tab 之间不合并，窗口也不跨 tab 搬。

    /// 拖分栏小标签：把一个窗口搬到同一 tab 里另一个分栏旁边（开出新分栏）。
    func movePane(sessionID: UUID, relativeTo target: UUID, edge: PaneEdge) {
        guard let index = tabs.firstIndex(where: { $0.contains(sessionID: sessionID) }),
              tabs[index].contains(sessionID: target)  // 跨 tab 不允许
        else { return }

        // 落点分栏是按「当前显示的会话」标识的。拖的正好是它自己时，换同组的别人当锚点，
        // 这样「把小标签拽出去单独成栏」才成立。
        var anchor = target
        if anchor == sessionID,
           let group = tabs[index].root.group(containing: sessionID),
           let other = group.sessionIDs.first(where: { $0 != sessionID }) {
            anchor = other
        }
        guard anchor != sessionID else { return }

        tabs[index].root.move(sessionID: sessionID, relativeTo: anchor, edge: edge)
        focus(sessionID: sessionID)
    }

    /// 并入同一 tab 里某个分栏的窗口组：落在分栏正中或它的小标签条上。
    func joinPane(sessionID: UUID, anchor: UUID, at index: Int?) {
        guard let tabIndex = tabs.firstIndex(where: { $0.contains(sessionID: sessionID) }),
              tabs[tabIndex].contains(sessionID: anchor)  // 跨 tab 不允许
        else { return }

        tabs[tabIndex].root.join(sessionID: sessionID, into: anchor, at: index)
        focus(sessionID: sessionID)
    }

    /// 点分栏上的小标签：切换这个分栏显示哪个会话。
    func activate(sessionID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.contains(sessionID: sessionID) }) else { return }
        tabs[index].root.activate(sessionID: sessionID)
        tabs[index].focusedSessionID = sessionID
        if selectedTabID != tabs[index].id {
            selectedTabID = tabs[index].id
        }
    }

    /// tab 条上拖动重排 —— tab 条上唯一的拖拽语义。`destination` 是「插到原列表第几项之前」。
    func moveTab(id: UUID, to destination: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(destination, 0), tabs.count)
        guard clamped != from, clamped != from + 1 else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: clamped > from ? clamped - 1 : clamped)
    }

    /// 拖分割线：整体替换某个 split 的占比。
    func setFractions(_ fractions: [CGFloat], splitID: UUID, tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].root.setFractions(fractions, forSplit: splitID)
    }

    // MARK: - 关闭

    /// ⌘W：关掉当前聚焦的那个终端。它是这个 tab 最后一个终端时，整个 tab 一起消失。
    func closeFocusedSession() {
        guard let tab = selectedTab else { return }
        closeSession(sessionID: tab.focusedSessionID)
    }

    func closeSession(sessionID: UUID) {
        destroySession(sessionID)
        detachFromTree(sessionID: sessionID)
    }

    /// 关掉整个 tab（连里面所有分栏）。
    func close(tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].sessionIDs.forEach { destroySession($0) }
        removeTab(at: index)
    }

    func closeOtherTabs(keeping tabID: UUID) {
        for tab in tabs where tab.id != tabID {
            tab.sessionIDs.forEach { destroySession($0) }
        }
        tabs.removeAll { $0.id != tabID }
        selectedTabID = tabID
    }

    /// 退出 App 前把所有 ssh 进程收干净。
    func terminateAll() {
        sessions.forEach { $0.close() }
        sessionObservations.removeAll()
        sessions.removeAll()
        tabs.removeAll()
        selectedTabID = nil
        sessionBeingRenamed = nil
    }

    func reconnectFocused() {
        focusedSession?.reconnect()
    }

    /// 终止会话并从注册表里移除（**不动**分栏树）。
    private func destroySession(_ sessionID: UUID) {
        endRenaming(sessionID: sessionID)
        session(id: sessionID)?.close()
        sessionObservations.removeValue(forKey: sessionID)
        sessions.removeAll { $0.id == sessionID }
    }

    /// 从分栏树里摘掉一个会话（**不**销毁会话本身）。整棵树只剩它时连 tab 一起删。
    @discardableResult
    private func detachFromTree(sessionID: UUID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.contains(sessionID: sessionID) }) else { return false }

        if tabs[index].sessionCount == 1 {
            removeTab(at: index)
            return true
        }

        let position = tabs[index].sessionIDs.firstIndex(of: sessionID) ?? 0
        guard tabs[index].root.remove(sessionID: sessionID) else { return false }
        // 编号还给这个 tab：下次新建窗口会补上这个空缺。
        tabs[index].releaseWindowNumber(of: sessionID)

        if tabs[index].focusedSessionID == sessionID {
            // 焦点跟着走到原位置的下一个分栏，没有就往前退一个。
            let remaining = tabs[index].sessionIDs
            let fallback = min(position, remaining.count - 1)
            if remaining.indices.contains(fallback) {
                tabs[index].focusedSessionID = remaining[fallback]
            }
        }
        return true
    }

    private func removeTab(at index: Int) {
        let removed = tabs.remove(at: index)
        guard selectedTabID == removed.id else { return }
        // 优先选右边那个，没有就选左边。
        let fallback = min(index, tabs.count - 1)
        selectedTabID = tabs.indices.contains(fallback) ? tabs[fallback].id : nil
    }

    // MARK: - tab 切换

    func selectNext() {
        moveSelection(by: 1)
    }

    func selectPrevious() {
        moveSelection(by: -1)
    }

    /// `⌘1`…`⌘9`，index 从 0 开始。
    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedTabID = tabs[index].id
    }

    private func moveSelection(by offset: Int) {
        guard !tabs.isEmpty else { return }
        guard let current = tabs.firstIndex(where: { $0.id == selectedTabID }) else {
            selectedTabID = tabs.first?.id
            return
        }
        let next = (current + offset + tabs.count) % tabs.count
        selectedTabID = tabs[next].id
    }

    // MARK: - 分栏焦点

    /// 点终端或点小标签时聚焦该会话（顺带让它所在分栏显示它）。
    func focus(sessionID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.contains(sessionID: sessionID) }) else { return }
        if tabs[index].root.group(containing: sessionID)?.activeID != sessionID {
            tabs[index].root.activate(sessionID: sessionID)
        }
        if tabs[index].focusedSessionID != sessionID {
            tabs[index].focusedSessionID = sessionID
        }
        if selectedTabID != tabs[index].id {
            selectedTabID = tabs[index].id
        }
    }

    /// ⌥⌘方向键：按几何位置找相邻分栏。比在树上走更符合眼睛看到的布局。
    func moveFocus(_ edge: PaneEdge) {
        guard let tab = selectedTab, tab.paneCount > 1,
              let current = drag.paneFrames[tab.focusedSessionID]
        else { return }

        // 只在「各分栏当前显示的会话」之间跳；同一分栏里的其他小标签不参与。
        let candidates: [(id: UUID, rect: CGRect)] = tab.activeSessionIDs.compactMap { id in
            guard id != tab.focusedSessionID, let rect = drag.paneFrames[id] else { return nil }
            guard Self.lies(rect, on: edge, of: current) else { return nil }
            return (id, rect)
        }

        // 主轴上离得最近、副轴上重叠最多的那个。
        let best = candidates.min { lhs, rhs in
            Self.focusScore(lhs.rect, from: current, edge: edge)
                < Self.focusScore(rhs.rect, from: current, edge: edge)
        }
        if let best {
            focus(sessionID: best.id)
            session(id: best.id)?.takeKeyboardFocus()
        }
    }

    private static func lies(_ rect: CGRect, on edge: PaneEdge, of current: CGRect) -> Bool {
        switch edge {
        case .leading: return rect.midX < current.midX
        case .trailing: return rect.midX > current.midX
        case .top: return rect.midY < current.midY
        case .bottom: return rect.midY > current.midY
        }
    }

    private static func focusScore(_ rect: CGRect, from current: CGRect, edge: PaneEdge) -> CGFloat {
        let gap: CGFloat
        let overlap: CGFloat
        switch edge {
        case .leading:
            gap = current.minX - rect.maxX
            overlap = overlapLength(current.minY, current.maxY, rect.minY, rect.maxY)
        case .trailing:
            gap = rect.minX - current.maxX
            overlap = overlapLength(current.minY, current.maxY, rect.minY, rect.maxY)
        case .top:
            gap = current.minY - rect.maxY
            overlap = overlapLength(current.minX, current.maxX, rect.minX, rect.maxX)
        case .bottom:
            gap = rect.minY - current.maxY
            overlap = overlapLength(current.minX, current.maxX, rect.minX, rect.maxX)
        }
        return abs(gap) - overlap
    }

    private static func overlapLength(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> CGFloat {
        max(0, min(a1, b1) - max(a0, b0))
    }

    // MARK: - 拖拽收尾

    /// 松手时把拖拽意图落到模型上。
    func completeDrag() {
        let state = drag.state
        drag.end()
        guard let state else { return }

        // 只有两种合法组合：tab 在 tab 条上重排，分栏在自己 tab 内部重新布局。
        // `DragController` 已经在落点判定时挡掉了其余组合，这里再兜一次。
        switch (state.payload, state.target) {
        case (.tab(let tabID), .tabBar(let index)):
            moveTab(id: tabID, to: index)

        case (.pane(let sessionID), .pane(let target, .edge(let edge))):
            movePane(sessionID: sessionID, relativeTo: target, edge: edge)

        case (.pane(let sessionID), .pane(let target, .center)):
            joinPane(sessionID: sessionID, anchor: target, at: nil)

        case (.pane(let sessionID), .paneHeader(let anchor, let index)):
            joinPane(sessionID: sessionID, anchor: anchor, at: index)

        default:
            break
        }
    }

    // MARK: - 分栏命令

    /// ⌘D / ⇧⌘D：在当前分栏旁边划一个新分栏，主机沿用本 tab 的，不再问。
    func splitFocused(_ edge: PaneEdge) {
        guard let tab = selectedTab else { return }
        split(from: tab.focusedSessionID, edge: edge)
    }

    /// 在当前分栏里叠放一个新窗口。
    func addWindowToFocusedPane() {
        guard let tab = selectedTab else { return }
        addWindow(toPaneOf: tab.focusedSessionID)
    }

    // MARK: - 重命名分栏

    /// 让某个分栏的小标签进入输入态。顺手把焦点挪过去，免得在看不见的分栏上改名。
    func beginRenaming(sessionID: UUID) {
        guard tabs.contains(where: { $0.contains(sessionID: sessionID) }) else { return }
        focus(sessionID: sessionID)
        sessionBeingRenamed = sessionID
    }

    /// 菜单里的「重命名分栏…」：改当前聚焦的那个。
    func beginRenamingFocusedSession() {
        guard let tab = selectedTab else { return }
        beginRenaming(sessionID: tab.focusedSessionID)
    }

    /// 提交新名字并收起输入框。空名字表示恢复默认的「窗口N」。
    func rename(sessionID: UUID, to name: String) {
        if let index = tabs.firstIndex(where: { $0.contains(sessionID: sessionID) }) {
            tabs[index].rename(sessionID: sessionID, to: name)
        }
        finishRenaming(sessionID: sessionID)
    }

    /// 放弃重命名（Esc）。
    func cancelRenaming(sessionID: UUID) {
        finishRenaming(sessionID: sessionID)
    }

    /// 输入框没了就得有人接住键盘焦点，否则输入既进不了终端也没处可去。
    private func finishRenaming(sessionID: UUID) {
        endRenaming(sessionID: sessionID)
        guard selectedTab?.focusedSessionID == sessionID else { return }
        // 等输入框先从视图层级里撤掉，再把 first responder 交回终端。
        DispatchQueue.main.async { [weak self] in
            self?.session(id: sessionID)?.takeKeyboardFocus()
        }
    }

    /// 强制收起输入框（会话被关掉时）。
    func endRenaming(sessionID: UUID) {
        guard sessionBeingRenamed == sessionID else { return }
        sessionBeingRenamed = nil
    }

    // MARK: - 字号

    func increaseFontSize() {
        fontSize = min(fontSize + 1, AppFont.maximumSize)
    }

    func decreaseFontSize() {
        fontSize = max(fontSize - 1, AppFont.minimumSize)
    }

    func resetFontSize() {
        fontSize = AppFont.defaultSize
    }

    // MARK: - 左侧竖栏

    /// 点竖栏上的图标：已经展开的那个再点一下就收起。
    func toggleSidebar(_ panel: SidebarPanel) {
        activeSidebar = activeSidebar == panel ? nil : panel
    }

    /// 需要选主机时（⌘T / 关掉最后一个 tab 之后）把主机面板露出来。
    func revealHosts() {
        activeSidebar = .hosts
    }

    /// 拖面板右边缘。宽度夹在上下限之间：太窄看不清主机名，太宽把终端挤没了。
    func setSidebarWidth(_ width: CGFloat) {
        sidebarWidth = min(max(width.rounded(), Self.minimumSidebarWidth), Self.maximumSidebarWidth)
    }

    // MARK: - 主机编辑

    /// 新建主机。`group` 是预选的分组（从分组的右键菜单进来时用），nil = 未分组。
    func beginCreatingHost(inGroup group: UUID? = nil) {
        hostBeingEdited = HostConfig(groupID: group)
    }

    func beginEditing(host: HostConfig) {
        hostBeingEdited = host
    }
}
