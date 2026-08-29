import XCTest
@testable import MoontermCore

/// `/proc` 与 `df` 的输出解析。样本都是真机上抄下来的格式。
final class RemoteMetricsParserTests: XCTestCase {

    // MARK: - 整帧

    /// 一帧完整输出（就是 `RemoteMetricsScript` 那个循环一轮吐出来的东西）。
    private let frameText = """
        #m:time
        12345.67 98765.43
        #m:cpu
        cpu  2255 34 2290 22625563 6290 127 456 0 0 0
        #m:mem
        MemTotal:       16316052 kB
        MemFree:          329784 kB
        MemAvailable:    8452740 kB
        Buffers:          262568 kB
        Cached:          5924832 kB
        SwapTotal:       2097148 kB
        SwapFree:        1048574 kB
        #m:load
        0.52 0.58 0.59 2/1234 56789
        #m:cpus
        8
        #m:net
        Inter-|   Receive                                                |  Transmit
         face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
            lo: 1000      10    0    0    0     0          0         0     1000      10    0    0    0     0       0          0
          eth0: 500000   900    0    0    0     0          0         0   250000     700    0    0    0     0       0          0
        docker0: 700       7    0    0    0     0          0         0      800       8    0    0    0     0       0          0
        #m:disk
        Filesystem     1024-blocks      Used Available Capacity Mounted on
        udev              8117368         0   8117368       0% /dev
        tmpfs             1631608      1800   1629808       1% /run
        /dev/sda1        41251136  12345678  26804518      32% /
        /dev/sdb1       102400000  97280000   5120000      95% /data
        /dev/loop3          56704     56704         0     100% /snap/core18/2721
        /dev/sdc1        10240000   1024000   9216000      10% /backup
        """

    func testParsesWholeFrame() throws {
        let frame = RemoteMetricsParser.parseFrame(frameText)

        XCTAssertEqual(frame.uptime, 12345.67)
        XCTAssertEqual(frame.cpuCount, 8)
        XCTAssertEqual(try XCTUnwrap(frame.cpu).idle, 22625563)
        XCTAssertEqual(try XCTUnwrap(frame.memory).total, 16316052 * 1024)
        XCTAssertEqual(try XCTUnwrap(frame.load).five, 0.58)
        // 只统计 eth0：lo 是回环，docker0 会把同一份流量再数一遍。
        XCTAssertEqual(try XCTUnwrap(frame.network).receivedBytes, 500000)
        XCTAssertEqual(try XCTUnwrap(frame.network).sentBytes, 250000)
        XCTAssertEqual(frame.disks.map { $0.mountPoint }, ["/", "/data", "/backup"])
        XCTAssertFalse(frame.isEmpty)
    }

    /// 少了几节、某一节内容坏掉，都只影响那一节。
    func testMissingAndBrokenSectionsOnlyLoseThatSection() {
        let frame = RemoteMetricsParser.parseFrame("""
            #m:cpu
            这不是 cpu 那一行
            #m:load
            0.10 0.20 0.30 1/2 3
            """)

        XCTAssertNil(frame.cpu)
        XCTAssertNil(frame.memory)
        XCTAssertNil(frame.uptime)
        XCTAssertEqual(frame.load?.one, 0.10)
        XCTAssertFalse(frame.isEmpty)
    }

    /// 完全对不上的输出（比如登录 shell 往流里插了欢迎语）要能被认出来是空的。
    func testGarbageFrameIsEmpty() {
        XCTAssertTrue(RemoteMetricsParser.parseFrame("Welcome to Ubuntu 22.04\nLast login: ...").isEmpty)
    }

    /// 认不出的标记只是让那一节消失，不会把内容错记到上一节里。
    func testUnknownMarkerDoesNotLeakIntoPreviousSection() {
        let frame = RemoteMetricsParser.parseFrame("""
            #m:load
            0.10 0.20 0.30 1/2 3
            #m:something-new
            9.99 9.99 9.99
            """)

        XCTAssertEqual(frame.load?.one, 0.10)
    }

    // MARK: - CPU

    func testParsesCPUTimesAndTreatsIOWaitAsIdle() throws {
        let cpu = try XCTUnwrap(RemoteMetricsParser.parseCPU("cpu  100 20 30 800 50 1 2 3 0 0"))

        XCTAssertEqual(cpu.user, 100)
        XCTAssertEqual(cpu.steal, 3)
        XCTAssertEqual(cpu.total, 100 + 20 + 30 + 800 + 50 + 1 + 2 + 3)
        // iowait 算闲着：拷文件时 CPU 确实没在算东西。
        XCTAssertEqual(cpu.idleTotal, 850)
        XCTAssertEqual(cpu.busy, cpu.total - 850)
    }

    /// 老内核没有 `steal` / `softirq`，缺的档按 0 算，不是整行作废。
    func testParsesCPUTimesFromShortLine() throws {
        let cpu = try XCTUnwrap(RemoteMetricsParser.parseCPU("cpu  10 0 5 100 2"))

        XCTAssertEqual(cpu.softirq, 0)
        XCTAssertEqual(cpu.total, 117)
    }

    /// 只有 4 档（被截断）时算读不到 —— 少一档就意味着分不清 idle 和 iowait。
    func testTooShortCPULineIsRejected() {
        XCTAssertNil(RemoteMetricsParser.parseCPU("cpu  10 0 5 100"))
    }

    /// 别把 `cpu0` 当成汇总行。
    func testPerCoreLinesAreIgnored() throws {
        let cpu = try XCTUnwrap(RemoteMetricsParser.parseCPU("cpu0 1 1 1 1 1\ncpu  10 0 5 100 2"))
        XCTAssertEqual(cpu.total, 117)
    }

    // MARK: - 内存

    func testMemoryUsesAvailableNotFree() throws {
        let memory = try XCTUnwrap(RemoteMetricsParser.parseMemory("""
            MemTotal:       1000 kB
            MemFree:          50 kB
            MemAvailable:    600 kB
            Buffers:          10 kB
            Cached:          300 kB
            SwapTotal:       200 kB
            SwapFree:         50 kB
            """))

        // 已用 = 总量 - 可用。用 free 算的话这台机器会显示 95% 已用，而它其实只用了 40%。
        XCTAssertEqual(memory.used, 400 * 1024)
        XCTAssertEqual(memory.usedFraction, 0.4, accuracy: 0.0001)
        XCTAssertEqual(memory.swapUsed, 150 * 1024)
        XCTAssertEqual(try XCTUnwrap(memory.swapUsedFraction), 0.75, accuracy: 0.0001)
    }

    /// 3.14 以前的内核没有 `MemAvailable`，退回 `free + buffers + cached`。
    func testMemoryFallsBackWhenAvailableIsMissing() throws {
        let memory = try XCTUnwrap(RemoteMetricsParser.parseMemory("""
            MemTotal:       1000 kB
            MemFree:         100 kB
            Buffers:          50 kB
            Cached:          250 kB
            """))

        XCTAssertEqual(memory.used, 600 * 1024)
    }

    /// 没开 swap 时不给百分比 —— 界面上就不显示那一段，而不是显示 0%。
    func testNoSwapMeansNoSwapFraction() throws {
        let memory = try XCTUnwrap(RemoteMetricsParser.parseMemory("""
            MemTotal:       1000 kB
            MemAvailable:    400 kB
            SwapTotal:         0 kB
            SwapFree:          0 kB
            """))

        XCTAssertNil(memory.swapUsedFraction)
    }

    func testMemoryWithoutTotalIsRejected() {
        XCTAssertNil(RemoteMetricsParser.parseMemory("MemFree: 100 kB"))
    }

    // MARK: - 负载与核数

    func testParsesLoadAverage() throws {
        let load = try XCTUnwrap(RemoteMetricsParser.parseLoad("1.25 0.80 0.42 3/512 9876"))

        XCTAssertEqual(load.one, 1.25)
        XCTAssertEqual(load.five, 0.80)
        XCTAssertEqual(load.fifteen, 0.42)
    }

    func testRejectsIncompleteLoadAverage() {
        XCTAssertNil(RemoteMetricsParser.parseLoad("1.25 0.80"))
    }

    func testCPUCountZeroCountsAsUnknown() {
        XCTAssertNil(RemoteMetricsParser.parseCPUCount("0"))
        XCTAssertEqual(RemoteMetricsParser.parseCPUCount("16"), 16)
    }

    // MARK: - 网络

    /// 虚拟口全部排掉：算进来速率会翻倍。
    func testVirtualInterfacesAreExcluded() {
        for name in ["lo", "docker0", "veth1a2b", "br-abc123", "virbr0", "vnet0", "tap0", "cni0", ""] {
            XCTAssertFalse(RemoteMetricsParser.isMonitoredInterface(name), name)
        }
        for name in ["eth0", "ens3", "enp0s31f6", "wlan0", "bond0", "eno1"] {
            XCTAssertTrue(RemoteMetricsParser.isMonitoredInterface(name), name)
        }
    }

    /// 多张网卡时相加。
    func testNetworkSumsMonitoredInterfaces() throws {
        let counters = try XCTUnwrap(RemoteMetricsParser.parseNetwork("""
        Inter-|   Receive                                                |  Transmit
         face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
          eth0: 100      1    0    0    0     0          0         0      10       1    0    0    0     0       0          0
          eth1: 200      2    0    0    0     0          0         0      20       2    0    0    0     0       0          0
        """))

        XCTAssertEqual(counters.receivedBytes, 300)
        XCTAssertEqual(counters.sentBytes, 30)
    }

    /// 一张能统计的网卡都没有（容器里只有 lo）时算读不到，而不是 0 —— 0 会在图上画成一条实线。
    func testNetworkWithOnlyLoopbackIsNil() {
        XCTAssertNil(RemoteMetricsParser.parseNetwork("""
        Inter-|   Receive
         face |bytes
            lo: 100      1    0    0    0     0          0         0      10       1    0    0    0     0       0          0
        """))
    }

    // MARK: - 磁盘

    func testDiskRowIsConvertedToBytes() throws {
        let disks = RemoteMetricsParser.parseDisks("""
            Filesystem     1024-blocks      Used Available Capacity Mounted on
            /dev/sda1          1000000    250000    750000      25% /
            """)

        let root = try XCTUnwrap(disks.first)
        XCTAssertEqual(root.totalBytes, 1000000 * 1024)
        XCTAssertEqual(root.usedBytes, 250000 * 1024)
        XCTAssertEqual(root.usedFraction, 0.25, accuracy: 0.0001)
    }

    /// 伪文件系统、snap 的只读环回盘、以及挂在 `/proc` `/sys` 这些地方的都不占侧栏的位置。
    func testPseudoFilesystemsAreExcluded() {
        XCTAssertFalse(RemoteMetricsParser.isMonitoredFilesystem("tmpfs", mountPoint: "/run"))
        XCTAssertFalse(RemoteMetricsParser.isMonitoredFilesystem("overlay", mountPoint: "/"))
        XCTAssertFalse(RemoteMetricsParser.isMonitoredFilesystem("/dev/loop3", mountPoint: "/snap/core18/2721"))
        XCTAssertFalse(RemoteMetricsParser.isMonitoredFilesystem("/dev/sda1", mountPoint: "/dev/shm"))
        XCTAssertTrue(RemoteMetricsParser.isMonitoredFilesystem("/dev/sda1", mountPoint: "/"))
        XCTAssertTrue(RemoteMetricsParser.isMonitoredFilesystem("/dev/mapper/vg-data", mountPoint: "/data"))
        // `/dev` 本身要排掉，但 `/devel` 不是 `/dev` 下面的东西。
        XCTAssertTrue(RemoteMetricsParser.isMonitoredFilesystem("/dev/sdb1", mountPoint: "/devel"))
    }

    /// 根分区排最前，其余按使用率从高到低，最多留 limit 条。
    func testDisksAreSortedByUsageWithRootFirst() {
        let disks = RemoteMetricsParser.parseDisks("""
            /dev/sdb1  1000  900   100   90% /data
            /dev/sdc1  1000  100   900   10% /backup
            /dev/sda1  1000  200   800   20% /
            /dev/sdd1  1000  500   500   50% /var/lib
            /dev/sde1  1000  600   400   60% /opt
            """, limit: 3)

        XCTAssertEqual(disks.map { $0.mountPoint }, ["/", "/data", "/opt"])
    }

    /// 使用率一样时按挂载点排，免得每帧顺序都在跳。
    func testEqualUsageIsOrderedStably() {
        let disks = RemoteMetricsParser.parseDisks("""
            /dev/sdb1  1000  500   500   50% /b
            /dev/sda1  1000  500   500   50% /a
            """)

        XCTAssertEqual(disks.map { $0.mountPoint }, ["/a", "/b"])
    }

    /// 挂载点里可以有空格：第 6 列往后全算挂载点。
    func testMountPointWithSpaces() throws {
        let disks = RemoteMetricsParser.parseDisks("/dev/sdb1  1000  500   500   50% /mnt/my disk")
        XCTAssertEqual(try XCTUnwrap(disks.first).mountPoint, "/mnt/my disk")
    }

    /// 表头、`df` 抱怨的那几行、以及总量为 0 的行都会被滤掉。
    func testHeaderAndUnparsableRowsAreSkipped() {
        let disks = RemoteMetricsParser.parseDisks("""
            Filesystem     1024-blocks      Used Available Capacity Mounted on
            df: /mnt/stale: Stale file handle
            map auto_home            0         0         0     100% /home
            /dev/sda1          1000000    250000    750000      25% /
            """)

        XCTAssertEqual(disks.map { $0.mountPoint }, ["/"])
    }
}
