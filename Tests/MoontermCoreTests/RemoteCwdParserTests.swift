import XCTest
@testable import MoontermCore

final class RemoteCwdParserTests: XCTestCase {

    // MARK: - OSC 7

    func testOSC7() {
        XCTAssertEqual(RemoteCwdParser.fromOSC7("file://web1/var/log"), "/var/log")
        XCTAssertEqual(RemoteCwdParser.fromOSC7("file:///var/log"), "/var/log")
        // 有些实现只发路径不发 scheme。
        XCTAssertEqual(RemoteCwdParser.fromOSC7("/var/log"), "/var/log")
    }

    func testOSC7DecodesPercentEscapes() {
        XCTAssertEqual(RemoteCwdParser.fromOSC7("file://web1/home/me/a%20b"), "/home/me/a b")
    }

    /// 载荷末尾常带 `\r`。
    func testOSC7TrimsTrailingControlCharacters() {
        XCTAssertEqual(RemoteCwdParser.fromOSC7("file://web1/tmp\r\n"), "/tmp")
    }

    func testOSC7RejectsGarbage() {
        XCTAssertNil(RemoteCwdParser.fromOSC7(nil))
        XCTAssertNil(RemoteCwdParser.fromOSC7(""))
        XCTAssertNil(RemoteCwdParser.fromOSC7("file://web1"))  // 连路径都没有
        XCTAssertNil(RemoteCwdParser.fromOSC7("not a uri"))
    }

    // MARK: - xterm 标题

    /// Debian / Ubuntu 的 bash 默认 PS1 就是这个样子，覆盖面比 OSC 7 还大。
    func testTitleFromDefaultDebianPrompt() {
        XCTAssertEqual(RemoteCwdParser.fromTitle("me@web1: ~/logs"), "~/logs")
        XCTAssertEqual(RemoteCwdParser.fromTitle("root@web1: /var/log"), "/var/log")
        XCTAssertEqual(RemoteCwdParser.fromTitle("me@web1: ~"), "~")
    }

    /// 整个标题就是一个路径的情况也认。
    func testTitleThatIsJustAPath() {
        XCTAssertEqual(RemoteCwdParser.fromTitle("/srv/app"), "/srv/app")
    }

    /// 前缀 `user@host` 里不会有 `": "`，而目录名里可以有冒号 ——
    /// 所以取**第一个** `: ` 之后的全部，按最后一个切会把路径切断。
    func testTitleKeepsColonsInsideThePath() {
        XCTAssertEqual(RemoteCwdParser.fromTitle("me@web1: /data: backups"), "/data: backups")
    }

    /// 标题里远端爱写什么写什么。不像路径的一律不认 —— 塞一个不存在的目录给文件面板更糟。
    func testTitleRejectsNonPaths() {
        XCTAssertNil(RemoteCwdParser.fromTitle("vim notes.txt"))
        XCTAssertNil(RemoteCwdParser.fromTitle("root@web1"))
        XCTAssertNil(RemoteCwdParser.fromTitle(nil))
        XCTAssertNil(RemoteCwdParser.fromTitle(""))
    }

    // MARK: - 合并

    /// OSC 7 更可信：它专门用来报目录，标题只是顺带能猜。
    func testResolvePrefersOSC7() {
        XCTAssertEqual(
            RemoteCwdParser.resolve(osc7: "file://web1/srv", title: "me@web1: ~/logs", home: "/home/me"),
            "/srv"
        )
    }

    func testResolveFallsBackToTitleAndExpandsTilde() {
        XCTAssertEqual(
            RemoteCwdParser.resolve(osc7: nil, title: "me@web1: ~/logs", home: "/home/me"),
            "/home/me/logs"
        )
    }

    /// 家目录不知道时，`~` 那条线索作废（宁可不定位也别猜到别人家目录去）。
    func testResolveDropsTildeWithoutHome() {
        XCTAssertNil(RemoteCwdParser.resolve(osc7: nil, title: "me@web1: ~/logs", home: nil))
        // 同样情况下的绝对路径照样能用。
        XCTAssertEqual(
            RemoteCwdParser.resolve(osc7: nil, title: "me@web1: /var/log", home: nil),
            "/var/log"
        )
    }

    /// OSC 7 解不出来时要接着看标题，而不是直接放弃。
    func testResolveSkipsUnusableOSC7() {
        XCTAssertEqual(
            RemoteCwdParser.resolve(osc7: "garbage", title: "me@web1: /etc", home: "/home/me"),
            "/etc"
        )
    }

    func testResolveWithNothingUsable() {
        XCTAssertNil(RemoteCwdParser.resolve(osc7: nil, title: "vim x", home: "/home/me"))
    }
}
