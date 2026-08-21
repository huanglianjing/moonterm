import AppKit
import Combine
import Foundation
import MoontermCore

/// 全局状态：打开的会话（tab）、当前选中项、字号，以及弹窗的开关。
final class AppState: ObservableObject {

    let configStore: ConfigStore

    /// 打开的会话，顺序即 tab 顺序。
    @Published private(set) var sessions: [SSHSession] = []
    @Published var selectedSessionID: UUID?

    /// 终端字号，持久化在 UserDefaults。
    @Published var fontSize: CGFloat {
        didSet {
            UserDefaults.standard.set(Double(fontSize), forKey: Self.fontSizeKey)
            sessions.forEach { $0.applyFontSize(fontSize) }
        }
    }

    /// 主机管理面板。
    @Published var isHostManagerPresented = false
    /// 正在编辑的主机（nil 表示没在编辑）。
    @Published var hostBeingEdited: HostConfig?
    /// 新建连接的选择器（tab 条上的 + 号）。
    @Published var isHostPickerPresented = false

    private static let fontSizeKey = "terminalFontSize"
    private var sessionObservations: [UUID: AnyCancellable] = [:]
    private var cancellables: Set<AnyCancellable> = []

    init(configStore: ConfigStore = ConfigStore()) {
        self.configStore = configStore
        let saved = UserDefaults.standard.double(forKey: Self.fontSizeKey)
        self.fontSize = saved > 0 ? CGFloat(saved) : AppFont.defaultSize

        // 主机列表变化也要驱动界面重绘（视图只观察 AppState 一个对象）。
        configStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - 查询

    var selectedSession: SSHSession? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    var windowTitle: String {
        guard let session = selectedSession else { return "Moonterm" }
        return session.remoteTitle ?? session.tabTitle
    }

    // MARK: - 会话开关

    /// 打开一个新 tab。同一台主机可以开多个。
    func open(host: HostConfig) {
        let session = SSHSession(
            config: host,
            password: configStore.password(for: host),
            fontSize: fontSize
        )
        // 会话内部状态变化要驱动 tab 条重绘。
        sessionObservations[session.id] = session.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }

        sessions.append(session)
        selectedSessionID = session.id
    }

    func close(sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].close()
        sessionObservations.removeValue(forKey: sessionID)
        sessions.remove(at: index)

        if selectedSessionID == sessionID {
            // 优先选右边那个，没有就选左边。
            let fallbackIndex = min(index, sessions.count - 1)
            selectedSessionID = sessions.indices.contains(fallbackIndex) ? sessions[fallbackIndex].id : nil
        }
    }

    func closeSelected() {
        guard let selectedSessionID else { return }
        close(sessionID: selectedSessionID)
    }

    func closeOthers(keeping sessionID: UUID) {
        for session in sessions where session.id != sessionID {
            session.close()
            sessionObservations.removeValue(forKey: session.id)
        }
        sessions.removeAll { $0.id != sessionID }
        selectedSessionID = sessionID
    }

    /// 退出 App 前把所有 ssh 进程收干净。
    func terminateAll() {
        sessions.forEach { $0.close() }
        sessionObservations.removeAll()
        sessions.removeAll()
        selectedSessionID = nil
    }

    func reconnectSelected() {
        selectedSession?.reconnect()
    }

    // MARK: - tab 切换

    func selectNext() {
        move(by: 1)
    }

    func selectPrevious() {
        move(by: -1)
    }

    /// `⌘1`…`⌘9`，index 从 0 开始。
    func select(index: Int) {
        guard sessions.indices.contains(index) else { return }
        selectedSessionID = sessions[index].id
    }

    private func move(by offset: Int) {
        guard !sessions.isEmpty else { return }
        guard let current = sessions.firstIndex(where: { $0.id == selectedSessionID }) else {
            selectedSessionID = sessions.first?.id
            return
        }
        let next = (current + offset + sessions.count) % sessions.count
        selectedSessionID = sessions[next].id
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

    // MARK: - 主机编辑

    func beginCreatingHost() {
        hostBeingEdited = HostConfig()
    }

    func beginEditing(host: HostConfig) {
        hostBeingEdited = host
    }
}
