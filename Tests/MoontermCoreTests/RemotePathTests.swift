import XCTest
@testable import MoontermCore

final class RemotePathTests: XCTestCase {

    // MARK: - 规范化

    func testNormalizeCollapsesSlashesAndTrailingSlash() {
        XCTAssertEqual(RemotePath.normalize("/a//b/"), "/a/b")
        XCTAssertEqual(RemotePath.normalize("/"), "/")
        XCTAssertEqual(RemotePath.normalize("///"), "/")
    }

    func testNormalizeResolvesDotSegments() {
        XCTAssertEqual(RemotePath.normalize("/a/./b"), "/a/b")
        XCTAssertEqual(RemotePath.normalize("/a/b/.."), "/a")
        XCTAssertEqual(RemotePath.normalize("/a/../../b"), "/b")  // 根上再往上就停在根
    }

    /// 相对路径要保持相对，`..` 也不能被吃掉 —— 否则会静默指到别的地方去。
    func testNormalizeKeepsRelativePaths() {
        XCTAssertEqual(RemotePath.normalize("a/b"), "a/b")
        XCTAssertEqual(RemotePath.normalize("../a"), "../a")
        XCTAssertEqual(RemotePath.normalize("."), ".")
    }

    // MARK: - 拼接与拆解

    func testJoin() {
        XCTAssertEqual(RemotePath.join("/a", "b"), "/a/b")
        XCTAssertEqual(RemotePath.join("/", "b"), "/b")
        XCTAssertEqual(RemotePath.join("/a", "/b"), "/b")  // 绝对路径直接取代
    }

    func testParentStopsAtRoot() {
        XCTAssertEqual(RemotePath.parent(of: "/a/b"), "/a")
        XCTAssertEqual(RemotePath.parent(of: "/a"), "/")
        XCTAssertEqual(RemotePath.parent(of: "/"), "/")
    }

    func testName() {
        XCTAssertEqual(RemotePath.name(of: "/a/b.txt"), "b.txt")
        XCTAssertEqual(RemotePath.name(of: "/a/"), "a")
        XCTAssertEqual(RemotePath.name(of: "/"), "/")
        XCTAssertEqual(RemotePath.name(of: "/a/name with spaces"), "name with spaces")
    }

    func testValidRemoteName() {
        XCTAssertTrue(RemotePath.isValidName("普通文件.txt"))
        XCTAssertTrue(RemotePath.isValidName("star*.txt"))
        XCTAssertTrue(RemotePath.isValidName(" name "))
        XCTAssertFalse(RemotePath.isValidName(""))
        XCTAssertFalse(RemotePath.isValidName("."))
        XCTAssertFalse(RemotePath.isValidName(".."))
        XCTAssertFalse(RemotePath.isValidName("a/b"))
        XCTAssertFalse(RemotePath.isValidName("a\0b"))
    }

    /// 文件树「展开到某个深路径」按这个顺序逐级列目录，面包屑也用同一份。
    func testAncestorsAreOutsideIn() {
        XCTAssertEqual(RemotePath.ancestors(of: "/a/b/c"), ["/", "/a", "/a/b", "/a/b/c"])
        XCTAssertEqual(RemotePath.ancestors(of: "/"), ["/"])
    }

    // MARK: - 波浪号

    func testExpandTilde() {
        XCTAssertEqual(RemotePath.expandTilde("~", home: "/home/me"), "/home/me")
        XCTAssertEqual(RemotePath.expandTilde("~/logs", home: "/home/me"), "/home/me/logs")
        XCTAssertEqual(RemotePath.expandTilde("/var/log", home: "/home/me"), "/var/log")
    }

    /// 不知道家目录时宁可不定位，也别猜。
    func testExpandTildeWithoutHomeFails() {
        XCTAssertNil(RemotePath.expandTilde("~/logs", home: nil))
        XCTAssertNil(RemotePath.expandTilde("~/logs", home: ""))
    }

    /// `~someone` 要问远端的 passwd，这里拿不到，所以不认。
    func testExpandTildeRejectsOtherUsers() {
        XCTAssertNil(RemotePath.expandTilde("~root/x", home: "/home/me"))
    }

    // MARK: - 包含关系

    func testIsDescendant() {
        XCTAssertTrue(RemotePath.isDescendant("/a/b", of: "/a"))
        XCTAssertTrue(RemotePath.isDescendant("/a", of: "/a"))
        XCTAssertTrue(RemotePath.isDescendant("/a", of: "/"))
        XCTAssertFalse(RemotePath.isDescendant("/ab", of: "/a"))  // 不能只比前缀
        XCTAssertFalse(RemotePath.isDescendant("/a", of: "/a/b"))
    }
}
