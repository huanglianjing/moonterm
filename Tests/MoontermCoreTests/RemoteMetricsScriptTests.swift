import XCTest
@testable import MoontermCore

/// 采集脚本的拼装，以及跑它的那条 ssh 命令行。
final class RemoteMetricsScriptTests: XCTestCase {

    // MARK: - 脚本

    func testScriptReadsEveryMetricAndMarksFrames() {
        let script = RemoteMetricsScript.script(interval: 2)

        for path in ["/proc/uptime", "/proc/stat", "/proc/meminfo", "/proc/loadavg", "/proc/cpuinfo", "/proc/net/dev"] {
            XCTAssertTrue(script.contains(path), "少读了 \(path)")
        }
        XCTAssertTrue(script.contains("df -kP"))
        for section in [RemoteMetricsScript.Section.time, .cpu, .memory, .load, .cpuCount, .network, .disk] {
            XCTAssertTrue(script.contains(RemoteMetricsScript.marker(section)), "少了 \(section) 的标记")
        }
        XCTAssertTrue(script.contains(RemoteMetricsScript.frameTerminator))
        XCTAssertTrue(script.contains(RemoteMetricsScript.unsupportedMarker))
        // locale 得在远端钉住：本地那套环境变量传不过去。
        XCTAssertTrue(script.contains("export LC_ALL=C"))
    }

    func testIntervalIsClamped() {
        XCTAssertTrue(RemoteMetricsScript.script(interval: 0).contains("sleep 1"))
        XCTAssertTrue(RemoteMetricsScript.script(interval: -5).contains("sleep 1"))
        XCTAssertTrue(RemoteMetricsScript.script(interval: 5).contains("sleep 5"))
        XCTAssertTrue(RemoteMetricsScript.script(interval: 9999).contains("sleep 30"))
    }

    /// `procRoot` 是给本机测试用的（见 `RemoteMetricsStreamLocalTests`），换掉之后不能还剩下
    /// 指向真 `/proc` 的路径。
    func testProcRootIsSubstitutedEverywhere() {
        let script = RemoteMetricsScript.script(interval: 1, procRoot: "/tmp/fake-proc")

        XCTAssertTrue(script.contains("/tmp/fake-proc/stat"))
        XCTAssertTrue(script.contains("/tmp/fake-proc/net/dev"))
        XCTAssertFalse(script.contains(" /proc/"))
    }

    /// 每一帧都以帧结束标记收尾，且它自己独占一行 —— 本地分帧就靠「整行相等」。
    func testFrameTerminatorIsOnItsOwnLine() {
        let script = RemoteMetricsScript.script(interval: 1)
        XCTAssertTrue(script.contains("echo '\(RemoteMetricsScript.frameTerminator)'\n"))
    }

    // MARK: - ssh 命令行

    private let config = HostConfig(name: "", host: "example.com", port: 2222, username: "deploy")

    func testPlanOnlyReusesTheExistingMaster() {
        let plan = RemoteShellCommandBuilder.makePlan(config: config, controlPath: "/tmp/socket")

        XCTAssertEqual(plan.executable, "/usr/bin/ssh")
        XCTAssertTrue(hasOption(plan.arguments, "ControlMaster=no"))
        XCTAssertTrue(hasOption(plan.arguments, "ControlPath=/tmp/socket"))
        // 绝不交互提问：master 不在时立刻失败，而不是挂在一个没人看得见的密码提示上。
        XCTAssertTrue(hasOption(plan.arguments, "BatchMode=yes"))
        XCTAssertFalse(plan.arguments.contains("ControlMaster=auto"))
    }

    func testPlanRunsShellFromStdinWithoutTTY() {
        let plan = RemoteShellCommandBuilder.makePlan(config: config, controlPath: "/tmp/socket")

        XCTAssertTrue(plan.arguments.contains("-T"))
        XCTAssertEqual(plan.arguments.suffix(3), ["deploy@example.com", "sh", "-s"])
        XCTAssertEqual(plan.arguments[plan.arguments.firstIndex(of: "-p")! + 1], "2222")
    }

    /// 环境全部继承：整套替换会把 `HOME` 弄丢，ssh 就找不到 `~/.ssh` 了。
    func testPlanInheritsEnvironment() {
        XCTAssertTrue(RemoteShellCommandBuilder.makePlan(config: config, controlPath: "/tmp/s").environment.isEmpty)
    }

    private func hasOption(_ arguments: [String], _ value: String) -> Bool {
        guard let index = arguments.firstIndex(of: value), index > 0 else { return false }
        return arguments[index - 1] == "-o"
    }
}
