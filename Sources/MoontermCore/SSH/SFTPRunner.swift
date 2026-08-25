import Foundation

/// 跑一次 sftp：把批处理脚本写进 stdin，收 stdout / stderr，超时或取消时把进程掐掉。
///
/// **一次性对象** —— 一个 `SFTPRunner` 对应一次调用。这样「取消这个传输」就是「掐掉这个进程」，
/// 不用在一个长命对象里维护「现在跑的是哪一条」。
///
/// 这里不 import 任何 UI 框架，但也算不上纯逻辑（要起进程），所以判定类的活儿一概不干：
/// 命令怎么拼在 `SFTPCommandBuilder`，输出怎么解在 `SFTPListingParser`，两边都有单测。
public final class SFTPRunner {

    /// 一次调用的结果。
    public struct Outcome {
        /// 与传入的 `commands` 一一对应的输出（按 sftp 的回显行切开，见
        /// `SFTPCommandBuilder.splitBatchOutput`）。某条没有输出时是空串，对不上时是 nil。
        public let outputs: [String?]
        public let stdout: String
        public let stderr: String
        /// 进程退出码。被掐掉时是信号造成的非零值。
        public let exitCode: Int32
        public let timedOut: Bool
        public let cancelled: Bool

        public var isSuccess: Bool { exitCode == 0 && !timedOut && !cancelled }

        /// 失败时给人看的一句话。成功时 nil。
        public var errorMessage: String? {
            if cancelled { return "已取消" }
            if timedOut { return "操作超时（远端没有响应）" }
            if exitCode == 0 { return nil }
            if let reported = SFTPCommandBuilder.firstError(in: stderr) { return reported }
            return "sftp 退出码 \(exitCode)"
        }
    }

    /// 列目录这类小操作的默认上限。传输不能用它 —— 大文件传十分钟也正常。
    public static let defaultTimeout: TimeInterval = 20

    private let process = Process()
    private let queue = DispatchQueue(label: "moonterm.sftp", qos: .userInitiated)
    /// 只在 `queue` 上读写。
    private var didCancel = false
    private var didTimeOut = false
    private var didFinish = false

    public init() {}

    /// 起进程并跑完这批命令。
    ///
    /// - Parameters:
    ///   - plan: `SFTPCommandBuilder.makePlan` 的产物。
    ///   - commands: 每条一行，会自动加上「出错不中断」的 `-` 前缀。
    ///   - timeout: 超过就掐掉。传 nil 表示不限时（传输用）。
    ///   - completion: **在主队列**回调，一定会被调用一次（包括起不来进程的情况）。
    public func start(
        plan: SSHLaunchPlan,
        commands: [String],
        timeout: TimeInterval? = defaultTimeout,
        completion: @escaping (Outcome) -> Void
    ) {
        queue.async { [self] in
            // 起之前就被取消了（用户点得快）：别再拉进程。
            if didCancel {
                finish(stdout: "", stderr: "", exitCode: -1, commands: commands, completion: completion)
                return
            }

            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: plan.executable)
            process.arguments = plan.arguments
            if !plan.environment.isEmpty {
                // **叠加**而不是替换：整套换掉会把 `HOME` 一起弄丢，ssh 就找不到 `~/.ssh` 了。
                process.environment = ProcessInfo.processInfo.environment
                    .merging(Self.environmentDictionary(plan.environment)) { _, forced in forced }
            }
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                finish(
                    stdout: "",
                    stderr: "无法启动 \(plan.executable)：\(error.localizedDescription)",
                    exitCode: -1,
                    commands: commands,
                    completion: completion
                )
                return
            }

            // 脚本最多几 KB，远小于管道缓冲（64 KB），所以可以一次写完再去读输出，
            // 不用另起一条队列喂 stdin。
            let script = SFTPCommandBuilder.batchScript(commands)
            try? stdin.fileHandleForWriting.write(contentsOf: Data(script.utf8))
            // **必须关**：sftp 是从 stdin 读命令的，不关它就一直等下一条，永远不退出。
            try? stdin.fileHandleForWriting.close()

            if let timeout {
                queue.asyncAfter(deadline: .now() + timeout) { [self] in
                    guard !didFinish, process.isRunning else { return }
                    didTimeOut = true
                    process.terminate()
                }
            }

            // 两条管道要**同时**排空：只读一条时另一条填满 64 KB 缓冲，
            // 对面就卡在 write 上，进程永远等不到退出（目录一大就必现）。
            var outData = Data()
            var errData = Data()
            let group = DispatchGroup()
            let readQueue = DispatchQueue(label: "moonterm.sftp.read", attributes: .concurrent)
            readQueue.async(group: group) {
                outData = stdout.fileHandleForReading.readDataToEndOfFile()
            }
            readQueue.async(group: group) {
                errData = stderr.fileHandleForReading.readDataToEndOfFile()
            }
            group.wait()
            process.waitUntilExit()

            finish(
                stdout: String(decoding: outData),
                stderr: String(decoding: errData),
                exitCode: process.terminationStatus,
                commands: commands,
                completion: completion
            )
        }
    }

    /// 掐掉这次调用。已经跑完就什么都不做。可重复调用。
    public func cancel() {
        queue.async { [self] in
            guard !didFinish else { return }
            didCancel = true
            if process.isRunning { process.terminate() }
        }
    }

    private func finish(
        stdout: String,
        stderr: String,
        exitCode: Int32,
        commands: [String],
        completion: @escaping (Outcome) -> Void
    ) {
        guard !didFinish else { return }
        didFinish = true

        let outcome = Outcome(
            outputs: SFTPCommandBuilder.splitBatchOutput(stdout, commands: commands),
            stdout: stdout,
            stderr: stderr,
            exitCode: exitCode,
            timedOut: didTimeOut,
            cancelled: didCancel
        )
        DispatchQueue.main.async { completion(outcome) }
    }

    private static func environmentDictionary(_ entries: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for entry in entries {
            guard let separator = entry.firstIndex(of: "=") else { continue }
            result[String(entry[entry.startIndex..<separator])] = String(entry[entry.index(after: separator)...])
        }
        return result
    }
}

private extension String {

    /// 远端文件名不保证是合法 UTF-8（各人的语言环境不一样），所以坏字节得容错：
    /// `String(decoding:as:)` 把坏字节换成 U+FFFD 而不是整块失败，正合适。
    init(decoding data: Data) {
        self = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}
