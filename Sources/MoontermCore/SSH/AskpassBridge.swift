import Darwin
import Foundation

/// 把密码交给 ssh 的通道。
///
/// 密码写进一个临时文件（创建时就是 0600），路径通过环境变量告诉 `MoontermAskpass`；
/// ssh 需要密码时会执行 askpass 助手，助手读文件并打到 stdout。
///
/// 为什么不用环境变量直接传密码：同一个用户的其他进程可以 `ps -E` 看到子进程环境变量。
/// 为什么不用命令行传：`ps` 里所有人都能看到 argv。
public final class AskpassBridge {

    /// askpass 助手可执行文件名（SPM 里的 target 名，打包进 .app 时保持同名）。
    public static let helperExecutableName = "MoontermAskpass"

    public let secretPath: String
    private var cleanedUp = false

    /// 写入密码并创建临时文件。
    /// - Throws: 文件创建或写入失败。
    public init(password: String) throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("moonterm-\(UUID().uuidString)")
        self.secretPath = path

        // O_EXCL 保证不会写到别人预先建好的文件里；权限在创建瞬间就是 0600。
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            throw AskpassError.cannotCreateSecretFile(errno: errno)
        }
        defer { close(fd) }

        // 不写结尾换行：助手负责补，密码里的每个字节都原样保留。
        var bytes = Array(password.utf8)
        guard !bytes.isEmpty else { return }

        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw -> Int in
                write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            }
            if written <= 0 {
                if errno == EINTR { continue }
                throw AskpassError.cannotWriteSecretFile(errno: errno)
            }
            offset += written
        }
        // 抹掉内存里的明文副本（尽力而为，Swift String 的副本无法保证）。
        for i in bytes.indices { bytes[i] = 0 }
    }

    /// 删除临时密码文件。可重复调用。
    public func cleanup() {
        guard !cleanedUp else { return }
        cleanedUp = true
        unlink(secretPath)
    }

    deinit {
        cleanup()
    }

    public enum AskpassError: LocalizedError {
        case cannotCreateSecretFile(errno: Int32)
        case cannotWriteSecretFile(errno: Int32)
        case helperNotFound

        public var errorDescription: String? {
            switch self {
            case .cannotCreateSecretFile(let code):
                return "无法创建临时密码文件（errno \(code)）"
            case .cannotWriteSecretFile(let code):
                return "无法写入临时密码文件（errno \(code)）"
            case .helperNotFound:
                return "找不到 \(AskpassBridge.helperExecutableName) 助手程序"
            }
        }
    }

    /// 定位 askpass 助手。
    ///
    /// 两种运行形态都要能找到：
    /// - `.app` 包：和主程序一起躺在 `Contents/MacOS/`
    /// - `swift run` / `swift build`：和主程序一起躺在 `.build/<config>/`
    public static func locateHelper(
        bundleExecutableURL: URL? = Bundle.main.executableURL,
        argv0: String = CommandLine.arguments.first ?? ""
    ) -> String? {
        var candidates: [URL] = []

        if let executableDirectory = bundleExecutableURL?.deletingLastPathComponent() {
            candidates.append(executableDirectory.appendingPathComponent(helperExecutableName))
        }
        if !argv0.isEmpty {
            candidates.append(
                URL(fileURLWithPath: argv0)
                    .deletingLastPathComponent()
                    .appendingPathComponent(helperExecutableName)
            )
        }

        let fm = FileManager.default
        for candidate in candidates where fm.isExecutableFile(atPath: candidate.path) {
            return candidate.path
        }
        return nil
    }
}
