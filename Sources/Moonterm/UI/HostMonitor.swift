import Combine
import Foundation
import MoontermCore

/// 「监控」面板背后的状态：一条常驻采集流，加上几条指标的滑动历史。
///
/// **一个 tab 一份**（`AppState.hostMonitor(for:)`）。tab 与主机一一对应，所以历史属于这台机器；
/// 具体发命令时用的是**当前聚焦那个分栏**的 ControlMaster socket（见 `bind(session:)`），
/// 和文件面板同一个理由 —— socket 是每会话一份的。
///
/// 只在面板真的露出来时采样（`activate()` / `deactivate()`）：这条流是持续吃流量的，
/// 收起面板还接着采就成了后台常驻的偷跑。侧栏面板会被真正销毁重建，所以 `onDisappear`
/// 是可靠的停点 —— 和「分栏树必须常驻」那条边界无关，那条约束是为了别杀掉 PTY。
final class HostMonitor: ObservableObject {

    /// `…` 菜单里能选的采样间隔（秒）。
    static let intervalOptions = [1, 2, 5]

    // MARK: - 对外状态

    /// CPU 占用（0…1）。
    @Published private(set) var cpuHistory = MetricHistory()
    /// 内存已用占比（0…1）。
    @Published private(set) var memoryHistory = MetricHistory()
    /// 1 分钟负载。
    @Published private(set) var loadHistory = MetricHistory()
    /// 下行、上行速率（字节每秒）。分两条，画的时候共用一套 y 缩放。
    @Published private(set) var receivedHistory = MetricHistory()
    @Published private(set) var sentHistory = MetricHistory()

    /// 最新一格。第一帧还算不出 CPU 与网络（要两帧差分），那时它们是 nil。
    @Published private(set) var latest: HostMetricsSample?

    /// 面板级提示（没连上、远端不支持、采集挂了）。nil = 一切正常。
    @Published private(set) var statusMessage: String?

    /// 暂停采样。暂停不清历史 —— 停下来正是为了看住刚才那段曲线。
    ///
    /// 继续之后曲线是接着画的，暂停那段空档在图上看不出来。这是有意的取舍：暂停一般只有几秒，
    /// 为这几秒把几分钟的历史全清掉更不划算。改采样间隔也保留已有曲线，让用户仍能回看旧数据。
    @Published var isPaused: Bool {
        didSet {
            guard oldValue != isPaused else { return }
            UserDefaults.standard.set(isPaused, forKey: Self.pausedKey)
            if isPaused {
                stopStream()
            } else {
                startStream()
            }
        }
    }

    /// 采样间隔（秒）。
    @Published var interval: Int {
        didSet {
            guard oldValue != interval else { return }
            UserDefaults.standard.set(interval, forKey: Self.intervalKey)
            // 重启采集流会丢弃上一帧差分基准，但已有曲线仍要保留。
            restartStream()
        }
    }

    private static let pausedKey = "hostMonitorPaused"
    private static let intervalKey = "hostMonitorInterval"

    // MARK: - 内部

    private let host: HostConfig
    private weak var session: SSHSession?
    private var stream: RemoteMetricsStream?
    /// 开过几条流了。旧流的回调靠它认出来「你已经过期了」。
    private var streamGeneration = 0
    /// 上一帧原始读数，差分要用。
    private var previousFrame: HostMetricsFrame?
    /// 面板正露着。
    private var isActive = false
    /// 远端没有 `/proc`。确认过一次就不再重试 —— 换台机器才可能变。
    private var isUnsupported = false
    private var retryWorkItem: DispatchWorkItem?

    /// 采集流意外断掉后隔多久再试。连不上时不该每秒重试一次。
    private static let retryDelay: TimeInterval = 3

    init(host: HostConfig) {
        self.host = host
        let defaults = UserDefaults.standard
        self.isPaused = defaults.bool(forKey: Self.pausedKey)
        let storedInterval = defaults.integer(forKey: Self.intervalKey)
        self.interval = Self.intervalOptions.contains(storedInterval) ? storedInterval : 2
    }

    deinit {
        retryWorkItem?.cancel()
        stream?.stop()
    }

    // MARK: - 绑定会话

    /// 把面板接到当前聚焦的那个分栏上。切分栏、重连之后都要重新调。
    ///
    /// 换了连接就得换一条采集流（socket 不一样），但历史留着 —— 同一个 tab 的几个分栏是
    /// 同一台机器，曲线还是那台机器的曲线。
    func bind(session: SSHSession?) {
        guard self.session !== session else { return }
        self.session = session
        restartStream()
    }

    /// 面板露出来时调。
    func activate() {
        isActive = true
        startStream()
    }

    /// 面板收起 / 切到别的面板 / tab 关掉时调。停流，历史留着。
    func deactivate() {
        isActive = false
        stopStream()
    }

    // MARK: - 采集流

    private func startStream() {
        guard isActive, !isPaused, stream == nil else { return }
        retryWorkItem?.cancel()
        retryWorkItem = nil

        guard let session else {
            statusMessage = "没有打开的连接"
            return
        }
        guard session.isMultiplexReady else {
            statusMessage = session.state.isLive ? "正在连接…" : "会话未连接，按 ⌘R 重连"
            return
        }
        guard !isUnsupported else { return }

        statusMessage = nil
        // 换一条流就换一份差分基准：新流的第一帧和旧流最后一帧之间隔了多久没人知道。
        previousFrame = nil

        let stream = RemoteMetricsStream()
        self.stream = stream
        // 用「第几条流」这个号来认回调，而不是把 stream 本身捕进闭包 ——
        // 那会让 stream 被自己的回调强引用住，跑完也不释放。
        streamGeneration &+= 1
        let generation = streamGeneration
        stream.start(
            plan: RemoteShellCommandBuilder.makePlan(config: host, controlPath: session.controlPath),
            script: RemoteMetricsScript.script(interval: interval),
            onFrame: { [weak self] text in
                self?.receive(frameText: text, generation: generation)
            },
            onUnsupported: { [weak self] in
                self?.markUnsupported(generation: generation)
            },
            onTerminate: { [weak self] termination in
                self?.handle(termination: termination, generation: generation)
            }
        )
    }

    private func stopStream() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        // 号往前走一格：停的那一刻可能已经有一帧投在主队列上了，落地时要能认出它过期。
        streamGeneration &+= 1
        stream?.stop()
        stream = nil
        previousFrame = nil
    }

    private func restartStream() {
        stopStream()
        startStream()
    }

    // MARK: - 收帧

    private func receive(frameText: String, generation: Int) {
        guard generation == streamGeneration else { return }

        let frame = RemoteMetricsParser.parseFrame(frameText)
        guard !frame.isEmpty else {
            // 一节都没解出来：远端输出的不是我们要的东西（比如登录 shell 往流里插了欢迎语）。
            statusMessage = "远端输出无法解析"
            return
        }
        statusMessage = nil

        // 远端重启了（单调的 uptime 变小）：旧曲线和新曲线之间断了一截，接着画会看成一次尖峰。
        if let previous = previousFrame?.uptime, let now = frame.uptime, now < previous {
            clearHistories()
            previousFrame = nil
        }

        let sample = frame.sample(previous: previousFrame)
        previousFrame = frame
        latest = sample

        if let cpuUsage = sample.cpuUsage {
            cpuHistory.append(cpuUsage)
        }
        if let memory = sample.memory {
            memoryHistory.append(memory.usedFraction)
        }
        if let load = sample.load {
            loadHistory.append(load.one)
        }
        if let network = sample.network {
            receivedHistory.append(network.receivedBytesPerSecond)
            sentHistory.append(network.sentBytesPerSecond)
        }
    }

    private func markUnsupported(generation: Int) {
        guard generation == streamGeneration else { return }
        isUnsupported = true
        statusMessage = "远端不支持监控（需要 Linux 的 /proc）"
        stopStream()
    }

    /// 采集进程结束了。我们自己叫停的不用管；意外断掉（网络抖了一下、master 没了）过几秒再试。
    private func handle(termination: RemoteMetricsStream.Termination, generation: Int) {
        // 已经换了新的一条流，这是旧流的收尾回调，别拿它的结论盖住新流。
        guard generation == streamGeneration else { return }
        stream = nil
        guard !termination.stopped else { return }

        statusMessage = termination.errorMessage
        guard isActive, !isPaused, !isUnsupported else { return }

        let item = DispatchWorkItem { [weak self] in
            self?.retryWorkItem = nil
            self?.startStream()
        }
        retryWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay, execute: item)
    }

    private func clearHistories() {
        cpuHistory.removeAll()
        memoryHistory.removeAll()
        loadHistory.removeAll()
        receivedHistory.removeAll()
        sentHistory.removeAll()
    }
}
