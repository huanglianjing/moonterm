import Foundation

/// 把 `RemoteMetricsScript` 一帧输出解析成 `HostMetricsFrame`。
///
/// 纯函数，没有副作用，便于单测。
///
/// 容错原则：**某一节坏了只丢那一节**。`/proc` 各文件在不同内核、容器、架构上多几列少几列
/// 是常事（`/proc/stat` 的 `steal` 是 2.6.11 才有的，容器里 `df` 可能一行都给不出），
/// 为一个读不到的字段把整帧扔掉的话，图会毫无理由地断一格。
public enum RemoteMetricsParser {

    // MARK: - 一帧

    /// 按 `#m:` 标记切节再逐节解析。一节都没解出来时返回的帧 `isEmpty` 为 true。
    public static func parseFrame(_ text: String) -> HostMetricsFrame {
        var sections: [RemoteMetricsScript.Section: [String]] = [:]
        var current: RemoteMetricsScript.Section?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix(RemoteMetricsScript.markerPrefix) {
                let name = String(line.dropFirst(RemoteMetricsScript.markerPrefix.count))
                // 认不出的标记（以后加了节、但版本对不上）就当这一节不存在，别把内容错记到上一节里。
                current = RemoteMetricsScript.Section(rawValue: name)
                continue
            }
            guard let current else { continue }
            sections[current, default: []].append(line)
        }

        func content(of section: RemoteMetricsScript.Section) -> String? {
            guard let lines = sections[section] else { return nil }
            return lines.joined(separator: "\n")
        }

        return HostMetricsFrame(
            uptime: content(of: .time).flatMap(parseUptime),
            cpu: content(of: .cpu).flatMap(parseCPU),
            memory: content(of: .memory).flatMap(parseMemory),
            load: content(of: .load).flatMap(parseLoad),
            cpuCount: content(of: .cpuCount).flatMap(parseCPUCount),
            network: content(of: .network).flatMap(parseNetwork),
            disks: content(of: .disk).map { parseDisks($0) } ?? []
        )
    }

    // MARK: - 各节

    /// `/proc/uptime`：`12345.67 98765.43`（开机秒数、各核空闲秒数之和）。只要第一个。
    public static func parseUptime(_ text: String) -> Double? {
        guard let field = fields(ofFirstNonEmptyLine: text).first else { return nil }
        return Double(field)
    }

    /// `/proc/stat` 的汇总行：`cpu  123 4 56 7890 12 0 3 0 0 0`。
    ///
    /// 后面还有 `guest` / `guest_nice`，但它们已经算在 `user` / `nice` 里了（内核文档写明的重复计数），
    /// 再加一遍会把总量放大，所以只取前 8 档。少于 5 档（很老的内核、或者行被截断）就当读不到。
    public static func parseCPU(_ text: String) -> CPUTimes? {
        for line in text.split(separator: "\n") {
            let fields = columns(line)
            guard fields.first == "cpu" else { continue }
            let values = fields.dropFirst().compactMap(UInt64.init)
            guard values.count >= 5 else { return nil }
            return CPUTimes(
                user: values[0],
                nice: values[1],
                system: values[2],
                idle: values[3],
                iowait: values[4],
                irq: values.count > 5 ? values[5] : 0,
                softirq: values.count > 6 ? values[6] : 0,
                steal: values.count > 7 ? values[7] : 0
            )
        }
        return nil
    }

    /// `/proc/meminfo` 里的 `MemTotal:  16316052 kB` 这些行（脚本已经先 grep 过一遍）。
    ///
    /// 没有 `MemAvailable`（3.14 以前的内核）时用 `MemFree + Buffers + Cached` 顶上 ——
    /// 这正是 `free` 命令当年的算法，偏差主要来自不可回收的那部分缓存，读个占用率够用了。
    public static func parseMemory(_ text: String) -> MemoryInfo? {
        var values: [String: UInt64] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            guard let kilobytes = fields(ofFirstNonEmptyLine: String(parts[1])).first.flatMap(UInt64.init) else {
                continue
            }
            values[key] = kilobytes
        }

        guard let total = values["MemTotal"], total > 0 else { return nil }
        let available = values["MemAvailable"]
            ?? ((values["MemFree"] ?? 0) + (values["Buffers"] ?? 0) + (values["Cached"] ?? 0))

        // meminfo 的单位是 kB（十进制的 k，但内核给的其实是 KiB，历史遗留），一律 ×1024 换成字节。
        return MemoryInfo(
            total: total * 1024,
            available: min(available, total) * 1024,
            swapTotal: (values["SwapTotal"] ?? 0) * 1024,
            swapFree: (values["SwapFree"] ?? 0) * 1024
        )
    }

    /// `/proc/loadavg`：`0.52 0.58 0.59 2/1234 56789`。只要前三个。
    public static func parseLoad(_ text: String) -> LoadAverage? {
        let values = fields(ofFirstNonEmptyLine: text).prefix(3).compactMap(Double.init)
        guard values.count == 3 else { return nil }
        return LoadAverage(one: values[0], five: values[1], fifteen: values[2])
    }

    /// `grep -c '^processor'` 的输出。0 说明没数出来（比如 cpuinfo 格式不一样），当读不到。
    public static func parseCPUCount(_ text: String) -> Int? {
        guard let value = fields(ofFirstNonEmptyLine: text).first.flatMap(Int.init), value > 0 else {
            return nil
        }
        return value
    }

    // MARK: - 网络

    /// `/proc/net/dev`：两行表头之后，每行 `  eth0: 1234 56 0 ... 7890 12 0 ...`。
    ///
    /// 收发累计字节分别是冒号后的第 1 和第 9 个数。所有参与统计的网卡加在一起 ——
    /// 侧栏只有一格地方，分接口画就没法看了；哪些算「参与统计」见 `isMonitoredInterface`。
    public static func parseNetwork(_ text: String) -> NetworkCounters? {
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var matched = false

        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }  // 表头没有冒号
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard isMonitoredInterface(name) else { continue }
            let values = columns(parts[1]).compactMap { UInt64($0) }
            guard values.count >= 9 else { continue }
            received &+= values[0]
            sent &+= values[8]
            matched = true
        }

        return matched ? NetworkCounters(receivedBytes: received, sentBytes: sent) : nil
    }

    /// 这块网卡算不算「真的在收发数据」。
    ///
    /// 排掉回环和各种虚拟口：`lo` 上的流量是本机自己跟自己说话；容器 / 虚拟机宿主上
    /// `docker0`、`veth*`、`br-*` 会把同一份流量再数一遍，加进来速率就翻倍了。
    public static func isMonitoredInterface(_ name: String) -> Bool {
        if name.isEmpty || name == "lo" { return false }
        let virtualPrefixes = ["docker", "veth", "br-", "virbr", "vnet", "tap", "kube", "cni", "flannel", "dummy"]
        return !virtualPrefixes.contains { name.hasPrefix($0) }
    }

    // MARK: - 磁盘

    /// `df -kP` 的输出。
    ///
    /// POSIX 格式（`-P`）保证一个挂载点一行、六列不换行，`-k` 保证单位是 1024 字节块。
    /// 挂载点里可以有空格，所以第 6 列往后全算挂载点。
    ///
    /// 侧栏最多留 `limit` 条：`/` 一定在最前面（谁都先看它），其余按使用率从高到低 ——
    /// 一台机器上真正需要注意的就是快满的那几个，而容器里 `df` 一列几十行全是噪音。
    public static func parseDisks(_ text: String, limit: Int = 4) -> [DiskUsage] {
        var entries: [DiskUsage] = []

        for line in text.split(separator: "\n") {
            let fields = columns(line)
            guard fields.count >= 6,
                  let blocks = UInt64(fields[1]),
                  let used = UInt64(fields[2]),
                  blocks > 0
            else { continue }  // 表头、`df` 的错误行、以及总量为 0 的伪文件系统都在这儿被滤掉

            let mountPoint = fields[5...].joined(separator: " ")
            let filesystem = fields[0]
            guard isMonitoredFilesystem(filesystem, mountPoint: mountPoint) else { continue }

            entries.append(
                DiskUsage(
                    filesystem: filesystem,
                    mountPoint: mountPoint,
                    totalBytes: blocks * 1024,
                    usedBytes: min(used, blocks) * 1024
                )
            )
        }

        let root = entries.first { $0.mountPoint == "/" }
        let others = entries
            .filter { $0.mountPoint != "/" }
            .sorted { lhs, rhs in
                // 使用率相同时按挂载点排，免得每帧顺序都在跳。
                lhs.usedFraction == rhs.usedFraction
                    ? lhs.mountPoint < rhs.mountPoint
                    : lhs.usedFraction > rhs.usedFraction
            }

        return Array(([root].compactMap { $0 } + others).prefix(max(1, limit)))
    }

    /// 这一行值不值得占侧栏一格。
    ///
    /// 排掉的都是「不是真磁盘」或者「同一块盘的另一个视角」：内存文件系统（`tmpfs` 系）、
    /// 容器镜像层（`overlay`）、snap 包（`/dev/loopN` 挂在 `/snap/...`，只读且永远 100% 满）。
    public static func isMonitoredFilesystem(_ filesystem: String, mountPoint: String) -> Bool {
        let pseudoFilesystems: Set<String> = [
            "tmpfs", "devtmpfs", "devfs", "ramfs", "overlay", "squashfs",
            "efivarfs", "udev", "none", "shm", "cgroup", "cgroup2"
        ]
        if pseudoFilesystems.contains(filesystem) { return false }
        if filesystem.hasPrefix("/dev/loop") { return false }

        let pseudoMountPrefixes = ["/snap", "/proc", "/sys", "/dev", "/run"]
        return !pseudoMountPrefixes.contains { mountPoint == $0 || mountPoint.hasPrefix($0 + "/") }
    }

    // MARK: - 辅助

    /// 第一行非空内容按空白切开。`/proc` 里好几个文件都是「一行几个数」。
    private static func fields(ofFirstNonEmptyLine text: String) -> [String] {
        for line in text.split(separator: "\n") {
            let fields = columns(line)
            if !fields.isEmpty { return fields }
        }
        return []
    }

    /// 一行按空白切成若干列。空格和制表符都当分隔符 —— `/proc` 与 `df` 用的是空格，
    /// 但对齐用几个、有没有掺制表符是各实现自己的事，不该由解析来赌。
    private static func columns(_ line: Substring) -> [String] {
        line
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
    }
}
