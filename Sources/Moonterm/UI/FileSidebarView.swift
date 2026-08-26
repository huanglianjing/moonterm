import AppKit
import MoontermCore
import SwiftUI
import UniformTypeIdentifiers

/// 竖栏「文件」图标展开的面板：当前 tab 那台主机的远端文件树，能上传下载。
///
/// 树根是**当前目录**而不是 `/`（侧栏窄，从根缩进十几级之后名字就没地方了），往上走靠顶部面包屑。
/// 单击选中、双击目录展开；双击文件只是选中 —— 5 GB 的文件不该因为手抖多点了一下就开始传。
///
/// 所有远端操作都复用当前分栏那条 ssh 连接的 ControlMaster socket，所以面板本身不碰密码。
struct FileSidebarView: View {

    @EnvironmentObject private var appState: AppState

    /// 只负责挑出当前 tab 的浏览状态。真正画面板的是 `FilePanel` ——
    /// 它把 browser 收成 `@ObservedObject`，不然列完目录界面不会重绘。
    var body: some View {
        if let tab = appState.selectedTab {
            FilePanel(browser: appState.fileBrowser(for: tab), tab: tab)
        } else {
            NoConnectionPanel()
        }
    }
}

/// 有 tab 时的文件面板。
private struct FilePanel: View {

    @EnvironmentObject private var appState: AppState
    @ObservedObject var browser: RemoteFileBrowser
    let tab: TerminalTab

    /// 标题栏那个 `…` 上有没有鼠标。`Menu` 自己不给悬停状态，只能自己接（和主机面板的 `+` 一样）。
    @State private var isOptionsHovering = false
    /// 新建目录与重命名共用一个小输入框；nil 表示没在输入。
    @State private var nameRequest: FileNameRequest?
    /// 待确认删除的条目。单独使用新版 alert builder，才能显式指定 Enter / Esc 的按钮语义。
    @State private var deletionConfirmation: RemoteFileEntry?
    @State private var operationError: String?
    /// 本地文件正悬在整棵树上；没有更具体的行落点时，实际上传到当前树根。
    @State private var isRootFileDropTargeted = false
    /// 必须按具体行追踪：相邻普通文件会映射到同一个父目录，旧行的延迟离开事件不能清掉新行的高亮。
    @State private var rowDropTargets = FileDropTargetTracker()
    /// 每点一次文件行就递增；AppKit 键盘接收层据此重新拿回第一响应者，点终端后则自然把焦点让回终端。
    @State private var fileKeyboardFocusRequest = 0
    /// 展开时传输区的高度；收起不改它，下次展开回到用户拖出的尺寸。
    @State private var transferHeight: CGFloat = 120
    @State private var isTransferCollapsed = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ChromeHairline()
            content
        }
        .frame(maxHeight: .infinity)
        .background(ChromeStyle.sidebar)
        .background(
            FilePanelKeyboardCatcher(focusRequest: fileKeyboardFocusRequest) {
                requestSelectionDeletion()
            }
            .frame(width: 0, height: 0)
        )
        .background(
            DeletionConfirmationKeyboardMonitor(
                isActive: deletionConfirmation != nil,
                onConfirm: {
                    guard let entry = deletionConfirmation else { return }
                    confirmDeletion(entry)
                },
                onCancel: {
                    deletionConfirmation = nil
                }
            )
            .frame(width: 0, height: 0)
        )
        .sheet(item: $nameRequest) { request in
            FileNameEditor(
                title: request.title,
                initialName: request.initialName,
                actionTitle: request.actionTitle
            ) { name in
                perform(request, name: name)
            }
        }
        .alert(
            deletionConfirmation.map { "删除「\($0.name)」？" } ?? "确认删除",
            isPresented: deletionConfirmationIsPresented,
            presenting: deletionConfirmation
        ) { entry in
            Button("取消", role: .cancel) {
                deletionConfirmation = nil
            }
            .keyboardShortcut(.cancelAction)

            Button("删除", role: .destructive) {
                confirmDeletion(entry)
            }
        }
        .alert("文件操作失败", isPresented: operationErrorIsPresented) {
            Button("好", role: .cancel) { operationError = nil }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(operationError ?? "操作失败")
        }
    }

    // MARK: - 标题栏

    private var header: some View {
        HStack(spacing: 2) {
            Text(SidebarPanel.files.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            if browser.isMutating {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.65)
                    .frame(width: 18, height: 18)
                    .help("正在执行文件操作…")
            }

            ChromeIconButton(systemName: "scope", side: 22, iconSize: 11) {
                browser.locate()
            }
            .help("定位到终端当前目录")

            ChromeIconButton(systemName: "arrow.clockwise", side: 22, iconSize: 11) {
                browser.refresh()
            }
            .help("刷新")

            ChromeIconButton(systemName: "arrow.up.doc", side: 22, iconSize: 11) {
                chooseFilesToUpload(browser: browser)
            }
            .help("上传到 \(browser.uploadDestination())")

            Menu {
                Toggle("显示隐藏文件", isOn: Binding(
                    get: { browser.showsHidden },
                    set: { browser.showsHidden = $0 }
                ))
                Toggle("跟随终端目录", isOn: Binding(
                    get: { browser.followsTerminal },
                    set: {
                        browser.followsTerminal = $0
                        // 刚打开就立刻跟过去，不用等下一次 cd。
                        if $0 { browser.locate() }
                    }
                ))
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .bold))
                    .chromeIconCell(side: 22, hovering: isOptionsHovering)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22, height: 22)
            .onHover { isOptionsHovering = $0 }
            .help("显示选项")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 28)
    }

    // MARK: - 主体

    @ViewBuilder
    private var content: some View {
        let session = appState.session(id: tab.focusedSessionID)

        VStack(spacing: 0) {
            breadcrumb(browser: browser)
            ChromeHairline()

            if let message = browser.connectionError, browser.children[browser.rootPath] == nil {
                // 一棵树都还没列出来的时候，错误就是这块面板的全部内容。
                notice(message)
            } else {
                tree(browser: browser)
            }

            if !browser.transfers.isEmpty {
                TransferResizeHandle(
                    height: $transferHeight,
                    isCollapsed: $isTransferCollapsed
                )
                TransferList(browser: browser, isCollapsed: $isTransferCollapsed)
                    .frame(height: isTransferCollapsed ? 20 : transferHeight)
            }
        }
        // 面板一露头就接上当前分栏、问家目录、定位过去。
        .onAppear {
            browser.bind(session: session)
            browser.activate()
        }
        // 切分栏 / 切 tab：换发命令用的那条连接（socket 是每会话一份的），树不动。
        .onChange(of: tab.focusedSessionID) { _ in
            browser.bind(session: appState.session(id: tab.focusedSessionID))
            browser.activate()
        }
        // 连上的那一刻再试一次：面板可能是在连接完成之前就打开的。
        .onChange(of: session?.state) { _ in
            browser.activate()
        }
        // 远端 cd 了。两条线索（OSC 7 与 xterm 标题）都可能变，各接一次。
        .onChange(of: session?.osc7Directory) { _ in
            browser.terminalDirectoryChanged()
        }
        .onChange(of: session?.remoteTitle) { _ in
            browser.terminalDirectoryChanged()
        }
    }

    /// 面包屑：从 `/` 到当前目录，点哪一段就把树根挪到那儿。
    private func breadcrumb(browser: RemoteFileBrowser) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(browser.breadcrumb.enumerated()), id: \.offset) { index, path in
                    // 第一段本身就叫 `/`，紧跟它的那一段不再补分隔符，否则读出来是「/ / Users」。
                    if index > 1 {
                        Text("/")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }

                    BreadcrumbSegment(
                        title: RemotePath.name(of: path),
                        isCurrent: path == browser.rootPath,
                        isDropTarget: path == browser.rootPath && highlightedDropDirectory == browser.rootPath
                    ) {
                        browser.navigate(to: path)
                    }
                    .contextMenu {
                        Button("新建文件夹…") {
                            nameRequest = .createDirectory(in: path)
                        }
                        .disabled(browser.isMutating)
                    }
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
        }
        .frame(height: 22)
        .help(browser.rootPath)
    }

    /// 树本身。行是自己画的（不是 `DisclosureGroup`）—— 缩进、点击语义、悬停高亮都要和主机面板一致。
    private func tree(browser: RemoteFileBrowser) -> some View {
        let visibleRows = rows(of: browser.rootPath, depth: 0, browser: browser)

        return GeometryReader { proxy in
            ScrollView {
                // 行间不能留布局缝隙：外层滚动区也是根目录的落点，拖在一像素缝里就会被误判成传到根目录。
                LazyVStack(spacing: 0) {
                ForEach(visibleRows, id: \.entry.path) { row in
                    FileRow(
                        entry: row.entry,
                        depth: row.depth,
                        isSelected: browser.selection == row.entry.path,
                        isExpanded: browser.isExpanded(row.entry.path),
                        isLoading: browser.loading.contains(row.entry.path),
                        error: browser.errors[row.entry.path],
                        isDropDestination: highlightedDropDirectory == row.entry.path,
                        onClick: { clickCount in
                            browser.selection = row.entry.path
                            fileKeyboardFocusRequest &+= 1
                            // 第一下只选中，第二下才切换。ClickCatcher 在 mouseDown 就回调，
                            // 所以若让第一下切换，鼠标还没松开目录就会自己展开或收起。
                            // 文件不管点几下都只是选中：5 GB 的文件不该因为手抖多点一下就开始传。
                            if clickCount == 2, row.entry.isExpandable {
                                browser.toggle(row.entry.path)
                            }
                        },
                        onToggle: {
                            browser.toggle(row.entry.path)
                        },
                        onUpload: { localURLs in
                            browser.selection = nil
                            rowDropTargets.clear()
                            browser.upload(localURLs, to: uploadDestination(for: row.entry))
                        },
                        onDropTargetChanged: { isTargeted in
                            updateRowDropDestination(
                                rowPath: row.entry.path,
                                uploadDestination(for: row.entry),
                                isTargeted: isTargeted
                            )
                        }
                    )
                    .contextMenu { menu(for: row.entry, browser: browser) }
                }

                if browser.loading.contains(browser.rootPath) {
                    loadingRow
                } else if visibleRows.isEmpty {
                    Text(browser.children[browser.rootPath] == nil ? "还没有列出内容" : "空目录")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }

                if let message = browser.errors[browser.rootPath] {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                }
                }
                .padding(.horizontal, 4)
                // 先让内容至少填满可视高度，再补上下边距；后台命中层于是能覆盖最后一行下面的全部空白。
                .frame(minHeight: max(0, proxy.size.height - 8), alignment: .top)
                .padding(.vertical, 4)
                .background(
                    Color.clear
                        .contentShape(Rectangle())
                        .onLeftClick { _, _ in browser.selection = nil }
                )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .fileDropDestination(isTargeted: $isRootFileDropTargeted) { localURLs in
                browser.selection = nil
                rowDropTargets.clear()
                browser.upload(localURLs, to: browser.rootPath)
            }
            .onChange(of: isRootFileDropTargeted) { isTargeted in
                if isTargeted { browser.selection = nil }
            }
        }
    }

    /// 最具体的行落点优先于树本身。外层 `ScrollView` 也会在行上方变成可接收状态，不能让它
    /// 抢走子目录的高亮；行离开后才退回当前树根。
    private var highlightedDropDirectory: String? {
        rowDropTargets.destination ?? (isRootFileDropTargeted ? browser.rootPath : nil)
    }

    private func uploadDestination(for entry: RemoteFileEntry) -> String {
        entry.kind == .directory ? entry.path : RemotePath.parent(of: entry.path)
    }

    private func updateRowDropDestination(rowPath: String, _ directory: String, isTargeted: Bool) {
        if isTargeted { browser.selection = nil }
        rowDropTargets.setTarget(
            rowPath: rowPath,
            destination: directory,
            isTargeted: isTargeted
        )
    }

    private func requestSelectionDeletion() {
        guard deletionConfirmation == nil,
              operationError == nil,
              !browser.isMutating,
              let selection = browser.selection,
              let entry = browser.entry(at: selection)
        else { return }
        deletionConfirmation = entry
    }

    private func confirmDeletion(_ entry: RemoteFileEntry) {
        deletionConfirmation = nil
        browser.delete(entry) { error in
            if let error { operationError = error }
        }
    }

    private var deletionConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { deletionConfirmation != nil },
            set: { if !$0 { deletionConfirmation = nil } }
        )
    }

    private var operationErrorIsPresented: Binding<Bool> {
        Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )
    }

    private var loadingRow: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("正在列目录…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    /// 把树摊平成一列行。只铺开展开着的那几支，收起来的子树不算。
    private func rows(
        of directory: String,
        depth: Int,
        browser: RemoteFileBrowser
    ) -> [(entry: RemoteFileEntry, depth: Int)] {
        var result: [(entry: RemoteFileEntry, depth: Int)] = []
        for entry in browser.visibleChildren(of: directory) {
            result.append((entry, depth))
            guard entry.isExpandable, browser.isExpanded(entry.path) else { continue }
            result.append(contentsOf: rows(of: entry.path, depth: depth + 1, browser: browser))
        }
        return result
    }

    private func notice(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.secondary)

            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 右键菜单

    @ViewBuilder
    private func menu(for entry: RemoteFileEntry, browser: RemoteFileBrowser) -> some View {
        if entry.isExpandable {
            Button(browser.isExpanded(entry.path) ? "折叠" : "展开") { browser.toggle(entry.path) }
            Button("作为根目录打开") { browser.navigate(to: entry.path) }
            Divider()
        }

        Button(entry.kind == .directory ? "下载整个文件夹…" : "下载…") {
            chooseDownloadTarget(for: entry, browser: browser)
        }

        if entry.kind == .directory {
            Button("上传到这里…") {
                chooseFilesToUpload(browser: browser, destination: entry.path)
            }
        }

        Divider()

        if entry.kind == .directory {
            Button("新建文件夹…") {
                nameRequest = .createDirectory(in: entry.path)
            }
            .disabled(browser.isMutating)
        }

        Button("重命名…") {
            nameRequest = .rename(entry)
        }
        .disabled(browser.isMutating)

        Button("删除…", role: .destructive) {
            deletionConfirmation = entry
        }
        .disabled(browser.isMutating)

        Divider()

        Button("复制路径") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.path, forType: .string)
        }
    }

    private func perform(_ request: FileNameRequest, name: String) {
        let completion: (String?) -> Void = { error in
            if let error { operationError = error }
        }
        switch request.action {
        case .createDirectory(let parent):
            browser.createDirectory(in: parent, name: name, completion: completion)
        case .rename(let entry):
            browser.rename(entry, to: name, completion: completion)
        }
    }

    // MARK: - 文件对话框
    //
    // `NSSavePanel` / `NSOpenPanel` 直接用 AppKit 的：SwiftUI 的 `.fileImporter` 在这个
    // 「一个按钮 + 一堆右键菜单项都要能弹」的场景里，得为每个入口各挂一个绑定状态，反而更绕。

    private func chooseDownloadTarget(for entry: RemoteFileEntry, browser: RemoteFileBrowser) {
        if entry.kind == .directory {
            // 文件夹选「放到哪个目录里」，落点是 <选中的目录>/<文件夹名>。
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "下载到这里"
            panel.message = "选一个本地目录，\(entry.name) 会放进去"
            guard panel.runModal() == .OK, let directory = panel.url else { return }
            browser.download(entry, to: directory.appendingPathComponent(entry.name))
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = entry.name
            panel.canCreateDirectories = true
            panel.prompt = "下载"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            browser.download(entry, to: url)
        }
    }

    private func chooseFilesToUpload(browser: RemoteFileBrowser, destination: String? = nil) {
        let target = destination ?? browser.uploadDestination()
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "上传"
        panel.message = "上传到 \(target)"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        browser.upload(panel.urls, to: target)
    }
}

// MARK: - 文件操作输入与确认

private struct FileNameRequest: Identifiable {

    enum Action {
        case createDirectory(parent: String)
        case rename(RemoteFileEntry)
    }

    let id = UUID()
    let action: Action

    static func createDirectory(in parent: String) -> FileNameRequest {
        FileNameRequest(action: .createDirectory(parent: parent))
    }

    static func rename(_ entry: RemoteFileEntry) -> FileNameRequest {
        FileNameRequest(action: .rename(entry))
    }

    var title: String {
        switch action {
        case .createDirectory: return "新建文件夹"
        case .rename: return "重命名"
        }
    }

    var initialName: String {
        if case .rename(let entry) = action { return entry.name }
        return ""
    }

    var actionTitle: String {
        switch action {
        case .createDirectory: return "新建"
        case .rename: return "重命名"
        }
    }
}

private struct FileNameEditor: View {

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @FocusState private var isFocused: Bool

    let title: String
    let initialName: String
    let actionTitle: String
    let onCommit: (String) -> Void

    init(
        title: String,
        initialName: String,
        actionTitle: String,
        onCommit: @escaping (String) -> Void
    ) {
        self.title = title
        self.initialName = initialName
        self.actionTitle = actionTitle
        self.onCommit = onCommit
        _draft = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            TextField("名称", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(commit)

            if let validationMessage {
                Text(validationMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle, action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCommit)
            }
        }
        .padding(18)
        .frame(width: 360)
        .onAppear { isFocused = true }
    }

    private var canCommit: Bool {
        RemotePath.isValidName(draft) && draft != initialName
    }

    private var validationMessage: String? {
        if draft.isEmpty { return "名称不能为空。" }
        if draft == "." || draft == ".." { return "名称不能是 . 或 ..。" }
        if draft.contains("/") { return "名称不能包含 /。" }
        if draft.contains("\0") { return "名称不能包含 NUL 字符。" }
        return nil
    }

    private func commit() {
        guard canCommit else { return }
        let name = draft
        dismiss()
        onCommit(name)
    }
}

// MARK: - 没有连接时

/// 一个 tab 都没有时的面板。文件树是跟着 tab（主机）走的，没 tab 就没什么可列。
private struct NoConnectionPanel: View {

    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(SidebarPanel.files.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)

            ChromeHairline()

            VStack(spacing: 8) {
                Text("没有打开的连接")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Text("在主机面板里双击一台主机，这里会显示它的文件")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)

                Button("打开主机面板") { appState.revealHosts() }
                    .controlSize(.small)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
        .background(ChromeStyle.sidebar)
    }
}

// MARK: - 面包屑的一段

private struct BreadcrumbSegment: View {

    let title: String
    let isCurrent: Bool
    /// 文件正要上传到这段代表的当前树根；只在实际落点是树根时为 true。
    let isDropTarget: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                .lineLimit(1)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isDropTarget ? ChromeStyle.accent.opacity(0.26) : (isHovering ? ChromeStyle.hover : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - 树里的一行

/// 一个文件或目录。
///
/// 点击走 `ClickCatcher`（`onLeftClick`）而不是 `onTapGesture`：要区分单击与双击，
/// 而 `onTapGesture(count:)` 在同一个视图上挂两次会互相吞掉。
private struct FileRow: View {

    let entry: RemoteFileEntry
    /// 缩进层级，树根的直接子项是 0。
    let depth: Int
    let isSelected: Bool
    let isExpanded: Bool
    let isLoading: Bool
    let error: String?
    /// 这行是本次拖放真正会写入的目录。普通文件行的实际落点在它的父目录，所以它自己不会高亮。
    let isDropDestination: Bool
    let onClick: (Int) -> Void
    let onToggle: () -> Void
    /// 接收本地文件 URL。目录行传到自身，普通文件行传到它所在的目录。
    let onUpload: ([URL]) -> Void
    /// 行的 AppKit 落点状态变化。父视图据此高亮实际上传到的目录，而不是鼠标下的普通文件。
    let onDropTargetChanged: (Bool) -> Void

    @State private var isHovering = false
    /// Finder 拖进来的文件正悬在这个可上传的行上。单独留状态，不能借用普通悬停——拖拽时未必会有 mouseMoved。
    @State private var isFileDropTargeted = false

    var body: some View {
        HStack(spacing: 4) {
            chevron

            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(entry.kind == .directory ? ChromeStyle.accent : Color.secondary)
                    .frame(width: 12)

                Text(entry.name)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                } else if error != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                } else if let size = entry.displaySize {
                    Text(size)
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .onLeftClick { clickCount, _ in onClick(clickCount) }
        }
        // 一级缩进 10 点：侧栏最窄 160 点，缩得再多几级之后名字就没地方了。
        .padding(.leading, 4 + CGFloat(depth) * 10)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(
                    isDropDestination
                        ? ChromeStyle.accent.opacity(0.26)
                        : (isSelected ? ChromeStyle.selectedRow : (isHovering ? ChromeStyle.hover : .clear))
                )
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onChange(of: isFileDropTargeted) { isTargeted in
            onDropTargetChanged(isTargeted)
        }
        .onDisappear {
            // LazyVStack 可能在拖动滚动时回收屏幕外的行；若它当时仍是落点，主动补一条离开事件。
            if isFileDropTargeted { onDropTargetChanged(false) }
        }
        .fileDropDestination(
            isTargeted: $isFileDropTargeted,
            onDropFiles: onUpload
        )
        .help(helpText)
    }

    /// 箭头有独立的点击区域；行主体的点击层只盖住右边内容，两个 AppKit 命中区不会互相抢事件。
    @ViewBuilder
    private var chevron: some View {
        if entry.isExpandable {
            Button(action: onToggle) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Spacer().frame(width: 10)
        }
    }

    private var icon: String {
        switch entry.kind {
        case .directory: return isExpanded ? "folder.fill" : "folder"
        case .symlink: return "arrowshape.turn.up.left"
        case .file: return "doc"
        }
    }

    private var helpText: String {
        var parts = [entry.path, entry.modeText, entry.dateText]
        if let size = entry.displaySize { parts.append(size) }
        if let error { parts.append(error) }
        return parts.joined(separator: "\n")
    }
}

/// 给已有内容直接加落点。不能用透明 overlay：它会抢走 `ClickCatcher` 的点击命中，目录原有的
/// 单击选中、双击展开就会失效。
private struct FileDropDestination: ViewModifier {

    @Binding var isTargeted: Bool
    let onDropFiles: ([URL]) -> Void

    func body(content: Content) -> some View {
        content.onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            receiveDroppedFiles(from: providers)
        }
    }

    /// 用 SwiftUI 的文件 URL 落点接 Finder / 其他 macOS App 的外部拖拽；接到以后仍交给
    /// `RemoteFileBrowser.upload`，这样并发上限、取消、完成后刷新都和工具栏上传完全一致。
    private func receiveDroppedFiles(from providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }

        // `loadObject` 的回调不保证在同一线程；保留 Finder 给出的顺序，等所有 URL 都取到后再一次入队。
        let lock = NSLock()
        var urls = Array<URL?>(repeating: nil, count: fileProviders.count)
        let group = DispatchGroup()

        for (index, provider) in fileProviders.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL {
                    lock.lock()
                    urls[index] = url
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            lock.lock()
            let localURLs = urls.compactMap { $0 }
            lock.unlock()
            guard !localURLs.isEmpty else { return }
            onDropFiles(localURLs)
        }
        return true
    }
}

private extension View {

    func fileDropDestination(
        isTargeted: Binding<Bool>,
        onDropFiles: @escaping ([URL]) -> Void
    ) -> some View {
        modifier(FileDropDestination(isTargeted: isTargeted, onDropFiles: onDropFiles))
    }
}

// MARK: - 文件面板键盘焦点

/// 文件行用 AppKit 接点击，本身不会像 `TextField` 那样自动成为第一响应者。这个零尺寸视图只在
/// 用户点选文件行后主动拿一次焦点，于是 Delete / Backspace 能删远端条目；点回终端时终端照常
/// 成为第一响应者，删除键不会误删仍留着选中色的远端文件。
private struct FilePanelKeyboardCatcher: NSViewRepresentable {

    let focusRequest: Int
    let onDelete: () -> Void

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.lastFocusRequest = focusRequest
        view.onDelete = onDelete
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.onDelete = onDelete
        guard nsView.lastFocusRequest != focusRequest else { return }
        nsView.lastFocusRequest = focusRequest

        // SwiftUI 更新时视图可能还没挂进 window，下一轮 runloop 再拿焦点才稳定。
        DispatchQueue.main.async { [weak nsView] in
            guard let nsView, let window = nsView.window else { return }
            window.makeFirstResponder(nsView)
        }
    }

    final class KeyView: NSView {

        var lastFocusRequest = 0
        var onDelete: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            // 51 是键盘上的 Delete（向后删），117 是 Forward Delete。Fn+Delete 会带 `.function`，
            // 只排除会改变命令语义的四种常规修饰键。
            let disallowedModifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard disallowedModifiers.isEmpty, event.keyCode == 51 || event.keyCode == 117 else {
                super.keyDown(with: event)
                return
            }
            onDelete?()
        }
    }
}

// MARK: - 删除确认快捷键

/// 给删除确认框保留 Return / Enter 和 Esc，但不把破坏性按钮标成系统默认按钮；后者会让按钮
/// 在弹框刚出现时显示成蓝色，只有按下后才短暂露出破坏性操作应有的红色。
private struct DeletionConfirmationKeyboardMonitor: NSViewRepresentable {

    let isActive: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        update(nsView)
    }

    private func update(_ view: MonitorView) {
        view.isActive = isActive
        view.onConfirm = onConfirm
        view.onCancel = onCancel
    }

    final class MonitorView: NSView {

        var isActive = false
        var onConfirm: (() -> Void)?
        var onCancel: (() -> Void)?

        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                stopMonitoring()
            } else {
                startMonitoring()
            }
        }

        private func startMonitoring() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isActive else { return event }

                let disallowedModifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
                guard disallowedModifiers.isEmpty else { return event }

                switch event.keyCode {
                case 36, 76: // Return、数字键盘 Enter
                    self.isActive = false
                    self.onConfirm?()
                    return nil
                case 53: // Esc
                    self.isActive = false
                    self.onCancel?()
                    return nil
                default:
                    return event
                }
            }
        }

        private func stopMonitoring() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        deinit {
            stopMonitoring()
        }
    }
}

// MARK: - 传输区

/// 传输区上边缘：向上拖会变高，向下拖会变矮。用全局位移是因为边缘自己会随高度移动，
/// 若拿局部坐标累计，手柄会一边移动一边改变下一帧的输入。
private struct TransferResizeHandle: View {

    @Binding var height: CGFloat
    @Binding var isCollapsed: Bool

    @State private var baseHeight: CGFloat?
    @State private var isHovering = false

    private static let minimumHeight: CGFloat = 64
    private static let maximumHeight: CGFloat = 300

    var body: some View {
        Rectangle()
            .fill(isHovering ? ChromeStyle.dividerHovered : ChromeStyle.divider)
            .frame(height: 4)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            // 点「清除」可能让整块传输区在鼠标还压着手柄时消失，游标栈也要成对收回。
            .onDisappear {
                if isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if isCollapsed { isCollapsed = false }
                        let start = baseHeight ?? height
                        baseHeight = start
                        height = min(
                            max(start - value.translation.height, Self.minimumHeight),
                            Self.maximumHeight
                        )
                    }
                    .onEnded { _ in baseHeight = nil }
            )
    }
}

/// 面板底部那一小块：正在传和刚传完的条目。
///
/// 下载有百分比（拿本地文件当前多大除以远端说它多大算出来的），上传只能显示「传输中」——
/// sftp 的进度条只在 stdout 是 tty 时才输出，批处理模式下一个字都没有。
private struct TransferList: View {

    @ObservedObject var browser: RemoteFileBrowser
    @Binding var isCollapsed: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    isCollapsed.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                        Text("传输")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isCollapsed ? "展开传输区" : "收起传输区")

                Spacer(minLength: 0)

                if browser.hasFinishedTransfers {
                    Button("清除") { browser.clearFinishedTransfers() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 20)

            if !isCollapsed {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(browser.transfers) { transfer in
                            TransferRow(transfer: transfer) { browser.cancel(transfer.id) }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
            }
        }
        .background(ChromeStyle.paneHeader)
    }
}

private struct TransferRow: View {

    let transfer: RemoteFileBrowser.Transfer
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: transfer.direction == .download ? "arrow.down" : "arrow.up")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(iconColor)

                Text(transfer.name)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 2)

                Text(statusText)
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.tertiary)

                if !transfer.isDone {
                    ChromeIconButton(systemName: "xmark", side: 14, iconSize: 7, cornerRadius: 3) {
                        onCancel()
                    }
                    .help("取消")
                }
            }

            if !transfer.isDone {
                // 有百分比就画确定的条，没有（上传、目录）就画来回跑的那种。
                if let fraction = transfer.fraction {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.04))
        )
        .help(helpText)
    }

    private var iconColor: Color {
        switch transfer.state {
        case .failed: return .orange
        case .finished: return .green
        case .queued, .running: return .secondary
        }
    }

    private var statusText: String {
        switch transfer.state {
        case .queued: return "排队中"
        case .running:
            if let fraction = transfer.fraction {
                return "\(Int(fraction * 100))%"
            }
            return "传输中"
        case .finished:
            return transfer.totalBytes.map { RemoteFileEntry.formatBytes($0) } ?? "完成"
        case .failed:
            return "失败"
        }
    }

    private var helpText: String {
        if case .failed(let reason) = transfer.state { return "\(transfer.name)\n\(reason)" }
        return transfer.name
    }
}
