import XCTest
@testable import MoontermCore

final class SFTPListingParserTests: XCTestCase {

    /// 这段 fixture 是本机 `sftp -q -b - -D /usr/libexec/sftp-server` 真实跑出来的输出，
    /// 一个字都没改：包含回显行、`.` 与 `..`、`?` 硬链接数、名字里的空格、符号链接、
    /// 以及超过半年的文件那种「有年份没时刻」的日期。
    private let fixture = """
        sftp> ls -lan "/tmp/sftptest"
        drwxr-xr-x    ? moondo   wheel         256 Aug 25 13:22 /tmp/sftptest/.
        drwxrwxrwt    ? root     wheel        1760 Aug 25 13:22 /tmp/sftptest/..
        -rw-r--r--    ? moondo   wheel           0 Aug 25 13:22 /tmp/sftptest/.hidden
        -rw-r--r--    ? moondo   wheel           5 Aug 25 13:22 /tmp/sftptest/a.txt
        lrwxr-xr-x    ? moondo   wheel           5 Aug 25 13:22 /tmp/sftptest/link.txt
        -rw-r--r--    ? moondo   wheel           1 Aug 25 13:22 /tmp/sftptest/name with  spaces.txt
        -rw-r--r--    ? moondo   wheel           0 Jan  1  2020 /tmp/sftptest/old.txt
        drwxr-xr-x    ? moondo   wheel          64 Aug 25 13:22 /tmp/sftptest/sub
        """

    func testParsesRealSftpOutput() {
        let entries = SFTPListingParser.parse(fixture, directory: "/tmp/sftptest")

        // `.` 和 `..` 丢掉，回显行也不算一项；目录排在文件前面。
        XCTAssertEqual(
            entries.map { $0.name },
            ["sub", ".hidden", "a.txt", "link.txt", "name with  spaces.txt", "old.txt"]
        )
        XCTAssertEqual(entries.map { $0.path }.first, "/tmp/sftptest/sub")
    }

    func testKinds() {
        let entries = SFTPListingParser.parse(fixture, directory: "/tmp/sftptest")
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })

        XCTAssertEqual(byName["sub"]?.kind, .directory)
        XCTAssertEqual(byName["a.txt"]?.kind, .file)
        XCTAssertEqual(byName["link.txt"]?.kind, .symlink)
        // 符号链接可能指向目录，所以给它展开的机会。
        XCTAssertEqual(byName["link.txt"]?.isExpandable, true)
        XCTAssertEqual(byName["a.txt"]?.isExpandable, false)
    }

    /// 名字里带空格：只能从左边数着切字段，不能整行 split 完取最后一段。
    func testNameWithSpacesSurvives() {
        let entries = SFTPListingParser.parse(fixture, directory: "/tmp/sftptest")
        let entry = entries.first { $0.name.contains("spaces") }

        XCTAssertEqual(entry?.name, "name with  spaces.txt")
        XCTAssertEqual(entry?.path, "/tmp/sftptest/name with  spaces.txt")
        XCTAssertEqual(entry?.size, 1)
    }

    /// 近半年是 `Aug 25 13:22`，更早是 `Jan  1  2020` —— 两种都恰好 3 段，原样留着当显示文本。
    func testDateTextKeepsBothFormats() {
        let entries = SFTPListingParser.parse(fixture, directory: "/tmp/sftptest")
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })

        XCTAssertEqual(byName["a.txt"]?.dateText, "Aug 25 13:22")
        XCTAssertEqual(byName["old.txt"]?.dateText, "Jan 1 2020")
    }

    func testMetadataFields() {
        let entries = SFTPListingParser.parse(fixture, directory: "/tmp/sftptest")
        let entry = entries.first { $0.name == "a.txt" }

        XCTAssertEqual(entry?.modeText, "-rw-r--r--")
        XCTAssertEqual(entry?.owner, "moondo")
        XCTAssertEqual(entry?.group, "wheel")
        XCTAssertEqual(entry?.size, 5)
    }

    /// 传相对路径给 `ls` 时名字回来只有基名，也要能接上目录。
    func testBareNamesGetJoinedToDirectory() {
        let output = "-rw-r--r--    1 1000     1000         12 Aug 25 13:22 notes.txt"
        let entries = SFTPListingParser.parse(output, directory: "/home/me")

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].path, "/home/me/notes.txt")
        XCTAssertEqual(entries[0].owner, "1000")
    }

    /// sftp 的提示语、空行、错误文本混进来都不能变成一行「文件」。
    func testIgnoresNonRecordLines() {
        let output = """
            sftp> ls -lan "/nope"
            Remote working directory: /home/me
            Connected to example.com.

            -rw-r--r--    ? me       me              7 Aug 25 13:22 real.txt
            """
        let entries = SFTPListingParser.parse(output, directory: "/home/me")

        XCTAssertEqual(entries.map { $0.name }, ["real.txt"])
    }

    func testEmptyDirectoryYieldsNothing() {
        let output = "sftp> ls -lan \"/tmp/empty\""
        XCTAssertTrue(SFTPListingParser.parse(output, directory: "/tmp/empty").isEmpty)
    }

    /// 数字感知排序：`log2` 要排在 `log10` 前面。
    func testNumericAwareSorting() {
        let output = """
            -rw-r--r--    ? me       me              0 Aug 25 13:22 log10.txt
            -rw-r--r--    ? me       me              0 Aug 25 13:22 log2.txt
            drwxr-xr-x    ? me       me              0 Aug 25 13:22 zzz
            """
        let entries = SFTPListingParser.parse(output, directory: "/x")

        XCTAssertEqual(entries.map { $0.name }, ["zzz", "log2.txt", "log10.txt"])
    }

    // MARK: - 大小的显示

    func testDisplaySize() {
        XCTAssertEqual(RemoteFileEntry.formatBytes(0), "0 B")
        XCTAssertEqual(RemoteFileEntry.formatBytes(999), "999 B")
        XCTAssertEqual(RemoteFileEntry.formatBytes(1024), "1.0 K")
        XCTAssertEqual(RemoteFileEntry.formatBytes(10 * 1024), "10 K")
        XCTAssertEqual(RemoteFileEntry.formatBytes(1024 * 1024 * 3 / 2), "1.5 M")
    }

    /// 目录不显示大小：那个数字（macOS 上 256、Linux 上 4096）只会让人误以为是里面东西的总和。
    func testDirectoriesHaveNoDisplaySize() {
        let entries = SFTPListingParser.parse(fixture, directory: "/tmp/sftptest")
        XCTAssertNil(entries.first { $0.name == "sub" }?.displaySize)
        XCTAssertEqual(entries.first { $0.name == "a.txt" }?.displaySize, "5 B")
    }
}
