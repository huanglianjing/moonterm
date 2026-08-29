import Foundation

/// 跑一条**常驻**的远端采集流：把脚本写进 stdin，然后一帧一帧地把 stdout 交出来。
///
/// 和一次性的 `SFTPRunner` 是一对：那个「起进程 → 收完输出 → 退出」，这个「起进程 → 一直读」。
/// 同样是**一次性对象** —— 一个 `RemoteMetricsStream` 对应一条流，`stop()` 之后不能再 `start`。
///
/// 这里不 import 任何 UI 框架，也不做任何判定：脚本怎么写在 `RemoteMetricsScript`，
/// 输出怎么解在 `RemoteMetricsParser`，两边都有单测。
public final class RemoteMetricsStream {

    /// 流为什么停了。
    public struct Termination {
        public let exitCode: Int32
        /// 远端 / ssh 写到 stderr 的东西（只留最后一段，见 `stderrLimit`）。
        public let stderr: String
        /// 是我们自己叫停的（面板收起、换会话、改间隔）。
        public let stopped: Bool

        /// 给人看的一句话。自己叫停时 nil。
        public var errorMessage: String? {
            if stopped { return nil }
            if let reported = SFTPCommandBuilder.firstError(in: stderr) { return reported }
            return "采集进程退出（退出码 \(exitCode)）"
        }
    }

    /// stderr 只留最后这么多字节。一条流可能挂着好几个小时，出错的那句话通常在最后。
    private static let stderrLimit = 4 * 1024

    private let process = Process()
    /// 状态只在这条队列上读写。
    private let queue = DispatchQueue(label: "moonterm.metrics")
    private var didStop = false
    private var didFinish = false
    /// stdout 还没凑成一帧的零碎字节。
    private var buffer = Data()
    private var frameLines: [String] = []
    private var stderrData = Data()

    public init() {}

    /// 起进程并开始收帧。
    ///
    /// - Parameters:
    ///   - plan: `RemoteShellCommandBuilder.makePlan` 的产物（测试里也可以换成本地 `/bin/sh`）。
    ///   - script: 灌给远端 `sh` 的脚本，见 `RemoteMetricsScript.script`。
    ///   - onFrame: 收满一帧（读到 `#m:end`）时回调，参数是这一帧的正文。**在主队列**。
    ///   - onUnsupported: 远端没有 `/proc`，脚本自己报的。**在主队列**，最多一次。
    ///   - onTerminate: 进程结束时回调一次（包括起不来、被我们叫停）。**在主队列**。
    public func start(
        plan: SSHLaunchPlan,
        script: String,
        onFrame: @escaping (String) -> Void,
        onUnsupported: @escaping () -> Void,
        onTerminate: @escaping (Termination) -> Void
    ) {
        queue.async { [self] in
            if didStop {
                finish(exitCode: -1, onTerminate: onTerminate)
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

            // 读 stdout：按行攒，见到帧结束标记就把攒的交出去。
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    // EOF。进程退出的收尾交给 terminationHandler，这里只把回调摘掉。
                    handle.readabilityHandler = nil
                    return
                }
                self?.queue.async {
                    self?.consume(data, onFrame: onFrame, onUnsupported: onUnsupported)
                }
            }

            // stderr 也**必须**排空：只读 stdout 的话，对面把 stderr 的管道缓冲填满就卡在 write 上。
            stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    self.stderrData.append(data)
                    if self.stderrData.count > Self.stderrLimit {
                        self.stderrData.removeFirst(self.stderrData.count - Self.stderrLimit)
                    }
                }
            }

            // **故意捕强引用**：进程还在跑的时候本对象不能被释放，否则 `Process` 跟着没了，
            // 这条回调再也不会来，调用方就一直等一个不会到的结束通知。`finish` 一定会把这个
            // handler 摘掉（见那边的注释），所以这不是泄漏，只是「跑完之前先自己扶着」。
            process.terminationHandler = { [self] process in
                queue.async {
                    self.finish(exitCode: process.terminationStatus, onTerminate: onTerminate)
                }
            }

            do {
                try process.run()
            } catch {
                stderrData = Data("无法启动 \(plan.executable)：\(error.localizedDescription)".utf8)
                finish(exitCode: -1, onTerminate: onTerminate)
                return
            }

            // 脚本只有一两 KB，远小于管道缓冲（64 KB），一次写完就行。
            try? stdin.fileHandleForWriting.write(contentsOf: Data(script.utf8))
            // **写完就关**：脚本本身不再读 stdin（那个 `while` 循环里没有任何读操作），
            // `sh` 读到 EOF 时整段脚本已经在手上，循环照跑。不关的话远端会一直等下一条命令。
            try? stdin.fileHandleForWriting.close()
        }
    }

    /// 叫停这条流。已经停了就什么都不做，可重复调用。
    ///
    /// **必须调**（面板收起、换会话、改间隔时）：远端那个循环不会自己停下来，
    /// 而本对象在进程结束前一直自己扶着自己（见 `start` 里 `terminationHandler` 那段），
    /// 光丢引用是不够的。
    ///
    /// 远端那个 `sh` 不用我们操心：ssh 一走，它下一次往 stdout 写就会吃到 SIGPIPE 而退出，
    /// 不会留下一个还在 `sleep` 的孤儿循环。
    public func stop() {
        queue.async { [self] in
            didStop = true
            guard !didFinish else { return }
            if process.isRunning { process.terminate() }
        }
    }

    // MARK: - 分帧

    private func consume(
        _ data: Data,
        onFrame: @escaping (String) -> Void,
        onUnsupported: @escaping () -> Void
    ) {
        buffer.append(data)

        // 按换行切；最后一段可能是半行，留在 buffer 里等下一批。
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)

            // 远端输出应当是 ASCII 数字与路径；坏字节容错处理，别让一个字节废掉整条流。
            let line = String(data: lineData, encoding: .utf8)
                ?? String(decoding: lineData, as: UTF8.self)

            switch line {
            case RemoteMetricsScript.frameTerminator:
                let frame = frameLines.joined(separator: "\n")
                frameLines.removeAll(keepingCapacity: true)
                DispatchQueue.main.async { onFrame(frame) }

            case RemoteMetricsScript.unsupportedMarker:
                DispatchQueue.main.async { onUnsupported() }

            default:
                frameLines.append(line)
                // 兜底：正常一帧只有几十行。远端要是吐个没完没了的东西（挂了个几万行的 df），
                // 别让内存跟着涨 —— 丢掉这一帧的开头，图上顶多缺一格。
                if frameLines.count > Self.maximumFrameLines {
                    frameLines.removeFirst(frameLines.count - Self.maximumFrameLines)
                }
            }
        }
    }

    private static let maximumFrameLines = 2000

    private func finish(exitCode: Int32, onTerminate: @escaping (Termination) -> Void) {
        guard !didFinish else { return }
        didFinish = true

        // 把挂在进程和管道上的回调都摘掉。它们是一条强引用链
        // （本对象 → process → terminationHandler → 调用方的闭包 → 可能又指回本对象），
        // 不解开的话这条流跑完也不会被释放，每次重启就漏一个进程对象和两个管道。
        process.terminationHandler = nil
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil

        let termination = Termination(
            exitCode: exitCode,
            stderr: String(decoding: stderrData, as: UTF8.self),
            stopped: didStop
        )
        DispatchQueue.main.async { onTerminate(termination) }
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
