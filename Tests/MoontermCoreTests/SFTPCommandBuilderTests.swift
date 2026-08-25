import XCTest
@testable import MoontermCore

final class SFTPCommandBuilderTests: XCTestCase {

    private let host = HostConfig(
        name: "web",
        host: "10.0.0.1",
        port: 2222,
        username: "root"
    )

    // MARK: - 命令行

    func testPlanReusesControlSocketAndNeverPrompts() {
        let plan = SFTPCommandBuilder.makePlan(config: host, controlPath: "/tmp/x.sock")

        XCTAssertEqual(plan.executable, "/usr/bin/sftp")
        XCTAssertEqual(plan.arguments.last, "root@10.0.0.1")
        XCTAssertTrue(plan.arguments.contains("-b"))
        // 只复用现成的 master，不自己开新的。
        XCTAssertTrue(hasOption(plan, "ControlMaster=no"))
        XCTAssertTrue(hasOption(plan, "ControlPath=/tmp/x.sock"))
        // 绝不交互提问：master 不在时要立刻报错，而不是挂着等一个看不见的密码提示。
        XCTAssertTrue(hasOption(plan, "BatchMode=yes"))
        XCTAssertTrue(plan.arguments.contains("2222"))
    }

    // MARK: - 引号

    /// 双引号本身就把 glob 关掉了（实测：不加引号 `star*.txt` 会匹配到 `starX.txt`），
    /// 所以只转义 `\` 和 `"`，**不**给 `*` `?` `[` 补反斜杠 —— 补了反而找不到文件。
    func testQuoteOnlyEscapesBackslashAndQuote() {
        XCTAssertEqual(SFTPCommandBuilder.quote("/tmp/a b.txt"), "\"/tmp/a b.txt\"")
        XCTAssertEqual(SFTPCommandBuilder.quote("/tmp/star*.txt"), "\"/tmp/star*.txt\"")
        XCTAssertEqual(SFTPCommandBuilder.quote("/tmp/br[a]ck"), "\"/tmp/br[a]ck\"")
        XCTAssertEqual(SFTPCommandBuilder.quote("/tmp/quo\"te"), "\"/tmp/quo\\\"te\"")
        XCTAssertEqual(SFTPCommandBuilder.quote("/tmp/back\\slash"), "\"/tmp/back\\\\slash\"")
    }

    /// `-n` 不能去掉：不带它 sftp 打印的是**服务端**给的 longname，格式随服务端变。
    func testListAlwaysUsesNumericAndAll() {
        XCTAssertEqual(SFTPCommandBuilder.list(directory: "/var/log"), "ls -lan \"/var/log\"")
    }

    func testTransferCommands() {
        XCTAssertEqual(
            SFTPCommandBuilder.get(remote: "/a/b.txt", local: "/tmp/b.txt", recursive: false),
            "get -p \"/a/b.txt\" \"/tmp/b.txt\""
        )
        XCTAssertEqual(
            SFTPCommandBuilder.get(remote: "/a/dir", local: "/tmp/dir", recursive: true),
            "get -rp \"/a/dir\" \"/tmp/dir\""
        )
        XCTAssertEqual(
            SFTPCommandBuilder.put(local: "/tmp/b.txt", remote: "/a/b.txt", recursive: false),
            "put -p \"/tmp/b.txt\" \"/a/b.txt\""
        )
    }

    // MARK: - 批处理

    /// 不加 sftp 的「错了也接着跑」前缀：加了它 sftp 一律以退出码 0 收场，
    /// 成没成只能去猜 stderr，而 ssh 自己也会往 stderr 写警告，一猜就会误判。
    func testBatchScriptDoesNotSuppressErrors() {
        XCTAssertEqual(
            SFTPCommandBuilder.batchScript(["pwd", "ls -lan \"/\""]),
            "pwd\nls -lan \"/\"\n"
        )
    }

    func testSplitBatchOutputUsesEchoLines() {
        let commands = ["pwd", "ls -lan \"/a\"", "ls -lan \"/b\""]
        let stdout = """
            sftp> pwd
            Remote working directory: /home/me
            sftp> ls -lan "/a"
            drwxr-xr-x    ? me       me            64 Aug 25 13:22 /a/sub
            sftp> ls -lan "/b"
            """

        let outputs = SFTPCommandBuilder.splitBatchOutput(stdout, commands: commands)

        XCTAssertEqual(outputs.count, 3)
        XCTAssertEqual(outputs[0], "Remote working directory: /home/me")
        XCTAssertTrue(outputs[1]?.contains("/a/sub") == true)
        XCTAssertEqual(outputs[2], "")  // 空目录：有回显没内容
    }

    /// 一条失败就整批中断，还没轮到的那些是 nil，而不是被当成「空目录」。
    func testSplitBatchOutputMarksMissingCommandsNil() {
        let commands = ["pwd", "ls -lan \"/a\""]
        let outputs = SFTPCommandBuilder.splitBatchOutput("sftp> pwd\nRemote working directory: /\n", commands: commands)

        XCTAssertEqual(outputs[0], "Remote working directory: /\n")
        XCTAssertNil(outputs[1])
    }

    /// 命令输出里恰好有一行长得像回显时，不能把分帧带偏 —— 只认「下一条」的原文。
    func testSplitBatchOutputIgnoresLookalikeLines() {
        let commands = ["ls -lan \"/a\""]
        let stdout = """
            sftp> ls -lan "/a"
            sftp> ls -lan "/somewhere-else"
            -rw-r--r--    ? me       me             1 Aug 25 13:22 /a/x
            """

        let outputs = SFTPCommandBuilder.splitBatchOutput(stdout, commands: commands)

        XCTAssertTrue(outputs[0]?.contains("/somewhere-else") == true)
        XCTAssertTrue(outputs[0]?.contains("/a/x") == true)
    }

    // MARK: - 杂项解析

    func testParsePwd() {
        XCTAssertEqual(
            SFTPCommandBuilder.parsePwd("Remote working directory: /home/me\n"),
            "/home/me"
        )
        XCTAssertNil(SFTPCommandBuilder.parsePwd("nothing here"))
    }

    func testFirstErrorSkipsBlankLines() {
        XCTAssertEqual(
            SFTPCommandBuilder.firstError(in: "\n\nCan't ls: \"/nope\" not found\nsecond line\n"),
            "Can't ls: \"/nope\" not found"
        )
        XCTAssertNil(SFTPCommandBuilder.firstError(in: "  \n"))
    }

    // MARK: - 辅助

    private func hasOption(_ plan: SSHLaunchPlan, _ option: String) -> Bool {
        for (index, argument) in plan.arguments.enumerated() where argument == "-o" {
            if plan.arguments.indices.contains(index + 1), plan.arguments[index + 1] == option {
                return true
            }
        }
        return false
    }
}
