import Combine
import Foundation
import MoontermCore

/// 「文件」面板背后的状态：当前看的是哪个目录、树展开了哪几支、以及正在传的文件。
///
/// **一个 tab 一份**（`AppState.fileBrowser(for:)`）。tab 与主机一一对应，所以同一个 tab 里
/// 几个分栏看到的是同一棵树；具体发 sftp 时用的是**当前聚焦那个分栏**的 ControlMaster socket
/// （见 `bind(session:)`），因为 socket 是每会话一份的。
///
/// 树根是**当前目录**而不是 `/`：侧栏很窄，从根一级级缩进到 `/home/me/app/logs` 之后
/// 名字就只剩几个字了。往上走靠顶部的面包屑。
final class RemoteFileBrowser: ObservableObject {

    // MARK: - 传输

    struct Transfer: Identifiable {

        enum Direction {
            case download
            case upload
        }

        enum State: Equatable {
            /// 排在队里等前面的传完（同时最多两个，见 `maximumConcurrentTransfers`）。
            case queued
            case running
            case finished
            case failed(String)
        }

        let id = UUID()
        let name: String
        let direction: Direction
        /// 总字节数。下载时来自 `ls` 的结果，上传时来自本地文件；目录传输是 nil（没法预先知道）。
        let totalBytes: UInt64?
        /// 已传字节数。下载轮询本地落地文件，普通文件上传轮询远端目标文件；目录传输是 nil。
        var bytesDone: UInt64?
        var state: State = .queued

        var isDone: Bool {
            switch state {
            case .finished, .failed: return true
            case .queued, .running: return false
            }
        }

        /// 0…1 的进度。测不出来时 nil，界面上画成不确定的样子。
        ///
        /// sftp 批处理模式没有进度事件，所以两个方向都按已经落地的文件大小自行计算。
        var fraction: Double? {
            guard let totalBytes, totalBytes > 0, let bytesDone else { return nil }
            return min(1, Double(bytesDone) / Double(totalBytes))
        }
    }

    /// 上传前真实列一次目标目录的结果。只有 `.ready` 和用户确认过 `.conflicts` 后才能入传输队列。
    enum UploadPreflightResult {
        case ready
        case conflicts([String])
        case failed(String)
    }

    /// 同时最多传几个。sftp 一个进程一个文件，开太多只是把带宽切碎，还会撞上服务端的
    /// `MaxSessions`（默认 10，多路复用下每个传输占一条 channel）。
    private static let maximumConcurrentTransfers = 2

    // MARK: - 对外状态

    /// 树根，也就是面板当前「打开」的目录。
    @Published private(set) var rootPath = RemotePath.root
    /// 每个已经列过的目录 → 它的内容。没列过的目录不在表里。
    @Published private(set) var children: [String: [RemoteFileEntry]] = [:]
    /// 展开着的目录（含树根）。
    @Published private(set) var expanded: Set<String> = [RemotePath.root]
    /// 正在列的目录 —— 那一行显示转圈。
    @Published private(set) var loading: Set<String> = []
    /// 列失败的目录 → 原因（没权限、被删了）。
    @Published private(set) var errors: [String: String] = [:]
    /// 选中的那一项，也是上传的落点。nil = 没选，落点就是树根。
    @Published var selection: String?
    /// 远端家目录，由 sftp 刚连上时的 `pwd` 得到。也用来把标题里的 `~` 展开成真路径。
    @Published private(set) var home: String?
    @Published private(set) var transfers: [Transfer] = []
    /// 正在执行上传预检、新建、重命名或删除。一次只跑一个，避免目录修改互相覆盖刷新结果。
    @Published private(set) var isMutating = false

    /// 连接层面的问题（会话没连上、sftp 起不来），整块面板级的提示。
    @Published private(set) var connectionError: String?

    @Published var showsHidden: Bool {
        didSet { UserDefaults.standard.set(showsHidden, forKey: Self.showsHiddenKey) }
    }

    /// 跟着终端的当前目录跑。关掉之后面板就停在用户自己点到的地方。
    @Published var followsTerminal: Bool {
        didSet { UserDefaults.standard.set(followsTerminal, forKey: Self.followsTerminalKey) }
    }

    private static let showsHiddenKey = "fileBrowserShowsHidden"
    private static let followsTerminalKey = "fileBrowserFollowsTerminal"

    // MARK: - 内部

    private weak var session: SSHSession?
    private let host: HostConfig
    /// 正在跑的列目录调用。**同一时刻只有一个** —— 新的一来就把旧的掐掉，
    /// 因为用户点得快时晚回来的旧结果不该盖住新的。`loading` 也就跟着它整批换。
    private var listingRunner: SFTPRunner?
    /// 上传预检、新建、重命名、删除共用的一条串行操作。递归删除会逐步替换 runner，但始终只算一次操作。
    private var mutationRunner: SFTPRunner?
    /// 传输 id → 它的进程，用于取消。
    private var transferRunners: [UUID: SFTPRunner] = [:]
    /// 传输 id → 本地落地文件路径，用于轮询下载进度。
    private var downloadTargets: [UUID: URL] = [:]
    /// 普通文件上传的远端进度查询；目录无法用单个文件大小表示，所以不在这里。
    private struct UploadProgressTarget {
        let path: String
        var probe: UploadProgressProbe
    }
    private var uploadTargets: [UUID: UploadProgressTarget] = [:]
    /// 每个上传查询单独一条短命 sftp；查询不存在的文件失败时不能中断其他任务的查询。
    private var uploadProgressRunners: [UUID: SFTPRunner] = [:]
    /// 查询远端大小要另开一条复用 channel，限制到每秒一次，不能跟 0.4 秒的本地文件轮询一样频繁。
    private var lastUploadProgressPoll: [UUID: Date] = [:]
    /// 最近一次上传预检确认存在的目标及其旧大小，用来识别覆盖上传开始前的旧文件。
    private var uploadPreflightSizes: [String: UInt64] = [:]
    private var uploadPreflightChecked: Set<String> = []
    /// 传输 id → 还没起的命令（以及传完要重列哪个目录）。
    private var pendingCommands: [UUID: (command: String, reload: String?)] = [:]
    private var progressTimer: Timer?
    /// 已经问过家目录了（问一次就够，不用每次展开都带上 `pwd`）。
    private var hasResolvedHome = false

    init(host: HostConfig) {
        self.host = host
        let defaults = UserDefaults.standard
        self.showsHidden = defaults.bool(forKey: Self.showsHiddenKey)
        // 没存过时默认**跟随**：绝大多数时候「我现在在哪」就是想看的地方。
        self.followsTerminal = defaults.object(forKey: Self.followsTerminalKey) as? Bool ?? true
    }

    deinit {
        progressTimer?.invalidate()
        listingRunner?.cancel()
        mutationRunner?.cancel()
        transferRunners.values.forEach { $0.cancel() }
        uploadProgressRunners.values.forEach { $0.cancel() }
    }

    // MARK: - 绑定会话

    /// 把面板接到当前聚焦的那个分栏上。切分栏、重连之后都要重新调。
    ///
    /// 只换发命令用的连接，**不动**已经展开的树 —— 同一个 tab 的几个分栏是同一台主机，
    /// 路径通用，没必要因为切了个分栏就把树收回去。
    func bind(session: SSHSession?) {
        guard self.session !== session else { return }
        self.session = session
        connectionError = nil
    }

    /// 面板露出来时调。第一次会顺手问出家目录并定位到终端当前目录。
    ///
    /// 会话还没连上时**不发命令**，但要把原因写进 `connectionError` ——
    /// 否则面板只会空着，看不出是「还在连」还是「这个目录真是空的」。
    func activate() {
        guard let session else {
            connectionError = "没有打开的连接"
            return
        }
        guard session.isMultiplexReady else {
            connectionError = session.state.isLive ? "正在连接…" : "会话未连接，按 ⌘R 重连"
            return
        }
        connectionError = nil

        if !hasResolvedHome {
            resolveHomeAndLocate()
        } else if children[rootPath] == nil {
            load(rootPath)
        }
    }

    // MARK: - 定位

    /// 「定位到当前目录」。探不到就退回家目录，两个都没有就待在原地。
    func locate() {
        guard let session else { return }
        guard let directory = session.remoteDirectory(home: home) ?? home else { return }
        navigate(to: directory)
    }

    /// 终端的目录变了。只有开着「跟随」时才动，而且已经在那儿就别重列一次。
    func terminalDirectoryChanged() {
        guard followsTerminal,
              let session,
              session.isMultiplexReady,
              let directory = session.remoteDirectory(home: home),
              directory != rootPath
        else { return }
        navigate(to: directory)
    }

    /// 换树根（面包屑、定位、双击进目录都走这里）。
    func navigate(to path: String) {
        let path = RemotePath.normalize(path)
        rootPath = path
        expanded.insert(path)
        // 换根之后原来的选中项可能已经不在视野里了，清掉免得上传落点莫名指到别处。
        if let selection, !RemotePath.isDescendant(selection, of: path) {
            self.selection = nil
        }
        load(path)
    }

    /// 面包屑：从根到当前目录的每一级。
    var breadcrumb: [String] {
        RemotePath.ancestors(of: rootPath)
    }

    // MARK: - 展开与列目录

    func toggle(_ path: String) {
        if expanded.contains(path) {
            expanded.remove(path)
        } else {
            expanded.insert(path)
            // 只在没列过时才发命令；想强制刷新走 `refresh()`。
            if children[path] == nil { load(path) }
        }
    }

    func isExpanded(_ path: String) -> Bool { expanded.contains(path) }

    /// 重列当前树根以及所有展开着的子目录 —— 远端刚被改动过时用。
    func refresh() {
        let targets = ([rootPath] + expanded.filter { RemotePath.isDescendant($0, of: rootPath) })
            .reduced()
        guard !targets.isEmpty else { return }
        errors.removeAll()
        run(listing: targets)
    }

    /// 列一个目录。
    func load(_ path: String) {
        run(listing: [path])
    }

    /// 第一次进来：`pwd` 问家目录 + 列一个目录，**一次往返**办完。
    private func resolveHomeAndLocate() {
        guard let plan = makePlan() else { return }
        // 先立起来，免得面板刚露出来那几帧里重复发一遍；真失败了在回调里放回去，好让用户能重试。
        hasResolvedHome = true

        // 家目录还不知道，所以此刻只能用绝对路径那条线索；`~/x` 那种要等 pwd 回来才展开得开。
        let initialPath = session?.remoteDirectory(home: nil) ?? RemotePath.root
        let commands = [SFTPCommandBuilder.pwd, SFTPCommandBuilder.list(directory: initialPath)]

        listingRunner?.cancel()
        loading = [initialPath]
        let runner = SFTPRunner()
        listingRunner = runner
        runner.start(plan: plan, commands: commands) { [weak self] outcome in
            guard let self, self.listingRunner === runner else { return }
            self.listingRunner = nil
            self.loading = []

            if let output = outcome.outputs.first ?? nil {
                self.home = SFTPCommandBuilder.parsePwd(output)
            }
            guard outcome.isSuccess else {
                self.hasResolvedHome = false
                self.connectionError = self.explain(outcome)
                return
            }
            self.connectionError = nil

            // 现在知道家目录了，`~/logs` 这类线索才展开得开 —— 重新算一次落点。
            let target = self.session?.remoteDirectory(home: self.home) ?? self.home ?? initialPath
            if target == initialPath, let output = outcome.outputs.last ?? nil {
                self.rootPath = initialPath
                self.expanded.insert(initialPath)
                self.children[initialPath] = SFTPListingParser.parse(output, directory: initialPath)
            } else {
                self.navigate(to: target)
            }
        }
    }

    private func run(listing paths: [String]) {
        guard let plan = makePlan() else { return }

        listingRunner?.cancel()
        // 整批换掉：只有一个列目录调用在跑，被顶掉的那批不该继续显示转圈。
        loading = Set(paths)
        let commands = paths.map { SFTPCommandBuilder.list(directory: $0) }

        let runner = SFTPRunner()
        listingRunner = runner
        runner.start(plan: plan, commands: commands) { [weak self] outcome in
            guard let self, self.listingRunner === runner else { return }
            self.listingRunner = nil
            self.loading = []

            /// 第一条没拿到输出的：批处理一错即退，所以它就是出错的那一级
            /// （再往后的都是被连带取消的，不该也标成错）。
            var failedIndex: Int?
            for (index, path) in paths.enumerated() {
                guard let output = outcome.outputs[index] else {
                    failedIndex = failedIndex ?? index
                    continue
                }
                self.children[path] = SFTPListingParser.parse(output, directory: path)
                self.errors.removeValue(forKey: path)
            }

            guard !outcome.isSuccess else {
                self.connectionError = nil
                return
            }
            let message = self.explain(outcome)
            if let failedIndex {
                self.errors[paths[failedIndex]] = message
            } else {
                // 每条都有输出却仍然失败：不是某个目录的问题，按连接层的问题报。
                self.connectionError = message
            }
        }
    }

    // MARK: - 新建、重命名与删除

    /// 新建子目录。完成参数 nil 表示成功，否则是给用户看的错误。
    func createDirectory(in parent: String, name: String, completion: @escaping (String?) -> Void) {
        guard RemotePath.isValidName(name) else {
            completion("名称不能为空，不能是 . 或 ..，也不能包含 /。")
            return
        }
        guard let plan = beginMutation(completion: completion) else { return }
        let path = RemotePath.join(parent, name)

        runMutationStep(plan: plan, commands: [SFTPCommandBuilder.makeDirectory(path)]) { [weak self] outcome in
            guard let self else { return }
            self.isMutating = false
            guard outcome.isSuccess else {
                completion(self.explain(outcome))
                return
            }
            self.load(parent)
            completion(nil)
        }
    }

    /// 文件、目录与符号链接都由 sftp 的 `rename` 处理；新名字只改最后一段，不允许借机跨目录移动。
    /// 发 rename 前必须重新列父目录：部分服务端会把同名空目录直接替换掉，不会报错。
    func rename(_ entry: RemoteFileEntry, to name: String, completion: @escaping (String?) -> Void) {
        guard RemotePath.isValidName(name) else {
            completion("名称不能为空，不能是 . 或 ..，也不能包含 /。")
            return
        }
        let parent = RemotePath.parent(of: entry.path)
        let destination = RemotePath.join(parent, name)
        guard destination != entry.path else {
            completion(nil)
            return
        }
        guard let plan = beginMutation(completion: completion) else { return }
        let wasExpanded = expanded.contains(entry.path)

        runMutationStep(plan: plan, commands: [SFTPCommandBuilder.list(directory: parent)]) { [weak self] outcome in
            guard let self else { return }
            guard outcome.isSuccess else {
                self.isMutating = false
                completion(self.explain(outcome))
                return
            }
            guard let output = outcome.outputs.first ?? nil else {
                self.isMutating = false
                completion("无法确认目标名称是否已存在，请刷新后重试。")
                return
            }
            let entries = SFTPListingParser.parse(output, directory: parent)
            guard !RemoteFileMutationValidator.renameDestinationExists(destination, in: entries) else {
                self.isMutating = false
                completion("“\(name)”已存在，请使用其他名称。")
                return
            }

            self.performRename(
                entry,
                destination: destination,
                parent: parent,
                wasExpanded: wasExpanded,
                plan: plan,
                completion: completion
            )
        }
    }

    private func performRename(
        _ entry: RemoteFileEntry,
        destination: String,
        parent: String,
        wasExpanded: Bool,
        plan: SSHLaunchPlan,
        completion: @escaping (String?) -> Void
    ) {
        runMutationStep(
            plan: plan,
            commands: [SFTPCommandBuilder.rename(from: entry.path, to: destination)]
        ) { [weak self] outcome in
            guard let self else { return }
            self.isMutating = false
            guard outcome.isSuccess else {
                completion(self.explain(outcome))
                return
            }

            self.forgetSubtree(entry.path)
            self.selection = destination
            if entry.kind == .directory, wasExpanded {
                self.expanded.insert(destination)
                self.run(listing: [parent, destination].reduced())
            } else {
                self.load(parent)
            }
            completion(nil)
        }
    }

    /// 删除文件或目录。目录会先完整发现子树，再用 `rm` + 由深到浅的 `rmdir` 删除。
    func delete(_ entry: RemoteFileEntry, completion: @escaping (String?) -> Void) {
        guard let plan = beginMutation(completion: completion) else { return }
        if entry.kind == .directory {
            continueDeletionDiscovery(
                launchPlan: plan,
                entry: entry,
                deletionPlan: SFTPRecursiveDeletionPlan(rootDirectory: entry.path),
                completion: completion
            )
        } else {
            runMutationStep(plan: plan, commands: [SFTPCommandBuilder.removeFile(entry.path)]) { [weak self] outcome in
                self?.finishDeletion(entry: entry, outcome: outcome, completion: completion)
            }
        }
    }

    private func beginMutation(completion: (String?) -> Void) -> SSHLaunchPlan? {
        guard !isMutating else {
            completion("另一个文件操作正在进行，请稍后再试。")
            return nil
        }
        guard let plan = makePlan() else {
            completion(connectionError ?? "会话未连接")
            return nil
        }
        isMutating = true
        return plan
    }

    private func runMutationStep(
        plan: SSHLaunchPlan,
        commands: [String],
        completion: @escaping (SFTPRunner.Outcome) -> Void
    ) {
        let runner = SFTPRunner()
        mutationRunner = runner
        runner.start(plan: plan, commands: commands) { [weak self] outcome in
            guard let self, self.mutationRunner === runner else { return }
            self.mutationRunner = nil
            completion(outcome)
        }
    }

    /// 递归删除分两阶段：这里仅发现，不删任何东西。某一级列不了就安全停止，不会留下半删的目录。
    private func continueDeletionDiscovery(
        launchPlan: SSHLaunchPlan,
        entry: RemoteFileEntry,
        deletionPlan: SFTPRecursiveDeletionPlan,
        completion: @escaping (String?) -> Void
    ) {
        guard let directory = deletionPlan.nextDirectory else {
            let commands = deletionPlan.deletionCommands ?? []
            continueDeletionCommands(
                launchPlan: launchPlan,
                entry: entry,
                batches: SFTPCommandBuilder.commandBatches(commands),
                index: 0,
                completion: completion
            )
            return
        }

        runMutationStep(plan: launchPlan, commands: [SFTPCommandBuilder.list(directory: directory)]) { [weak self] outcome in
            guard let self else { return }
            guard outcome.isSuccess, let output = outcome.outputs.first ?? nil else {
                self.isMutating = false
                completion(self.explain(outcome))
                return
            }

            var next = deletionPlan
            let contents = SFTPListingParser.parse(output, directory: directory)
            guard next.record(contents: contents, of: directory) else {
                self.isMutating = false
                completion("内部错误：递归删除目录顺序不一致")
                return
            }
            self.continueDeletionDiscovery(
                launchPlan: launchPlan,
                entry: entry,
                deletionPlan: next,
                completion: completion
            )
        }
    }

    /// 真正删除时按小批次串行跑，避免大目录的脚本塞满 stdin 管道。
    private func continueDeletionCommands(
        launchPlan: SSHLaunchPlan,
        entry: RemoteFileEntry,
        batches: [[String]],
        index: Int,
        completion: @escaping (String?) -> Void
    ) {
        guard batches.indices.contains(index) else {
            finishDeletion(entry: entry, error: nil, completion: completion)
            return
        }
        runMutationStep(plan: launchPlan, commands: batches[index]) { [weak self] outcome in
            guard let self else { return }
            guard outcome.isSuccess else {
                self.finishDeletion(entry: entry, outcome: outcome, completion: completion)
                return
            }
            self.continueDeletionCommands(
                launchPlan: launchPlan,
                entry: entry,
                batches: batches,
                index: index + 1,
                completion: completion
            )
        }
    }

    private func finishDeletion(
        entry: RemoteFileEntry,
        outcome: SFTPRunner.Outcome,
        completion: @escaping (String?) -> Void
    ) {
        finishDeletion(entry: entry, error: outcome.isSuccess ? nil : explain(outcome), completion: completion)
    }

    private func finishDeletion(
        entry: RemoteFileEntry,
        error: String?,
        completion: @escaping (String?) -> Void
    ) {
        isMutating = false
        forgetSubtree(entry.path)
        load(RemotePath.parent(of: entry.path))
        completion(error)
    }

    /// 目录改名或删除之后，旧路径底下的缓存已经没有任何可信度，整支丢掉等下次真实列目录。
    private func forgetSubtree(_ path: String) {
        let cachedPaths = children.keys.filter { RemotePath.isDescendant($0, of: path) }
        for key in cachedPaths {
            children.removeValue(forKey: key)
        }
        expanded = Set(expanded.filter { !RemotePath.isDescendant($0, of: path) })
        loading = Set(loading.filter { !RemotePath.isDescendant($0, of: path) })
        let errorPaths = errors.keys.filter { RemotePath.isDescendant($0, of: path) }
        for key in errorPaths {
            errors.removeValue(forKey: key)
        }
        if let selection, RemotePath.isDescendant(selection, of: path) {
            self.selection = nil
        }
    }

    // MARK: - 传输

    /// 上传前重新列目标目录，不能直接信任文件树缓存：远端内容可能刚被另一条会话改过。
    func prepareUpload(
        _ localURLs: [URL],
        to directory: String,
        completion: @escaping (UploadPreflightResult) -> Void
    ) {
        guard !localURLs.isEmpty else {
            completion(.ready)
            return
        }
        guard let plan = beginMutation(completion: { error in
            if let error { completion(.failed(error)) }
        }) else { return }

        let destinations = localURLs.map { RemotePath.join(directory, $0.lastPathComponent) }
        for destination in destinations {
            uploadPreflightChecked.remove(destination)
            uploadPreflightSizes.removeValue(forKey: destination)
        }
        runMutationStep(plan: plan, commands: [SFTPCommandBuilder.list(directory: directory)]) { [weak self] outcome in
            guard let self else { return }
            self.isMutating = false
            guard outcome.isSuccess else {
                completion(.failed("无法检测同名文件：\(self.explain(outcome))"))
                return
            }
            guard let output = outcome.outputs.first ?? nil else {
                completion(.failed("无法检测同名文件，请刷新后重试。"))
                return
            }

            let entries = SFTPListingParser.parse(output, directory: directory)
            self.uploadPreflightChecked.formUnion(destinations)
            for entry in entries where destinations.contains(entry.path) {
                self.uploadPreflightSizes[entry.path] = entry.size
            }
            // 预检拿到的是最新目录内容，顺手更新已经显示过的这一层，避免确认框底下仍画着旧列表。
            if self.children[directory] != nil {
                self.children[directory] = entries
                self.errors.removeValue(forKey: directory)
            }
            let conflicts = RemoteFileMutationValidator.existingUploadDestinations(
                destinations,
                in: entries
            )
            completion(conflicts.isEmpty ? .ready : .conflicts(conflicts))
        }
    }

    /// 上传若干本地文件 / 目录到 `directory`。
    func upload(_ localURLs: [URL], to directory: String) {
        for url in localURLs {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { UInt64($0) }
            let remote = RemotePath.join(directory, url.lastPathComponent)
            let wasChecked = uploadPreflightChecked.remove(remote) != nil
            let checkedSize = uploadPreflightSizes.removeValue(forKey: remote)
            let initialRemoteSize = wasChecked
                ? checkedSize
                : children[directory]?.first { $0.path == remote }?.size

            enqueue(
                Transfer(
                    name: url.lastPathComponent,
                    direction: .upload,
                    totalBytes: isDirectory ? nil : size
                ),
                command: SFTPCommandBuilder.put(local: url.path, remote: remote, recursive: isDirectory),
                downloadTarget: nil,
                uploadTarget: isDirectory ? nil : UploadProgressTarget(
                    path: remote,
                    probe: UploadProgressProbe(initialRemoteSize: initialRemoteSize)
                ),
                // 上传完目标目录的内容变了，列一遍才对得上。
                reloadOnFinish: directory
            )
        }
    }

    /// 下载一项到本地 `destination`（已经含文件名）。
    func download(_ entry: RemoteFileEntry, to destination: URL) {
        let isDirectory = entry.kind == .directory
        enqueue(
            Transfer(
                name: entry.name,
                direction: .download,
                totalBytes: isDirectory ? nil : entry.size
            ),
            command: SFTPCommandBuilder.get(
                remote: entry.path,
                local: destination.path,
                recursive: isDirectory
            ),
            downloadTarget: isDirectory ? nil : destination,
            uploadTarget: nil,
            reloadOnFinish: nil
        )
    }

    func cancel(_ transferID: UUID) {
        transferRunners[transferID]?.cancel()
        // 还在排队（进程都没起）时，直接就地标成失败，顺手把攒着的命令扔掉。
        if let index = transfers.firstIndex(where: { $0.id == transferID }), transfers[index].state == .queued {
            pendingCommands.removeValue(forKey: transferID)
            downloadTargets.removeValue(forKey: transferID)
            uploadTargets.removeValue(forKey: transferID)
            transfers[index].state = .failed("已取消")
            startQueuedTransfers()
        }
    }

    /// 清掉已经结束的记录（完成的和失败的）。
    func clearFinishedTransfers() {
        transfers.removeAll { $0.isDone }
    }

    var hasFinishedTransfers: Bool {
        transfers.contains { $0.isDone }
    }

    private func enqueue(
        _ transfer: Transfer,
        command: String,
        downloadTarget: URL?,
        uploadTarget: UploadProgressTarget?,
        reloadOnFinish: String?
    ) {
        transfers.append(transfer)
        if let downloadTarget { downloadTargets[transfer.id] = downloadTarget }
        if let uploadTarget { uploadTargets[transfer.id] = uploadTarget }
        pendingCommands[transfer.id] = (command, reloadOnFinish)
        startQueuedTransfers()
    }

    private func startQueuedTransfers() {
        for index in transfers.indices where transfers[index].state == .queued {
            guard transfers.filter({ $0.state == .running }).count < Self.maximumConcurrentTransfers else { return }
            let id = transfers[index].id
            guard let pending = pendingCommands.removeValue(forKey: id) else {
                transfers[index].state = .failed("内部错误：命令丢失")
                continue
            }
            guard let plan = makePlan() else {
                transfers[index].state = .failed(connectionError ?? "会话未连接")
                continue
            }

            transfers[index].state = .running
            let runner = SFTPRunner()
            transferRunners[id] = runner
            // 传输**不设超时**：大文件传十几分钟也正常，掐掉才是错的。要停就用「取消」。
            runner.start(plan: plan, commands: [pending.command], timeout: nil) { [weak self] outcome in
                self?.finish(transferID: id, outcome: outcome, reload: pending.reload)
            }
            updateProgressTimer()
        }
    }

    private func finish(transferID: UUID, outcome: SFTPRunner.Outcome, reload: String?) {
        transferRunners.removeValue(forKey: transferID)
        downloadTargets.removeValue(forKey: transferID)
        uploadTargets.removeValue(forKey: transferID)
        uploadProgressRunners.removeValue(forKey: transferID)?.cancel()
        lastUploadProgressPoll.removeValue(forKey: transferID)

        if let index = transfers.firstIndex(where: { $0.id == transferID }) {
            if outcome.isSuccess {
                transfers[index].state = .finished
                // 传完了就把进度条填满：最后一段轮询不一定赶得上。
                transfers[index].bytesDone = transfers[index].totalBytes
            } else {
                transfers[index].state = .failed(explain(outcome))
            }
        }

        if outcome.isSuccess, let reload, children[reload] != nil {
            load(reload)
        }
        updateProgressTimer()
        startQueuedTransfers()
    }

    // MARK: - 传输进度

    /// 普通文件的下载和上传都能从落地文件大小推算；递归目录传输仍显示不确定进度。
    private func updateProgressTimer() {
        let needsPolling = transfers.contains { transfer in
            transfer.state == .running
                && (downloadTargets[transfer.id] != nil || uploadTargets[transfer.id] != nil)
        }

        if needsPolling, progressTimer == nil {
            progressTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
                self?.pollProgress()
            }
        } else if !needsPolling {
            progressTimer?.invalidate()
            progressTimer = nil
        }
    }

    private func pollProgress() {
        for index in transfers.indices where transfers[index].state == .running {
            let id = transfers[index].id
            if let url = downloadTargets[id],
               let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                transfers[index].bytesDone = UInt64(size)
            }
            pollUploadProgress(transferID: id)
        }
    }

    /// 用另一条只复用、不认证的 sftp 查询远端目标大小。上一轮没结束时直接跳过，避免慢网络上堆积进程。
    private func pollUploadProgress(transferID: UUID) {
        let now = Date()
        guard uploadProgressRunners[transferID] == nil,
              lastUploadProgressPoll[transferID].map({ now.timeIntervalSince($0) >= 1 }) ?? true,
              let target = uploadTargets[transferID],
              let session,
              session.isMultiplexReady
        else { return }

        lastUploadProgressPoll[transferID] = now
        let runner = SFTPRunner()
        uploadProgressRunners[transferID] = runner
        let command = SFTPCommandBuilder.list(directory: target.path)
        let plan = SFTPCommandBuilder.makePlan(config: host, controlPath: session.controlPath)
        runner.start(plan: plan, commands: [command], timeout: 5) { [weak self, weak runner] outcome in
            guard let self,
                  let runner,
                  self.uploadProgressRunners[transferID] === runner
            else { return }
            self.uploadProgressRunners.removeValue(forKey: transferID)

            guard let output = outcome.outputs.first ?? nil,
                  let entry = SFTPListingParser.parse(
                      output,
                      directory: RemotePath.parent(of: target.path)
                  ).first(where: { $0.path == target.path }),
                  var currentTarget = self.uploadTargets[transferID],
                  let bytesDone = currentTarget.probe.accept(remoteSize: entry.size)
            else { return }

            self.uploadTargets[transferID] = currentTarget
            guard let index = self.transfers.firstIndex(where: {
                $0.id == transferID && $0.state == .running
            }) else { return }
            self.transfers[index].bytesDone = bytesDone
        }
    }

    // MARK: - 辅助

    /// 把一次失败翻译成给人看的话。
    ///
    /// 会话已经断了的话**别报 sftp 的原文** —— 那时 sftp 说的是「Connection closed」
    /// （master socket 没了，它退回直连又没有可用的认证方式），对着这句话没人知道该干什么。
    /// 真正该说的是「会话断了，按 ⌘R 重连」。
    private func explain(_ outcome: SFTPRunner.Outcome) -> String {
        if let session, !session.isMultiplexReady {
            return session.state.isLive ? "正在连接…" : "会话未连接，按 ⌘R 重连"
        }
        return outcome.errorMessage ?? "操作失败"
    }

    /// 当前能不能发 sftp。不能就把原因记下来给面板显示。
    private func makePlan() -> SSHLaunchPlan? {
        guard let session else {
            connectionError = "没有打开的连接"
            return nil
        }
        guard session.isMultiplexReady else {
            connectionError = session.state.isLive ? "正在连接…" : "会话未连接，按 ⌘R 重连"
            return nil
        }
        return SFTPCommandBuilder.makePlan(config: host, controlPath: session.controlPath)
    }

    /// 某个目录当前该显示的内容（隐藏文件按开关过滤）。
    func visibleChildren(of path: String) -> [RemoteFileEntry] {
        let entries = children[path] ?? []
        return showsHidden ? entries : entries.filter { !$0.isHidden }
    }

    /// 上传落点：选中的是目录就是它，选中的是文件就是它所在的目录，什么都没选就是树根。
    func uploadDestination() -> String {
        guard let selection else { return rootPath }
        if let entry = entry(at: selection) {
            return entry.kind == .directory ? selection : RemotePath.parent(of: selection)
        }
        return rootPath
    }

    func entry(at path: String) -> RemoteFileEntry? {
        children[RemotePath.parent(of: path)]?.first { $0.path == path }
    }
}

private extension Array where Element == String {

    /// 去重且保持顺序 —— 刷新时树根可能同时出现在「展开列表」里。
    func reduced() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
