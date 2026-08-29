import XCTest
@testable import MoontermCore

/// 采集链路的**全链路**测试：起进程 → 灌脚本 → 按帧切开 → 解析 → 两帧差分。不需要远端。
///
/// 手法和 `SFTPRunnerLocalTests` 一个路子：把 ssh 那一段省掉，直接让本机的 `/bin/sh` 当
/// 「远端 shell」，再用 `RemoteMetricsScript.script(procRoot:)` 把 `/proc` 指到一个装了假
/// `stat` / `meminfo` 的临时目录。于是脚本里的引号、`echo` 分帧、`grep` / `head` / `df` 的
/// 可用性、以及「写完 stdin 就关掉、循环照跑」这些和 shell 约定好的事，全都是真跑过的。
///
/// 测不到的只有 ControlMaster 复用与认证 —— 那必须有真远端。
final class RemoteMetricsStreamLocalTests: XCTestCase {

    private var procRoot: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/bin/sh"), "本机没有 /bin/sh")

        procRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moonterm-proc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: procRoot.appendingPathComponent("net"),
            withIntermediateDirectories: true
        )
        try write(uptime: 100, user: 1000, idle: 9000, received: 10_000, sent: 2_000)
        try write("""
            MemTotal:       1000000 kB
            MemFree:          50000 kB
            MemAvailable:    400000 kB
            Buffers:          10000 kB
            Cached:          300000 kB
            SwapTotal:            0 kB
            SwapFree:             0 kB
            """, to: "meminfo")
        try write("0.52 0.58 0.59 2/1234 56789", to: "loadavg")
        try write("processor\t: 0\nprocessor\t: 1\nprocessor\t: 2\nprocessor\t: 3", to: "cpuinfo")
    }

    override func tearDownWithError() throws {
        if let procRoot {
            try? FileManager.default.removeItem(at: procRoot)
        }
    }

    // MARK: - 全链路

    /// 连收两帧：第一帧只有瞬时值，第二帧才有 CPU 占用和网络速率（差分要两帧）。
    ///
    /// 两帧之间测试会改写那几个假 `/proc` 文件 —— 脚本每轮都重新 `cat`，所以第二帧看到的是新值。
    func testStreamsFramesAndComputesDeltas() throws {
        let firstFrame = expectation(description: "第一帧")
        let secondFrame = expectation(description: "第二帧")
        var frames: [HostMetricsFrame] = []
        let stream = RemoteMetricsStream()

        stream.start(
            plan: localShellPlan(),
            script: RemoteMetricsScript.script(interval: 1, procRoot: procRoot.path),
            onFrame: { text in
                frames.append(RemoteMetricsParser.parseFrame(text))
                if frames.count == 1 {
                    // 让计数器往前走：多跑了 500 jiffies（其中 400 是闲的），又收了 20 KB。
                    try? self.write(uptime: 102, user: 1100, idle: 9400, received: 30_480, sent: 2_000)
                    firstFrame.fulfill()
                } else if frames.count == 2 {
                    secondFrame.fulfill()
                }
            },
            onUnsupported: { XCTFail("假 /proc 是齐的，不该报不支持") },
            onTerminate: { _ in }
        )

        wait(for: [firstFrame, secondFrame], timeout: 20)
        stream.stop()

        let first = frames[0]
        XCTAssertEqual(first.uptime, 100)
        XCTAssertEqual(first.cpuCount, 4)
        XCTAssertEqual(try XCTUnwrap(first.memory).usedFraction, 0.6, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(first.load).one, 0.52)
        XCTAssertEqual(try XCTUnwrap(first.network).receivedBytes, 10_000)
        // `df -kP` 是真跑的（macOS 与 Linux 的 POSIX 格式一致），根分区总该在。
        XCTAssertTrue(first.disks.contains { $0.mountPoint == "/" }, "解析不出根分区：\(first.disks)")

        // 第一帧没有基准，差分项必须是 nil，而不是 0。
        let firstSample = first.sample(previous: nil)
        XCTAssertNil(firstSample.cpuUsage)
        XCTAssertNil(firstSample.network)

        let secondSample = frames[1].sample(previous: first)
        XCTAssertEqual(try XCTUnwrap(secondSample.cpuUsage), 0.2, accuracy: 0.0001)
        // 20480 字节 / 2 秒 = 10 KB/s。
        XCTAssertEqual(
            try XCTUnwrap(secondSample.network).receivedBytesPerSecond,
            10_240,
            accuracy: 0.5
        )
        XCTAssertEqual(try XCTUnwrap(secondSample.network).sentBytesPerSecond, 0, accuracy: 0.0001)
    }

    /// 远端没有 `/proc`：脚本自己报一声就退出，面板据此说明情况。
    func testMissingProcReportsUnsupportedAndExits() throws {
        let unsupported = expectation(description: "报了不支持")
        let terminated = expectation(description: "进程退出了")
        let stream = RemoteMetricsStream()

        stream.start(
            plan: localShellPlan(),
            script: RemoteMetricsScript.script(interval: 1, procRoot: "/definitely/not/here"),
            onFrame: { _ in XCTFail("没有 /proc 时不该有帧") },
            onUnsupported: { unsupported.fulfill() },
            onTerminate: { termination in
                XCTAssertEqual(termination.exitCode, 0)
                XCTAssertFalse(termination.stopped)
                terminated.fulfill()
            }
        )

        wait(for: [unsupported, terminated], timeout: 20)
    }

    /// 自己叫停的不算失败，不该给出错误提示（否则面板每次收起都要闪一行红字）。
    func testStoppingIsNotAFailure() throws {
        let firstFrame = expectation(description: "第一帧")
        let terminated = expectation(description: "停下来了")
        let stream = RemoteMetricsStream()

        stream.start(
            plan: localShellPlan(),
            script: RemoteMetricsScript.script(interval: 1, procRoot: procRoot.path),
            onFrame: { _ in
                // 帧可能来好几个，只认第一个。
                if self.fulfilledFirstFrame { return }
                self.fulfilledFirstFrame = true
                firstFrame.fulfill()
                stream.stop()
            },
            onUnsupported: { XCTFail("假 /proc 是齐的，不该报不支持") },
            onTerminate: { termination in
                XCTAssertTrue(termination.stopped)
                XCTAssertNil(termination.errorMessage)
                terminated.fulfill()
            }
        )

        wait(for: [firstFrame, terminated], timeout: 20)
    }

    /// 真的 ssh 得认这套 argv。
    ///
    /// 连的是 `127.0.0.1:1`（必然连不上）加一个不存在的 socket，所以不碰网络、不碰认证，
    /// 但只要 `RemoteShellCommandBuilder` 拼错一个选项，ssh 就会打 `usage:` 而不是
    /// 「连不上」—— 这条测的正是这个区别。`BatchMode=yes` 也一起验了：不会停在密码提示上。
    func testRealSSHAcceptsTheArguments() throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: SSHCommandBuilder.sshExecutable),
            "本机没有 \(SSHCommandBuilder.sshExecutable)"
        )
        let terminated = expectation(description: "ssh 退出了")

        RemoteMetricsStream().start(
            plan: RemoteShellCommandBuilder.makePlan(
                config: HostConfig(host: "127.0.0.1", port: 1, username: "nobody"),
                controlPath: "/tmp/moonterm-no-such-socket-\(UUID().uuidString)"
            ),
            script: RemoteMetricsScript.script(interval: 1),
            onFrame: { _ in XCTFail("连不上时不该有帧") },
            onUnsupported: { XCTFail("连不上时不该报不支持") },
            onTerminate: { termination in
                XCTAssertNotEqual(termination.exitCode, 0)
                XCTAssertFalse(
                    termination.stderr.lowercased().contains("usage"),
                    "ssh 不认这套参数：\(termination.stderr)"
                )
                XCTAssertNotNil(termination.errorMessage)
                terminated.fulfill()
            }
        )

        wait(for: [terminated], timeout: 30)
    }

    /// 起不来的可执行文件也要老实回调一次，不能把调用方挂在那儿。
    func testMissingExecutableStillCallsBack() throws {
        let terminated = expectation(description: "回调了")

        RemoteMetricsStream().start(
            plan: SSHLaunchPlan(executable: "/nope/ssh", arguments: [], environment: []),
            script: "echo hi\n",
            onFrame: { _ in },
            onUnsupported: { },
            onTerminate: { termination in
                XCTAssertNotNil(termination.errorMessage)
                terminated.fulfill()
            }
        )

        wait(for: [terminated], timeout: 10)
    }

    // MARK: - 辅助

    private var fulfilledFirstFrame = false

    /// 把 ssh 那一段省掉，直接用本机 `sh -s` 当远端 shell。
    private func localShellPlan() -> SSHLaunchPlan {
        SSHLaunchPlan(
            executable: "/bin/sh",
            arguments: ["-s"],
            environment: []
        )
    }

    /// 假的 `/proc` 文件**必须以换行结尾** —— 真的 `/proc` 就是这样，而分节标记靠「整行相等」
    /// 认出来：少了这个换行，`cat` 出来的最后一行会和紧跟其后的 `echo '#m:...'` 粘成一行，
    /// 那一节就整节丢掉（丢的只是那一节，别的节照旧）。
    private func write(_ contents: String, to name: String) throws {
        try Data((contents + "\n").utf8).write(to: procRoot.appendingPathComponent(name))
    }

    /// 写一套「这一刻」的假 `/proc`。
    private func write(
        uptime: Double,
        user: UInt64,
        idle: UInt64,
        received: UInt64,
        sent: UInt64
    ) throws {
        try write("\(uptime) 9999.99", to: "uptime")
        try write("cpu  \(user) 0 0 \(idle) 0 0 0 0 0 0\ncpu0 1 2 3 4 5", to: "stat")
        try write("""
            Inter-|   Receive                                                |  Transmit
             face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
                lo: 999 9 0 0 0 0 0 0 999 9 0 0 0 0 0 0
              eth0: \(received) 9 0 0 0 0 0 0 \(sent) 9 0 0 0 0 0 0
            """, to: "net/dev")
    }
}
