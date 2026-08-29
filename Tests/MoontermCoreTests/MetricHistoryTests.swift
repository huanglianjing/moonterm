import XCTest
@testable import MoontermCore

final class MetricHistoryTests: XCTestCase {

    func testKeepsOnlyTheMostRecentSamples() {
        var history = MetricHistory(capacity: 3)
        [1, 2, 3, 4, 5].forEach { history.append(Double($0)) }

        XCTAssertEqual(history.values, [3, 4, 5])
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history.latest, 5)
    }

    func testMaximumIsTheWindowPeak() {
        var history = MetricHistory(capacity: 3)
        [9, 1, 2, 3].forEach { history.append(Double($0)) }

        // 9 已经被挤出窗口了，峰值该跟着降下来 —— 否则网络那张图的 y 轴会永远停在
        // 十分钟前那一次下载上，之后的曲线全被压成一条贴底的线。
        XCTAssertEqual(history.maximum, 3)
    }

    func testEmptyHistory() {
        let history = MetricHistory(capacity: 5)

        XCTAssertTrue(history.isEmpty)
        XCTAssertNil(history.latest)
        XCTAssertNil(history.maximum)
    }

    func testRemoveAll() {
        var history = MetricHistory(capacity: 5)
        history.append(1)
        history.removeAll()

        XCTAssertTrue(history.isEmpty)
    }

    /// 容量至少是 1，别让 0 或负数把下标算炸。
    func testCapacityIsAtLeastOne() {
        var history = MetricHistory(capacity: 0)
        history.append(1)
        history.append(2)

        XCTAssertEqual(history.capacity, 1)
        XCTAssertEqual(history.values, [2])
    }
}
