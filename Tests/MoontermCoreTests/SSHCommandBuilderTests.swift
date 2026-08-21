import XCTest
@testable import MoontermCore

final class SSHCommandBuilderTests: XCTestCase {

    private func config(
        host: String = "10.0.0.1",
        port: Int = 22,
        username: String = "root",
        acceptNewHostKey: Bool = true
    ) -> HostConfig {
        HostConfig(
            name: "",
            host: host,
            port: port,
            username: username,
            acceptNewHostKey: acceptNewHostKey
        )
    }

    // MARK: - argv

    func testPortUsernameAndHostArePassedThrough() {
        let plan = SSHCommandBuilder.makePlan(
            config: config(host: "example.com", port: 2222, username: "deploy"),
            askpass: nil,
            baseEnvironment: []
        )

        XCTAssertEqual(plan.executable, "/usr/bin/ssh")
        XCTAssertEqual(plan.arguments.suffix(3), ["-l", "deploy", "example.com"])
        XCTAssertEqual(optionValue("-p", in: plan.arguments), "2222")
    }

    func testAcceptNewHostKeyMapsToStrictHostKeyChecking() {
        let accepting = SSHCommandBuilder.makePlan(
            config: config(acceptNewHostKey: true),
            askpass: nil,
            baseEnvironment: []
        )
        XCTAssertTrue(accepting.arguments.contains("StrictHostKeyChecking=accept-new"))

        let asking = SSHCommandBuilder.makePlan(
            config: config(acceptNewHostKey: false),
            askpass: nil,
            baseEnvironment: []
        )
        XCTAssertTrue(asking.arguments.contains("StrictHostKeyChecking=ask"))
    }

    func testPasswordAuthOptionsOnlyAppearWhenAskpassIsUsed() {
        let withoutPassword = SSHCommandBuilder.makePlan(
            config: config(),
            askpass: nil,
            baseEnvironment: []
        )
        XCTAssertFalse(withoutPassword.arguments.contains("PubkeyAuthentication=no"))
        XCTAssertFalse(withoutPassword.environment.contains { $0.hasPrefix("SSH_ASKPASS=") })

        let withPassword = SSHCommandBuilder.makePlan(
            config: config(),
            askpass: (helperPath: "/tmp/helper", secretPath: "/tmp/secret"),
            baseEnvironment: []
        )
        XCTAssertTrue(withPassword.arguments.contains("PubkeyAuthentication=no"))
        XCTAssertTrue(withPassword.arguments.contains("PreferredAuthentications=keyboard-interactive,password"))
        XCTAssertTrue(withPassword.arguments.contains("NumberOfPasswordPrompts=2"))
    }

    // MARK: - 环境变量

    func testAskpassEnvironmentIsSet() {
        let plan = SSHCommandBuilder.makePlan(
            config: config(),
            askpass: (helperPath: "/tmp/helper", secretPath: "/tmp/secret"),
            baseEnvironment: ["TERM=xterm-256color"]
        )

        XCTAssertTrue(plan.environment.contains("TERM=xterm-256color"))
        XCTAssertTrue(plan.environment.contains("SSH_ASKPASS=/tmp/helper"))
        XCTAssertTrue(plan.environment.contains("SSH_ASKPASS_REQUIRE=force"))
        XCTAssertTrue(plan.environment.contains("MOONTERM_SECRET_FILE=/tmp/secret"))
    }

    func testInheritedAskpassVariablesAreReplaced() {
        let plan = SSHCommandBuilder.makePlan(
            config: config(),
            askpass: (helperPath: "/tmp/helper", secretPath: "/tmp/secret"),
            baseEnvironment: [
                "SSH_ASKPASS=/usr/libexec/other-askpass",
                "SSH_ASKPASS_REQUIRE=never",
                "MOONTERM_SECRET_FILE=/tmp/stale"
            ]
        )

        XCTAssertEqual(plan.environment.filter { $0.hasPrefix("SSH_ASKPASS=") }, ["SSH_ASKPASS=/tmp/helper"])
        XCTAssertEqual(plan.environment.filter { $0.hasPrefix("SSH_ASKPASS_REQUIRE=") }, ["SSH_ASKPASS_REQUIRE=force"])
        XCTAssertEqual(plan.environment.filter { $0.hasPrefix("MOONTERM_SECRET_FILE=") }, ["MOONTERM_SECRET_FILE=/tmp/secret"])
    }

    func testPathIsAddedWhenMissingAndKeptWhenPresent() {
        let added = SSHCommandBuilder.makePlan(config: config(), askpass: nil, baseEnvironment: [])
        XCTAssertTrue(added.environment.contains { $0.hasPrefix("PATH=") })

        let kept = SSHCommandBuilder.makePlan(
            config: config(),
            askpass: nil,
            baseEnvironment: ["PATH=/opt/homebrew/bin"]
        )
        XCTAssertEqual(kept.environment.filter { $0.hasPrefix("PATH=") }, ["PATH=/opt/homebrew/bin"])
    }

    // MARK: - 辅助

    /// 取 `-p 2222` 这类「选项 值」组合里的值。
    private func optionValue(_ option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
