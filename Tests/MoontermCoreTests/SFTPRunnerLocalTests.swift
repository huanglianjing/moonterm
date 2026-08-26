import XCTest
@testable import MoontermCore

/// `SFTPRunner` + 命令拼装 + 输出解析的**全链路**测试，不需要网络也不需要一台可连的主机。
///
/// 手法是 sftp 自带的 `-D`：让它把 `/usr/libexec/sftp-server` 当子进程直接起在本地，
/// 走的还是真的 SFTP 协议，只是省掉了 ssh 那一段。所以引号规则、批处理分帧、`ls -lan` 的
/// 输出格式这些「跟 sftp 约定好的事」全都是真刀真枪验过的，而不是照文档猜的。
///
/// 唯一测不到的是 ControlMaster 复用与认证 —— 那必须有真远端。
final class SFTPRunnerLocalTests: XCTestCase {

    private static let sftpServer = "/usr/libexec/sftp-server"

    private var directory: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: Self.sftpServer),
            "本机没有 \(Self.sftpServer)"
        )
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: SFTPCommandBuilder.sftpExecutable),
            "本机没有 \(SFTPCommandBuilder.sftpExecutable)"
        )

        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moonterm-sftp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// 本地起 sftp-server，绕开 ssh。环境用的是**上线时那一份**，
    /// 这样 locale 相关的行为在这里测到的就是真实行为。
    private func plan(environment: [String] = SFTPCommandBuilder.forcedEnvironment) -> SSHLaunchPlan {
        SSHLaunchPlan(
            executable: SFTPCommandBuilder.sftpExecutable,
            arguments: ["-b", "-", "-q", "-D", Self.sftpServer],
            environment: environment
        )
    }

    private func run(
        _ commands: [String],
        environment: [String] = SFTPCommandBuilder.forcedEnvironment
    ) throws -> SFTPRunner.Outcome {
        let expectation = expectation(description: "sftp 跑完")
        var result: SFTPRunner.Outcome?
        SFTPRunner().start(plan: plan(environment: environment), commands: commands, timeout: 30) { outcome in
            result = outcome
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 40)
        return try XCTUnwrap(result)
    }

    private func write(_ contents: String, to name: String) throws {
        try Data(contents.utf8).write(to: directory.appendingPathComponent(name))
    }

    // MARK: - 列目录

    func testListsDirectory() throws {
        try write("hello", to: "a.txt")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("sub"),
            withIntermediateDirectories: false
        )

        let command = SFTPCommandBuilder.list(directory: directory.path)
        let outcome = try run([command])

        XCTAssertTrue(outcome.isSuccess, outcome.stderr)
        let entries = SFTPListingParser.parse(try XCTUnwrap(outcome.outputs[0]), directory: directory.path)
        XCTAssertEqual(entries.map { $0.name }, ["sub", "a.txt"])
        XCTAssertEqual(entries.last?.size, 5)
        XCTAssertEqual(entries.first?.kind, .directory)
    }

    /// 一次调用跑多条命令，靠 sftp 的回显行切分 —— 「展开到某个深路径」就是这么干的。
    func testBatchOfSeveralListingsIsFramedCorrectly() throws {
        let nested = directory.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try write("x", to: "a/top.txt")

        let commands = [
            SFTPCommandBuilder.list(directory: directory.path),
            SFTPCommandBuilder.list(directory: directory.appendingPathComponent("a").path),
            SFTPCommandBuilder.list(directory: nested.path)
        ]
        let outcome = try run(commands)

        XCTAssertTrue(outcome.isSuccess, outcome.stderr)
        XCTAssertEqual(outcome.outputs.count, 3)
        XCTAssertEqual(
            SFTPListingParser.parse(try XCTUnwrap(outcome.outputs[0]), directory: directory.path).map { $0.name },
            ["a"]
        )
        XCTAssertEqual(
            SFTPListingParser.parse(
                try XCTUnwrap(outcome.outputs[1]),
                directory: directory.appendingPathComponent("a").path
            ).map { $0.name },
            ["b", "top.txt"]
        )
        XCTAssertTrue(
            SFTPListingParser.parse(try XCTUnwrap(outcome.outputs[2]), directory: nested.path).isEmpty
        )
    }

    /// 一条失败就整批中断（批处理模式的默认行为，我们**故意**没去抑制它）：
    /// 失败前已经列出来的照样能用，失败之后的那些是 nil，退出码非 0，原因在 stderr。
    ///
    /// 「展开到某个深路径」正需要这个语义 —— 那串目录是由外到内的，
    /// 中间一级进不去，比它更深的几级本来也进不去。
    func testFailingCommandAbortsTheRestButKeepsWhatWasListed() throws {
        try write("x", to: "a.txt")

        let commands = [
            SFTPCommandBuilder.list(directory: directory.path),
            SFTPCommandBuilder.list(directory: "/definitely/not/here"),
            SFTPCommandBuilder.pwd
        ]
        let outcome = try run(commands)

        XCTAssertFalse(outcome.isSuccess)
        // 错误走 stderr，不会混进 stdout 的分帧里。
        XCTAssertTrue(outcome.stderr.contains("not found"), outcome.stderr)
        XCTAssertEqual(
            SFTPListingParser.parse(try XCTUnwrap(outcome.outputs[0]), directory: directory.path).map { $0.name },
            ["a.txt"]
        )
        XCTAssertNil(outcome.outputs[2])
    }

    func testPwdReportsStartingDirectory() throws {
        let outcome = try run([SFTPCommandBuilder.pwd])

        XCTAssertTrue(outcome.isSuccess, outcome.stderr)
        XCTAssertNotNil(SFTPCommandBuilder.parsePwd(try XCTUnwrap(outcome.outputs[0])))
    }

    // MARK: - 名字里的怪字符

    /// `quote()` 只转义 `\` 和 `"`，靠双引号把 glob 关掉。这条测的就是那个判断成不成立：
    /// 名字里带 `*` 的文件必须**只**命中它自己，不能顺手把 `starX.txt` 也匹配进来。
    func testQuotingSuppressesGlobbing() throws {
        try write("A", to: "star*.txt")
        try write("B", to: "starX.txt")

        let command = SFTPCommandBuilder.list(directory: directory.appendingPathComponent("star*.txt").path)
        let outcome = try run([command])

        XCTAssertTrue(outcome.isSuccess, outcome.stderr)
        let entries = SFTPListingParser.parse(try XCTUnwrap(outcome.outputs[0]), directory: directory.path)
        XCTAssertEqual(entries.map { $0.name }, ["star*.txt"])
    }

    func testQuotingHandlesSpacesQuotesAndBrackets() throws {
        let names = ["sp ace.txt", "quo\"te.txt", "br[a]ck.txt", "back\\slash.txt"]
        for name in names {
            try write("x", to: name)
        }

        let outcome = try run([SFTPCommandBuilder.list(directory: directory.path)])
        let listed = SFTPListingParser.parse(try XCTUnwrap(outcome.outputs[0]), directory: directory.path)
        XCTAssertEqual(Set(listed.map { $0.name }), Set(names))

        // 逐个再单独取一次，确认 quote() 拼出来的参数真能被 sftp 接住。
        for name in names {
            let path = directory.appendingPathComponent(name).path
            let single = try run([SFTPCommandBuilder.list(directory: path)])
            XCTAssertTrue(single.isSuccess, "\(name)：\(single.stderr)")
            XCTAssertEqual(
                SFTPListingParser.parse(try XCTUnwrap(single.outputs[0]), directory: directory.path).map { $0.name },
                [name],
                "取不到 \(name)"
            )
        }
    }

    // MARK: - 非 ASCII 文件名

    /// 中文名字要原样列出来、并且能照原样取回去。
    ///
    /// 靠的是 `SFTPCommandBuilder.forcedEnvironment` 里那个 UTF-8 的 `LC_ALL`；
    /// 下面那条测试说明少了它会怎样。
    func testChineseNamesSurviveListingAndDownload() throws {
        try write("内容", to: "中文文件.txt")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("配置（备份）"),
            withIntermediateDirectories: false
        )

        let outcome = try run([SFTPCommandBuilder.list(directory: directory.path)])
        let entries = SFTPListingParser.parse(try XCTUnwrap(outcome.outputs[0]), directory: directory.path)
        XCTAssertEqual(entries.map { $0.name }, ["配置（备份）", "中文文件.txt"])

        // 列出来的路径要能直接拿去下载 —— 名字被转义过的话这一步就会失败。
        let target = directory.appendingPathComponent("下载.txt")
        let download = try run([
            SFTPCommandBuilder.get(remote: try XCTUnwrap(entries.last).path, local: target.path, recursive: false)
        ])
        XCTAssertTrue(download.isSuccess, download.stderr)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "内容")
    }

    /// 反面对照：locale 不是 UTF-8 时，sftp 会把非 ASCII 字节按八进制转义打出来。
    ///
    /// 这条测试是给 `forcedEnvironment` 那行代码留的**理由** —— 从 `.app` 启动时环境里
    /// 本来就没有 `LANG`（Finder 不给），删掉那行就会退化成这个样子。
    func testWithoutUTF8LocaleNamesComeBackEscaped() throws {
        try write("内容", to: "中文文件.txt")

        let outcome = try run([SFTPCommandBuilder.list(directory: directory.path)], environment: ["LC_ALL=C"])
        let stdout = try XCTUnwrap(outcome.outputs[0])

        XCTAssertFalse(stdout.contains("中文文件.txt"))
        XCTAssertTrue(stdout.contains("\\344\\270\\255"), stdout)
    }

    // MARK: - 传输

    func testDownloadAndUpload() throws {
        try write("payload", to: "src.txt")
        let downloaded = directory.appendingPathComponent("down loaded.txt")
        let uploaded = directory.appendingPathComponent("up loaded.txt")

        let outcome = try run([
            SFTPCommandBuilder.get(
                remote: directory.appendingPathComponent("src.txt").path,
                local: downloaded.path,
                recursive: false
            ),
            SFTPCommandBuilder.put(local: downloaded.path, remote: uploaded.path, recursive: false)
        ])

        XCTAssertTrue(outcome.isSuccess, outcome.stderr)
        XCTAssertEqual(try String(contentsOf: downloaded, encoding: .utf8), "payload")
        XCTAssertEqual(try String(contentsOf: uploaded, encoding: .utf8), "payload")
    }

    func testRecursiveDownload() throws {
        let source = directory.appendingPathComponent("tree/inner")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try write("deep", to: "tree/inner/leaf.txt")
        let destination = directory.appendingPathComponent("copy")

        let outcome = try run([
            SFTPCommandBuilder.get(
                remote: directory.appendingPathComponent("tree").path,
                local: destination.path,
                recursive: true
            )
        ])

        XCTAssertTrue(outcome.isSuccess, outcome.stderr)
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("inner/leaf.txt"), encoding: .utf8),
            "deep"
        )
    }

    // MARK: - 远端修改

    func testCreateRenameAndDeleteFileAndEmptyDirectory() throws {
        let folder = directory.appendingPathComponent("新目录")
        let renamedFolder = directory.appendingPathComponent("改过名")
        let file = renamedFolder.appendingPathComponent("旧.txt")
        let renamedFile = renamedFolder.appendingPathComponent("新.txt")

        var outcome = try run([SFTPCommandBuilder.makeDirectory(folder.path)])
        XCTAssertTrue(outcome.isSuccess, outcome.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        outcome = try run([SFTPCommandBuilder.rename(from: folder.path, to: renamedFolder.path)])
        XCTAssertTrue(outcome.isSuccess, outcome.stderr)
        try Data("内容".utf8).write(to: file)

        outcome = try run([SFTPCommandBuilder.rename(from: file.path, to: renamedFile.path)])
        XCTAssertTrue(outcome.isSuccess, outcome.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamedFile.path))

        outcome = try run([
            SFTPCommandBuilder.removeFile(renamedFile.path),
            SFTPCommandBuilder.removeDirectory(renamedFolder.path)
        ])
        XCTAssertTrue(outcome.isSuccess, outcome.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamedFolder.path))
    }

    func testRecursiveDeletionPlanRemovesNonEmptyDirectory() throws {
        let tree = directory.appendingPathComponent("tree")
        let nested = tree.appendingPathComponent("a/b")
        let outside = directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("root".utf8).write(to: tree.appendingPathComponent("root.txt"))
        try Data("deep".utf8).write(to: nested.appendingPathComponent("deep.txt"))
        try Data("keep".utf8).write(to: outside.appendingPathComponent("keep.txt"))
        try FileManager.default.createSymbolicLink(
            at: tree.appendingPathComponent("outside-link"),
            withDestinationURL: outside
        )

        var plan = SFTPRecursiveDeletionPlan(rootDirectory: tree.path)
        while let path = plan.nextDirectory {
            let listing = try run([SFTPCommandBuilder.list(directory: path)])
            XCTAssertTrue(listing.isSuccess, listing.stderr)
            let entries = SFTPListingParser.parse(try XCTUnwrap(listing.outputs[0]), directory: path)
            XCTAssertTrue(plan.record(contents: entries, of: path))
        }

        let commands = try XCTUnwrap(plan.deletionCommands)
        for batch in SFTPCommandBuilder.commandBatches(commands) {
            let deletion = try run(batch)
            XCTAssertTrue(deletion.isSuccess, deletion.stderr)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tree.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outside.appendingPathComponent("keep.txt").path),
            "递归删除只能删符号链接本身，绝不能跟到目标目录里"
        )
    }

    // MARK: - 失败与收尾

    func testFailureCarriesReadableMessage() throws {
        let outcome = try run([SFTPCommandBuilder.list(directory: "/definitely/not/here")])

        XCTAssertNotNil(outcome.errorMessage)
        XCTAssertTrue(try XCTUnwrap(outcome.errorMessage).contains("not found"))
    }

    /// 起不来的可执行文件也要老实回调一次，不能把调用方挂在那儿。
    func testMissingExecutableStillCallsBack() throws {
        let expectation = expectation(description: "回调了")
        var result: SFTPRunner.Outcome?
        SFTPRunner().start(
            plan: SSHLaunchPlan(executable: "/nope/sftp", arguments: [], environment: []),
            commands: ["pwd"]
        ) { outcome in
            result = outcome
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)

        let outcome = try XCTUnwrap(result)
        XCTAssertFalse(outcome.isSuccess)
        XCTAssertNotNil(outcome.errorMessage)
    }
}
