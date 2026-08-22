import XCTest
@testable import MoontermCore

final class TerminalTabTests: XCTestCase {

    private let host = HostConfig(name: "线上机", host: "10.0.0.1", username: "root")
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()

    private func makeTab() -> TerminalTab {
        TerminalTab(host: host, sessionID: a)
    }

    // MARK: - 主机绑定

    func testTabTitleIsHostName() {
        let tab = makeTab()
        XCTAssertEqual(tab.title, "线上机")
        XCTAssertEqual(tab.host.id, host.id)
    }

    // MARK: - 窗口编号

    func testFirstSessionIsWindowOne() {
        let tab = makeTab()
        XCTAssertEqual(tab.windowNumber(of: a), 1)
        XCTAssertEqual(tab.windowName(of: a), "窗口1")
        XCTAssertEqual(tab.sessionCount, 1)
        XCTAssertEqual(tab.paneCount, 1)
    }

    func testSubsequentSessionsCountUp() {
        var tab = makeTab()
        tab.root.insert(sessionID: b, relativeTo: a, edge: .trailing)
        XCTAssertEqual(tab.assignWindowNumber(to: b), 2)
        tab.root.join(sessionID: c, into: b, at: nil)
        XCTAssertEqual(tab.assignWindowNumber(to: c), 3)

        XCTAssertEqual(tab.windowName(of: b), "窗口2")
        XCTAssertEqual(tab.windowName(of: c), "窗口3")
    }

    func testAssignIsIdempotent() {
        var tab = makeTab()
        XCTAssertEqual(tab.assignWindowNumber(to: b), 2)
        // 再调一次不会改名，也不会占掉新号。
        XCTAssertEqual(tab.assignWindowNumber(to: b), 2)
        XCTAssertEqual(tab.assignWindowNumber(to: c), 3)
    }

    func testReleasedNumberIsReused() {
        var tab = makeTab()
        tab.assignWindowNumber(to: b)  // 窗口2
        tab.assignWindowNumber(to: c)  // 窗口3

        tab.releaseWindowNumber(of: b)
        XCTAssertNil(tab.windowNumber(of: b))

        // 补最小空缺：不是 4。
        let reborn = UUID()
        XCTAssertEqual(tab.assignWindowNumber(to: reborn), 2)
        XCTAssertEqual(tab.windowNumber(of: c), 3, "别的窗口编号不受影响")
    }

    func testUnregisteredSessionFallsBackToVisualOrder() {
        var tab = makeTab()
        tab.root.insert(sessionID: b, relativeTo: a, edge: .trailing)
        // 故意不登记编号。
        XCTAssertNil(tab.windowNumber(of: b))
        XCTAssertEqual(tab.windowName(of: b), "窗口2")
    }
}
