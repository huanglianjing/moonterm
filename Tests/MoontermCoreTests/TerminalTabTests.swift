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

    // MARK: - 重命名

    func testRenameReplacesDisplayedName() {
        var tab = makeTab()
        tab.rename(sessionID: a, to: "编译")

        XCTAssertEqual(tab.windowName(of: a), "编译")
        XCTAssertEqual(tab.customName(of: a), "编译")
        XCTAssertEqual(tab.defaultWindowName(of: a), "窗口1", "默认名字还在，清空后要能回去")
        XCTAssertEqual(tab.windowNumber(of: a), 1, "改名不影响编号分配")
    }

    func testRenameTrimsWhitespaceAndClampsLength() {
        var tab = makeTab()
        tab.rename(sessionID: a, to: "  日志  ")
        XCTAssertEqual(tab.windowName(of: a), "日志")

        let long = String(repeating: "长", count: TerminalTab.maximumNameLength + 10)
        tab.rename(sessionID: a, to: long)
        XCTAssertEqual(tab.windowName(of: a).count, TerminalTab.maximumNameLength)
    }

    func testEmptyNameRestoresDefault() {
        var tab = makeTab()
        tab.rename(sessionID: a, to: "编译")
        tab.rename(sessionID: a, to: "   ")

        XCTAssertNil(tab.customName(of: a))
        XCTAssertEqual(tab.windowName(of: a), "窗口1")
    }

    func testRenameIgnoresSessionsOutsideTheTab() {
        var tab = makeTab()
        tab.rename(sessionID: b, to: "别人家的窗口")
        XCTAssertNil(tab.customName(of: b))
    }

    func testClosedWindowDoesNotLeaveItsNameToTheNextOne() {
        var tab = makeTab()
        tab.root.insert(sessionID: b, relativeTo: a, edge: .trailing)
        tab.assignWindowNumber(to: b)
        tab.rename(sessionID: b, to: "编译")

        tab.root.remove(sessionID: b)
        tab.releaseWindowNumber(of: b)

        // 编号 2 被复用时不能顶着上一个窗口的名字。
        let reborn = UUID()
        tab.root.insert(sessionID: reborn, relativeTo: a, edge: .trailing)
        XCTAssertEqual(tab.assignWindowNumber(to: reborn), 2)
        XCTAssertNil(tab.customName(of: reborn))
        XCTAssertEqual(tab.windowName(of: reborn), "窗口2")
    }
}
