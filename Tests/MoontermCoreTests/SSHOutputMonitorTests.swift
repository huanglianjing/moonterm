import XCTest
@testable import MoontermCore

final class SSHOutputMonitorTests: XCTestCase {

    private func feed(_ monitor: SSHOutputMonitor, _ text: String) -> String? {
        monitor.consume(ArraySlice(Array(text.utf8)))
    }

    // MARK: - 密码兜底注入

    func testInjectsPasswordOnSSHPrompt() {
        let monitor = SSHOutputMonitor(password: "s3cret")
        XCTAssertEqual(feed(monitor, "root@10.0.0.1's password: "), "s3cret\n")
        XCTAssertTrue(monitor.didInjectPassword)
    }

    func testInjectsOnlyOnce() {
        let monitor = SSHOutputMonitor(password: "s3cret")
        XCTAssertNotNil(feed(monitor, "root@10.0.0.1's password: "))
        XCTAssertNil(feed(monitor, "\r\nPermission denied, please try again.\r\nPassword: "))
    }

    func testDoesNotInjectForSudoPrompt() {
        let monitor = SSHOutputMonitor(password: "s3cret")
        XCTAssertNil(feed(monitor, "[sudo] password for deploy: "))
        XCTAssertFalse(monitor.didInjectPassword)
    }

    func testDoesNotInjectWhenDisabled() {
        let monitor = SSHOutputMonitor(password: "s3cret")
        monitor.passwordInjectionEnabled = false
        XCTAssertNil(feed(monitor, "root@10.0.0.1's password: "))
    }

    func testDoesNotInjectWithoutPassword() {
        let monitor = SSHOutputMonitor(password: "")
        XCTAssertNil(feed(monitor, "root@10.0.0.1's password: "))
    }

    func testDoesNotInjectOnOrdinaryOutput() {
        let monitor = SSHOutputMonitor(password: "s3cret")
        XCTAssertNil(feed(monitor, "Last login: Wed Aug 20 22:00:00 2026\r\ndeploy@host:~$ "))
    }

    /// 远端 shell 里恰好以 `password:` 结尾的输出不能触发注入 —— 判定落在「整行」上。
    func testDoesNotInjectWhenRemoteOutputMerelyEndsWithPassword() {
        let monitor = SSHOutputMonitor(password: "s3cret")
        XCTAssertNil(feed(monitor, "deploy@host:~$ echo password:"))
        XCTAssertFalse(monitor.didInjectPassword)
    }

    /// keyboard-interactive / PAM 的提示是单独一行的 `Password:`。
    /// 注意 Swift 把 "\r\n" 当一个 Character，拆行时必须先归一化换行。
    func testRecognizesKeyboardInteractivePrompt() {
        let monitor = SSHOutputMonitor(password: "s3cret")
        XCTAssertEqual(feed(monitor, "deploy@host\r\nPassword: "), "s3cret\n")
    }

    func testHandlesPromptSplitAcrossChunks() {
        let monitor = SSHOutputMonitor(password: "s3cret")
        XCTAssertNil(feed(monitor, "root@10.0.0.1's pas"))
        XCTAssertEqual(feed(monitor, "sword: "), "s3cret\n")
    }

    func testRecognizesKeyPassphrasePrompt() {
        let monitor = SSHOutputMonitor(password: "s3cret")
        XCTAssertEqual(feed(monitor, "Enter passphrase for key '/Users/x/.ssh/id_ed25519': "), "s3cret\n")
    }

    // MARK: - 失败归因

    func testClassifiesAuthFailure() {
        let monitor = SSHOutputMonitor(password: "")
        _ = feed(monitor, "Permission denied (publickey,password).\r\n")
        XCTAssertEqual(monitor.diagnostic, "认证失败：用户名或密码不正确")
    }

    func testClassifiesChangedHostKeyBeforeGenericHostKeyFailure() {
        let text = """
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!
        Host key verification failed.
        """
        let reason = SSHOutputMonitor.classifyFailure(in: text)
        XCTAssertEqual(reason?.contains("服务端主机密钥变了"), true)
    }

    func testClassifiesConnectionRefused() {
        XCTAssertEqual(
            SSHOutputMonitor.classifyFailure(in: "ssh: connect to host 10.0.0.1 port 22: Connection refused"),
            "连接被拒绝：目标端口没有服务在监听，或被防火墙拦掉了"
        )
    }

    func testNoDiagnosticForNormalOutput() {
        XCTAssertNil(SSHOutputMonitor.classifyFailure(in: "deploy@host:~$ ls\r\nREADME.md\r\n"))
    }

    func testResetClearsState() {
        let monitor = SSHOutputMonitor(password: "s3cret")
        _ = feed(monitor, "root@10.0.0.1's password: ")
        _ = feed(monitor, "Permission denied\r\n")
        monitor.reset()
        XCTAssertNil(monitor.diagnostic)
        XCTAssertFalse(monitor.didInjectPassword)
        XCTAssertEqual(feed(monitor, "root@10.0.0.1's password: "), "s3cret\n")
    }
}
