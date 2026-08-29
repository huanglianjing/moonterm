import Foundation

// 远端一次采样的原始读数与算好的结果。
//
// 分成「原始帧」和「样本」两层，是因为 CPU 占用和网络速率都**不是**某一时刻的读数，
// 而是两帧之差：`/proc/stat` 给的是开机以来累计的 jiffies，`/proc/net/dev` 给的是累计字节。
// 于是采集只管把原始计数搬回来（`HostMetricsFrame`），差分与除法集中在
// `HostMetricsFrame.sample(previous:)` 一处，好写单测也好定位「为什么百分比是负的」。

// MARK: - CPU

/// `/proc/stat` 第一行（所有核的汇总）里的各档时间，单位是 jiffies。
public struct CPUTimes: Equatable {

    public let user: UInt64
    public let nice: UInt64
    public let system: UInt64
    public let idle: UInt64
    public let iowait: UInt64
    public let irq: UInt64
    public let softirq: UInt64
    public let steal: UInt64

    public init(
        user: UInt64,
        nice: UInt64,
        system: UInt64,
        idle: UInt64,
        iowait: UInt64,
        irq: UInt64 = 0,
        softirq: UInt64 = 0,
        steal: UInt64 = 0
    ) {
        self.user = user
        self.nice = nice
        self.system = system
        self.idle = idle
        self.iowait = iowait
        self.irq = irq
        self.softirq = softirq
        self.steal = steal
    }

    /// 所有档相加。差分的分母。
    public var total: UInt64 {
        user &+ nice &+ system &+ idle &+ iowait &+ irq &+ softirq &+ steal
    }

    /// 算作「闲着」的部分。
    ///
    /// `iowait` 也归到闲：那段时间 CPU 确实没在算东西，等的是磁盘。把它算进忙的话，
    /// 一台在拷文件的机器会显示 100% 占用，而它的 CPU 其实是空的。
    public var idleTotal: UInt64 { idle &+ iowait }

    /// 真正在干活的部分。
    public var busy: UInt64 { total >= idleTotal ? total - idleTotal : 0 }
}

// MARK: - 内存

/// `/proc/meminfo` 里我们要的那几项，**单位已经换成字节**（meminfo 原文是 kB）。
public struct MemoryInfo: Equatable {

    public let total: UInt64
    /// 内核自己算的「还能拿去用的」。3.14 以后的内核都有；没有时由解析那边用
    /// `free + buffers + cached` 顶上（见 `RemoteMetricsParser.parseMemory`）。
    public let available: UInt64
    public let swapTotal: UInt64
    public let swapFree: UInt64

    public init(total: UInt64, available: UInt64, swapTotal: UInt64, swapFree: UInt64) {
        self.total = total
        self.available = available
        self.swapTotal = swapTotal
        self.swapFree = swapFree
    }

    /// 已用 = 总量 - 可用。
    ///
    /// **不用** `total - free`：Linux 会把空闲内存全拿去当页缓存，`free` 常年只剩几十兆，
    /// 那样算出来的「已用」永远是 99%，没有任何信息量。
    public var used: UInt64 { total >= available ? total - available : 0 }

    /// 0…1。总量为 0（读不到）时是 0。
    public var usedFraction: Double {
        total > 0 ? Double(used) / Double(total) : 0
    }

    public var swapUsed: UInt64 { swapTotal >= swapFree ? swapTotal - swapFree : 0 }

    /// 没开 swap 时 nil —— 界面上就不显示这一行，而不是显示一个 0%。
    public var swapUsedFraction: Double? {
        guard swapTotal > 0 else { return nil }
        return Double(swapUsed) / Double(swapTotal)
    }
}

// MARK: - 负载

/// `/proc/loadavg` 的前三个数。
public struct LoadAverage: Equatable {

    public let one: Double
    public let five: Double
    public let fifteen: Double

    public init(one: Double, five: Double, fifteen: Double) {
        self.one = one
        self.five = five
        self.fifteen = fifteen
    }
}

// MARK: - 网络

/// 参与统计的那些网卡的收发字节累计和（虚拟口已经在解析时排掉了）。
public struct NetworkCounters: Equatable {

    public let receivedBytes: UInt64
    public let sentBytes: UInt64

    public init(receivedBytes: UInt64, sentBytes: UInt64) {
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
    }
}

// MARK: - 磁盘

/// `df -kP` 的一行。
public struct DiskUsage: Equatable, Identifiable {

    public let filesystem: String
    public let mountPoint: String
    public let totalBytes: UInt64
    public let usedBytes: UInt64

    /// 挂载点当身份 —— 同一时刻不会有两行挂在同一处。
    public var id: String { mountPoint }

    public init(filesystem: String, mountPoint: String, totalBytes: UInt64, usedBytes: UInt64) {
        self.filesystem = filesystem
        self.mountPoint = mountPoint
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
    }

    /// 0…1。
    public var usedFraction: Double {
        totalBytes > 0 ? min(1, Double(usedBytes) / Double(totalBytes)) : 0
    }
}

// MARK: - 一帧原始读数

/// 远端一次输出（一帧）解析出来的东西。哪一节读不到就是 nil，不影响别的节。
public struct HostMetricsFrame: Equatable {

    /// `/proc/uptime` 的第一个数，秒，带两位小数。
    ///
    /// 用它而不是 `date +%s` 当时间轴：它是**单调**的，不会被远端改系统时间或 NTP 跳秒带偏；
    /// 精度也够（0.01 秒），算网络速率时分母更准。远端重启后它会变小，正好用来发现「机器换了一条命」。
    public let uptime: Double?
    public let cpu: CPUTimes?
    public let memory: MemoryInfo?
    public let load: LoadAverage?
    /// 逻辑核数，用来把负载读成「相对几个核」。
    public let cpuCount: Int?
    public let network: NetworkCounters?
    /// 已经过滤并排好序的挂载点（见 `RemoteMetricsParser.parseDisks`）。
    public let disks: [DiskUsage]

    public init(
        uptime: Double? = nil,
        cpu: CPUTimes? = nil,
        memory: MemoryInfo? = nil,
        load: LoadAverage? = nil,
        cpuCount: Int? = nil,
        network: NetworkCounters? = nil,
        disks: [DiskUsage] = []
    ) {
        self.uptime = uptime
        self.cpu = cpu
        self.memory = memory
        self.load = load
        self.cpuCount = cpuCount
        self.network = network
        self.disks = disks
    }

    /// 这一帧一点有用的东西都没有（远端输出坏了）。
    public var isEmpty: Bool {
        cpu == nil && memory == nil && load == nil && network == nil && disks.isEmpty
    }

    /// 和上一帧比出这一格该显示什么。
    ///
    /// 没有上一帧、时间没往前走、或者计数器变小（远端重启、网卡被重置）时，
    /// 差分出来的项一律给 nil —— **不要**回填 0 或取绝对值：那样图上会出现一段
    /// 凭空捏出来的平地或尖峰，比一段空白更难发现问题。
    public func sample(previous: HostMetricsFrame?) -> HostMetricsSample {
        HostMetricsSample(
            cpuUsage: Self.cpuUsage(previous: previous?.cpu, current: cpu),
            memory: memory,
            load: load,
            cpuCount: cpuCount,
            network: Self.rates(previous: previous, current: self),
            disks: disks
        )
    }

    /// 两帧 jiffies 之差算占用率。时间差在这里用不上 —— 分子分母都是 jiffies，自己就抵掉了。
    private static func cpuUsage(previous: CPUTimes?, current: CPUTimes?) -> Double? {
        guard let previous, let current else { return nil }
        guard current.total > previous.total, current.idleTotal >= previous.idleTotal else {
            // 相等（同一帧、采样间隔太短）或变小（重启）都算不出来。
            return nil
        }
        let totalDelta = Double(current.total - previous.total)
        let idleDelta = Double(current.idleTotal - previous.idleTotal)
        return min(1, max(0, 1 - idleDelta / totalDelta))
    }

    private static func rates(
        previous: HostMetricsFrame?,
        current: HostMetricsFrame
    ) -> HostMetricsSample.NetworkRates? {
        guard let previous,
              let before = previous.network,
              let now = current.network,
              let previousUptime = previous.uptime,
              let uptime = current.uptime
        else { return nil }

        let elapsed = uptime - previousUptime
        guard elapsed > 0 else { return nil }
        guard now.receivedBytes >= before.receivedBytes, now.sentBytes >= before.sentBytes else {
            return nil
        }

        return HostMetricsSample.NetworkRates(
            receivedBytesPerSecond: Double(now.receivedBytes - before.receivedBytes) / elapsed,
            sentBytesPerSecond: Double(now.sentBytes - before.sentBytes) / elapsed
        )
    }
}

// MARK: - 一格算好的数据

/// 界面直接用的一格：能算的都算好了，算不出来的是 nil。
public struct HostMetricsSample: Equatable {

    /// 上下行速率，字节每秒。
    public struct NetworkRates: Equatable {
        public let receivedBytesPerSecond: Double
        public let sentBytesPerSecond: Double

        public init(receivedBytesPerSecond: Double, sentBytesPerSecond: Double) {
            self.receivedBytesPerSecond = receivedBytesPerSecond
            self.sentBytesPerSecond = sentBytesPerSecond
        }
    }

    /// 0…1。第一帧算不出来（要两帧才有差分）。
    public let cpuUsage: Double?
    public let memory: MemoryInfo?
    public let load: LoadAverage?
    public let cpuCount: Int?
    /// 第一帧算不出来，同 `cpuUsage`。
    public let network: NetworkRates?
    public let disks: [DiskUsage]

    public init(
        cpuUsage: Double? = nil,
        memory: MemoryInfo? = nil,
        load: LoadAverage? = nil,
        cpuCount: Int? = nil,
        network: NetworkRates? = nil,
        disks: [DiskUsage] = []
    ) {
        self.cpuUsage = cpuUsage
        self.memory = memory
        self.load = load
        self.cpuCount = cpuCount
        self.network = network
        self.disks = disks
    }
}
