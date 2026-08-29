import MoontermCore
import SwiftUI

/// 竖栏「监控」图标展开的面板：当前 tab 那台主机的 CPU / 内存 / 磁盘 / 负载 / 网络。
///
/// 数据复用终端那条已连上的 ssh 连接（ControlMaster 多路复用），远端只读 `/proc` 和跑 `df`，
/// 不装任何东西 —— 采集脚本见 `RemoteMetricsScript`，状态在 `HostMonitor`。
struct MonitorSidebarView: View {

    @EnvironmentObject private var appState: AppState

    /// 只负责挑出当前 tab 的采样状态。真正画面板的是 `MonitorPanel` ——
    /// 它把 monitor 收成 `@ObservedObject`，不然来了新一帧界面不会重绘。
    var body: some View {
        if let tab = appState.selectedTab {
            // `.id(tab.id)`：切 tab 时要**换一个视图**，这样旧 tab 的 `onDisappear` 会真的走一遍、
            // 把它那条采集流停掉。只换属性的话 SwiftUI 会沿用同一个视图，旧流就一直采下去了。
            MonitorPanel(monitor: appState.hostMonitor(for: tab), tab: tab)
                .id(tab.id)
        } else {
            SidebarNoConnectionPanel(
                panel: .monitor,
                hint: "在主机面板里双击一台主机，这里会显示它的资源占用"
            )
        }
    }
}

// MARK: - 面板

private struct MonitorPanel: View {

    @EnvironmentObject private var appState: AppState
    @ObservedObject var monitor: HostMonitor
    let tab: TerminalTab

    /// 标题栏那个 `…` 上有没有鼠标。`Menu` 自己不给悬停状态，只能自己接（和文件面板一样）。
    @State private var isOptionsHovering = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ChromeHairline()
            content
        }
        .frame(maxHeight: .infinity)
        .background(ChromeStyle.sidebar)
    }

    // MARK: 标题栏

    private var header: some View {
        HStack(spacing: 2) {
            Text(SidebarPanel.monitor.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            ChromeIconButton(
                systemName: monitor.isPaused ? "play.fill" : "pause.fill",
                side: 22,
                iconSize: 10
            ) {
                monitor.isPaused.toggle()
            }
            .help(monitor.isPaused ? "继续采样" : "暂停采样（不清历史）")

            Menu {
                Picker("采样间隔", selection: $monitor.interval) {
                    ForEach(HostMonitor.intervalOptions, id: \.self) { seconds in
                        Text("每 \(seconds) 秒").tag(seconds)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .bold))
                    .chromeIconCell(side: 22, hovering: isOptionsHovering)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22, height: 22)
            .onHover { isOptionsHovering = $0 }
            .help("采样间隔")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 28)
    }

    // MARK: 主体

    @ViewBuilder
    private var content: some View {
        let session = appState.session(id: tab.focusedSessionID)

        ScrollView {
            VStack(spacing: 8) {
                if let notice {
                    NoticeRow(notice: notice)
                }

                cpuCard
                memoryCard
                diskCard
                loadCard
                networkDownloadCard
                networkUploadCard
            }
            .padding(8)
        }
        // 面板一露头就接上当前分栏并开始采样。
        .onAppear {
            monitor.bind(session: session)
            monitor.activate()
        }
        // 面板收起、或切到别的面板：停掉那条流，别在背后一直吃流量。
        .onDisappear {
            monitor.deactivate()
        }
        // 切分栏 / 切 tab：换发命令用的那条连接（socket 是每会话一份的）。
        .onChange(of: tab.focusedSessionID) { _ in
            monitor.bind(session: appState.session(id: tab.focusedSessionID))
            monitor.activate()
        }
        // 连上的那一刻再试一次：面板可能是在连接完成之前就打开的。
        .onChange(of: session?.state) { _ in
            monitor.activate()
        }
    }

    /// 面板顶上那行提示。暂停和「正在连接」都是过程，不算问题，所以不标橙色。
    private var notice: MonitorNotice? {
        if monitor.isPaused {
            return MonitorNotice(text: "已暂停采样", icon: "pause.circle", isProblem: false)
        }
        guard let message = monitor.statusMessage else { return nil }
        if message == "正在连接…" {
            return MonitorNotice(text: message, icon: "clock", isProblem: false)
        }
        return MonitorNotice(text: message, icon: "exclamationmark.triangle.fill", isProblem: true)
    }

    // MARK: 各张卡

    private var cpuCard: some View {
        MetricCard(
            title: "CPU",
            value: monitor.latest?.cpuUsage.map(MetricFormat.percent),
            detail: monitor.latest?.cpuCount.map { "\($0) 核" }
        ) {
            // 占用率的量程天然是 0…100%，固定住才能一眼看出「这条线高不高」。
            PercentSparkline(history: monitor.cpuHistory, color: MetricPalette.cpu)
        }
    }

    private var memoryCard: some View {
        let memory = monitor.latest?.memory
        return MetricCard(
            title: "内存",
            value: memory.map { MetricFormat.percent($0.usedFraction) },
            detail: memory.map { memory in
                var text = "\(MetricFormat.bytes(memory.used)) / \(MetricFormat.bytes(memory.total))"
                if let swap = memory.swapUsedFraction {
                    text += " · swap \(MetricFormat.percent(swap))"
                }
                return text
            }
        ) {
            PercentSparkline(history: monitor.memoryHistory, color: MetricPalette.memory)
        }
    }

    private var loadCard: some View {
        let load = monitor.latest?.load
        return MetricCard(
            title: "负载",
            value: load.map { MetricFormat.load($0.one) },
            detail: load.map { load in
                "1/5/15 分钟 \(MetricFormat.load(load.one)) / \(MetricFormat.load(load.five)) / \(MetricFormat.load(load.fifteen))"
            }
        ) {
            // 负载没有上限，y 轴取窗口峰值；下限钉在 1（「一个核在忙」这个天然刻度），
            // 否则一台闲着的机器上 0.02 的抖动会被拉成满格的大山。
            Sparkline(
                history: monitor.loadHistory,
                upperBound: max(monitor.loadHistory.maximum ?? 0, 1),
                color: MetricPalette.load
            )
        }
    }

    private var networkDownloadCard: some View {
        let bound = monitor.receivedHistory.maximum ?? 0
        return MetricCard(
            title: "网络下载",
            value: monitor.latest?.network.map { MetricFormat.rate($0.receivedBytesPerSecond) },
            detail: bound > 0 ? "峰值 \(MetricFormat.rate(bound))" : nil
        ) {
            Sparkline(
                history: monitor.receivedHistory,
                upperBound: bound,
                color: MetricPalette.network
            )
        }
    }

    private var networkUploadCard: some View {
        let bound = monitor.sentHistory.maximum ?? 0
        return MetricCard(
            title: "网络上传",
            value: monitor.latest?.network.map { MetricFormat.rate($0.sentBytesPerSecond) },
            detail: bound > 0 ? "峰值 \(MetricFormat.rate(bound))" : nil
        ) {
            Sparkline(
                history: monitor.sentHistory,
                upperBound: bound,
                color: MetricPalette.network
            )
        }
    }

    private var diskCard: some View {
        let disks = monitor.latest?.disks ?? []
        return MetricCard(
            title: "磁盘",
            value: nil,
            detail: nil
        ) {
            // 磁盘不画折线：两秒一采的曲线基本是条直线，占比条才是这项指标真正的信息
            // （还剩多少），一个挂载点一条。
            VStack(spacing: 6) {
                if disks.isEmpty {
                    MetricPlaceholder()
                } else {
                    ForEach(disks) { disk in
                        DiskRow(disk: disk)
                    }
                }
            }
        }
    }
}

// MARK: - 卡片

/// 一张卡：标题 + 右上角当前值 + 图 + 底下一行小字。
private struct MetricCard<Content: View>: View {

    let title: String
    /// 右上角那个当前值。nil 就不显示 —— 要么这一项还没算出来（第一帧的 CPU 与网络都要等
    /// 第二帧，那时图上写着「等待采样…」），要么它本来就没有单个数字（磁盘）。
    let value: String?
    /// 图下面那行补充信息，没有就不占地方。
    let detail: String?
    let content: () -> Content

    init(
        title: String,
        value: String?,
        detail: String?,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.value = value
        self.detail = detail
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 2)

                if let value {
                    // 数字一律用文本色，不染成曲线的颜色 —— 颜色是图上那一笔的事，
                    // 让数字也跟着变色只会让面板看起来像一堆彩色标签。
                    Text(value)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }

            content()
                // 所有指标的内容区统一提高到原折线高度的 150%；磁盘没有折线，也留出同样高度。
                .frame(minHeight: Sparkline.standardHeight)

            if let detail {
                Text(detail)
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.04))
        )
    }
}

/// 面板顶上那行提示的内容。
private struct MonitorNotice {
    let text: String
    let icon: String
    /// 出问题了（采集断了、远端不支持）—— 只有这种情况才标橙色。
    let isProblem: Bool
}

/// 面板顶上的一行提示。
private struct NoticeRow: View {

    let notice: MonitorNotice

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: notice.icon)
                .font(.system(size: 9))
                .foregroundStyle(notice.isProblem ? .orange : .secondary)

            Text(notice.text)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.04))
        )
    }
}

// MARK: - 磁盘一行

private struct DiskRow: View {

    let disk: DiskUsage

    /// 到这个比例就该处理了，条子换成状态红并配一个警示图标 ——
    /// 状态色不能单独承担含义，所以图标和百分比一起出现。
    private static let criticalFraction = 0.9

    private var isCritical: Bool { disk.usedFraction >= Self.criticalFraction }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                if isCritical {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(MetricPalette.critical)
                }

                Text(disk.mountPoint)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("\(MetricFormat.bytes(disk.usedBytes)) / \(MetricFormat.bytes(disk.totalBytes))")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    // 侧栏窄到放不下整行时，先截挂载点（它中间截掉还认得出来），
                    // 别去截「12 G / 40 G」—— 截一半的数字是错的信息。
                    .layoutPriority(1)

                Spacer(minLength: 2)

                Text(MetricFormat.percent(disk.usedFraction))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(isCritical ? MetricPalette.critical : MetricPalette.disk)
                        .frame(width: max(1, proxy.size.width * disk.usedFraction))
                }
            }
            .frame(height: 5)
        }
        .help("\(disk.filesystem) 挂在 \(disk.mountPoint)")
    }
}

// MARK: - 折线

/// 量程固定在 0…100% 的折线（CPU、内存）。半高处加一条极淡的参考线。
private struct PercentSparkline: View {

    let history: MetricHistory
    let color: Color

    var body: some View {
        Sparkline(history: history, upperBound: 1, color: color)
            .background(alignment: .center) {
                Rectangle()
                    .fill(MetricPalette.gridline)
                    .frame(height: 1)
            }
    }
}

/// 一条小折线。
///
/// **右对齐**：最新的一点贴着右边缘，点数不足时左边留白 —— 把几个点拉满整幅宽度会让
/// x 轴的时间刻度随点数变化，看着像「刚开始的时候变化特别慢」。
private struct Sparkline: View {

    let history: MetricHistory
    /// y 轴上限。<= 0 时按 1 算（除零保护），画出来就是贴着基线的一条平线。
    let upperBound: Double
    let color: Color
    /// 一条折线的默认高度，比原来的 34 点提高 50%。
    static let standardHeight: CGFloat = 51

    var body: some View {
        GeometryReader { proxy in
            let points = points(in: proxy.size)
            ZStack {
                if points.count >= 2 {
                    // 线下那层同色浅填充：只有一条 1.5 点的细线时，形状要费点劲才看得出来。
                    area(points, in: proxy.size)
                        .fill(color.opacity(0.12))
                    line(points)
                        .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                } else {
                    MetricPlaceholder()
                }
            }
        }
        .frame(height: Self.standardHeight)
    }

    private func points(in size: CGSize) -> [CGPoint] {
        let values = history.values
        guard values.count >= 2, size.width > 0, size.height > 0 else { return [] }

        let bound = upperBound > 0 ? upperBound : 1
        // x 刻度按容量固定：每一格宽度不变，图是从右往左长出来的。
        let step = size.width / CGFloat(max(1, history.capacity - 1))

        return values.enumerated().map { index, value in
            let x = size.width - CGFloat(values.count - 1 - index) * step
            let ratio = min(1, max(0, value / bound))
            let y = CGFloat(1 - ratio) * size.height
            return CGPoint(x: x, y: y)
        }
    }

    private func line(_ points: [CGPoint]) -> Path {
        var path = Path()
        path.move(to: points[0])
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }

    private func area(_ points: [CGPoint], in size: CGSize) -> Path {
        let baseline = size.height
        var path = Path()
        path.move(to: CGPoint(x: points[0].x, y: baseline))
        for point in points {
            path.addLine(to: point)
        }
        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: baseline))
        path.closeSubpath()
        return path
    }
}

/// 还没攒够两个采样点时的占位。不画假数据，只放一条静默的基线。
private struct MetricPlaceholder: View {

    var body: some View {
        HStack(spacing: 4) {
            Text("等待采样…")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(MetricPalette.baseline)
                .frame(height: 1)
        }
    }
}

// MARK: - 配色与格式

/// 监控面板的图形配色。
///
/// 五项按面板里从上到下的顺序取自 dataviz 参考调色板的深色档 1…5，并用它的验证器在本面板的
/// 底色（`ChromeStyle.sidebar` ≈ `#202125`）上实跑过：亮度带、彩度、相邻色的色盲可分度
/// （最差 ΔE 8.4）、常规视觉可分度（最差 19.3）、与底色的对比度（均 ≥ 3:1）全部通过。
/// **改这几个值要重新跑验证器**，别凭眼睛挑。
private enum MetricPalette {

    static let cpu = Color(red: 0.224, green: 0.529, blue: 0.898)      // #3987e5
    static let memory = Color(red: 0.851, green: 0.349, blue: 0.149)   // #d95926
    static let disk = Color(red: 0.098, green: 0.620, blue: 0.439)     // #199e70
    static let load = Color(red: 0.788, green: 0.522, blue: 0.0)       // #c98500
    static let network = Color(red: 0.835, green: 0.318, blue: 0.506)  // #d55181

    /// 状态色，只用于「快满了」。它和上面五个系列色是分开的一档，不会被当成第六个系列。
    static let critical = Color(red: 0.816, green: 0.231, blue: 0.231) // #d03b3b

    /// 零线 / 基线。
    static let baseline = Color.white.opacity(0.12)
    /// 半高参考线。比基线更淡 —— 它只是个刻度，不该跟数据抢注意力。
    static let gridline = Color.white.opacity(0.06)
}

/// 面板上所有数字的写法。
private enum MetricFormat {

    /// `37%`。侧栏窄，不留小数。
    static func percent(_ fraction: Double) -> String {
        "\(Int((min(1, max(0, fraction)) * 100).rounded()))%"
    }

    /// `12 G`。和文件面板用同一套（二进制单位、标签只留一个字母）。
    static func bytes(_ value: UInt64) -> String {
        RemoteFileEntry.formatBytes(value)
    }

    /// `1.2 M/s`。
    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "0 B/s" }
        return RemoteFileEntry.formatBytes(UInt64(bytesPerSecond.rounded())) + "/s"
    }

    /// `1.20`。负载得留两位小数：闲机器上 0.05 和 0.5 差着十倍，取整就都成 0 了。
    static func load(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
