import AppKit
import MoontermCore
import SwiftUI

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
    /// 删除确认和异步操作错误共用一条 alert 通道，避免同一视图上多个 alert 互相覆盖。
    @State private var panelAlert: FilePanelAlert?

    var body: some View {
        VStack(spacing: 0) {
            header
            ChromeHairline()
            content
        }
        .frame(maxHeight: .infinity)
        .background(ChromeStyle.sidebar)
        .sheet(item: $nameRequest) { request in
            FileNameEditor(
                title: request.title,
                initialName: request.initialName,
                actionTitle: request.actionTitle
            ) { name in
                perform(request, name: name)
            }
        }
        .alert(item: $panelAlert) { item in
            switch item.kind {
            case .confirmDeletion(let entry):
                return Alert(
                    title: Text("删除「\(entry.name)」？"),
                    primaryButton: .destructive(Text("删除")) {
                        browser.delete(entry) { error in
                            if let error { panelAlert = FilePanelAlert(.error(error)) }
                        }
                    },
                    secondaryButton: .cancel()
                )
            case .error(let message):
                return Alert(
                    title: Text("文件操作失败"),
                    message: Text(message),
                    dismissButton: .default(Text("好"))
                )
            }
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
                ChromeHairline()
                TransferList(browser: browser)
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
                        isCurrent: path == browser.rootPath
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

        return ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(visibleRows, id: \.entry.path) { row in
                    FileRow(
                        entry: row.entry,
                        depth: row.depth,
                        isSelected: browser.selection == row.entry.path,
                        isExpanded: browser.isExpanded(row.entry.path),
                        isLoading: browser.loading.contains(row.entry.path),
                        error: browser.errors[row.entry.path],
                        onClick: { clickCount in
                            browser.selection = row.entry.path
                            // 第一下只选中，第二下才切换。ClickCatcher 在 mouseDown 就回调，
                            // 所以若让第一下切换，鼠标还没松开目录就会自己展开或收起。
                            // 文件不管点几下都只是选中：5 GB 的文件不该因为手抖多点一下就开始传。
                            if clickCount == 2, row.entry.isExpandable {
                                browser.toggle(row.entry.path)
                            }
                        },
                        onToggle: {
                            browser.toggle(row.entry.path)
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
            .padding(.vertical, 4)
        }
        .frame(maxHeight: .infinity)
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
            panelAlert = FilePanelAlert(.confirmDeletion(entry))
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
            if let error { panelAlert = FilePanelAlert(.error(error)) }
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

private struct FilePanelAlert: Identifiable {

    enum Kind {
        case confirmDeletion(RemoteFileEntry)
        case error(String)
    }

    let id = UUID()
    let kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
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
                        .fill(isHovering ? ChromeStyle.hover : .clear)
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
    let onClick: (Int) -> Void
    let onToggle: () -> Void

    @State private var isHovering = false

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
                .fill(isSelected ? ChromeStyle.selectedRow : (isHovering ? ChromeStyle.hover : .clear))
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
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

// MARK: - 传输区

/// 面板底部那一小块：正在传和刚传完的条目。
///
/// 下载有百分比（拿本地文件当前多大除以远端说它多大算出来的），上传只能显示「传输中」——
/// sftp 的进度条只在 stdout 是 tty 时才输出，批处理模式下一个字都没有。
private struct TransferList: View {

    @ObservedObject var browser: RemoteFileBrowser

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("传输")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

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

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(browser.transfers) { transfer in
                        TransferRow(transfer: transfer) { browser.cancel(transfer.id) }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            // 传输区不能把树挤没了：只占一小条，多了自己滚。
            .frame(maxHeight: 120)
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
