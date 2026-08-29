import XCTest
@testable import MoontermCore

/// 两帧之间的差分：CPU 占用与网络速率都是算出来的，算不出来时必须是 nil。
final class HostMetricsTests: XCTestCase {

    private func cpu(user: UInt64, idle: UInt64) -> CPUTimes {
        CPUTimes(user: user, nice: 0, system: 0, idle: idle, iowait: 0)
    }

    private func frame(
        uptime: Double,
        user: UInt64 = 0,
        idle: UInt64 = 0,
        received: UInt64 = 0,
        sent: UInt64 = 0
    ) -> HostMetricsFrame {
        HostMetricsFrame(
            uptime: uptime,
            cpu: cpu(user: user, idle: idle),
            network: NetworkCounters(receivedBytes: received, sentBytes: sent)
        )
    }

    // MARK: - CPU

    func testCPUUsageIsBusyShareBetweenTwoFrames() throws {
        let previous = frame(uptime: 10, user: 100, idle: 900)
        let current = frame(uptime: 12, user: 300, idle: 1700)

        // 两帧之间总共走了 1000 jiffies，其中 800 是闲着的 → 20% 占用。
        XCTAssertEqual(try XCTUnwrap(current.sample(previous: previous).cpuUsage), 0.2, accuracy: 0.0001)
    }

    /// 第一帧算不出来 —— 没有差分的基准。
    func testFirstFrameHasNoCPUUsage() {
        XCTAssertNil(frame(uptime: 10, user: 100, idle: 900).sample(previous: nil).cpuUsage)
    }

    /// 计数器没动（两帧之间机器完全没跑，或者拿到了同一帧）时算不出来，
    /// 不能当成 0% —— 那会在图上画出一段凭空的平地。
    func testIdenticalCountersGiveNoUsage() {
        let sample = frame(uptime: 12, user: 100, idle: 900)
            .sample(previous: frame(uptime: 10, user: 100, idle: 900))
        XCTAssertNil(sample.cpuUsage)
    }

    /// 计数器变小 = 远端重启了，这一格不算。
    func testCountersGoingBackwardsGiveNoUsage() {
        let sample = frame(uptime: 5, user: 10, idle: 20)
            .sample(previous: frame(uptime: 9000, user: 100, idle: 900))
        XCTAssertNil(sample.cpuUsage)
    }

    /// 满载：闲的那一档一点没涨。
    func testFullyBusyIsOne() throws {
        let sample = frame(uptime: 12, user: 1100, idle: 900)
            .sample(previous: frame(uptime: 10, user: 100, idle: 900))
        XCTAssertEqual(try XCTUnwrap(sample.cpuUsage), 1, accuracy: 0.0001)
    }

    // MARK: - 网络

    func testNetworkRatesUseUptimeDelta() throws {
        let sample = frame(uptime: 12, user: 300, idle: 1700, received: 3000, sent: 500)
            .sample(previous: frame(uptime: 10, user: 100, idle: 900, received: 1000, sent: 100))

        let rates = try XCTUnwrap(sample.network)
        XCTAssertEqual(rates.receivedBytesPerSecond, 1000, accuracy: 0.0001)
        XCTAssertEqual(rates.sentBytesPerSecond, 200, accuracy: 0.0001)
    }

    /// 时间没往前走：不能拿 0 当分母。
    func testZeroElapsedGivesNoRates() {
        let sample = frame(uptime: 10, received: 3000)
            .sample(previous: frame(uptime: 10, received: 1000))
        XCTAssertNil(sample.network)
    }

    /// 网卡计数器被重置（重启、网卡被 down/up）时不给速率，否则会画出一个负值或者巨大的尖峰。
    func testResetCountersGiveNoRates() {
        let sample = frame(uptime: 12, received: 10)
            .sample(previous: frame(uptime: 10, received: 1_000_000))
        XCTAssertNil(sample.network)
    }

    /// 缺 uptime（那一节读不到）时同样算不出速率。
    func testMissingUptimeGivesNoRates() {
        let previous = HostMetricsFrame(network: NetworkCounters(receivedBytes: 0, sentBytes: 0))
        let current = HostMetricsFrame(network: NetworkCounters(receivedBytes: 1000, sentBytes: 0))
        XCTAssertNil(current.sample(previous: previous).network)
    }

    // MARK: - 原样透传的那几项

    /// 内存、负载、磁盘不需要差分，一帧就够，第一帧就该有值。
    func testInstantMetricsPassThroughOnFirstFrame() throws {
        let frame = HostMetricsFrame(
            memory: MemoryInfo(total: 1000, available: 400, swapTotal: 0, swapFree: 0),
            load: LoadAverage(one: 1, five: 2, fifteen: 3),
            cpuCount: 4,
            disks: [DiskUsage(filesystem: "/dev/sda1", mountPoint: "/", totalBytes: 100, usedBytes: 50)]
        )

        let sample = frame.sample(previous: nil)
        XCTAssertEqual(try XCTUnwrap(sample.memory).used, 600)
        XCTAssertEqual(try XCTUnwrap(sample.load).fifteen, 3)
        XCTAssertEqual(sample.cpuCount, 4)
        XCTAssertEqual(sample.disks.count, 1)
    }

    /// `df` 偶尔会给出「已用比总量还大」的行（保留块），占比夹到 1 而不是超出图外。
    func testDiskFractionIsClamped() {
        let disk = DiskUsage(filesystem: "/dev/sda1", mountPoint: "/", totalBytes: 100, usedBytes: 120)
        XCTAssertEqual(disk.usedFraction, 1)
    }
}
