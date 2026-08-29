import Foundation

/// 喂给远端 `sh` 的采集脚本，以及本地分帧要用的那几个标记。
///
/// 纯字符串拼装，没有副作用，便于单测；真正起进程的是 `RemoteMetricsStream`。
///
/// 为什么是「一条常驻连接 + 远端自己循环」而不是「每两秒起一次 ssh」：一条流只握手一次，
/// 之后每一帧就是几 KB 文本，采样间隔由远端的 `sleep` 决定，不受本地调度和网络抖动影响。
///
/// 为什么脚本走 **stdin**（ssh 的远端命令只有 `sh -s`）：脚本里全是引号、`$`、`|`，
/// 拼进 ssh 的远端命令行就得逐层转义两遍（本地 argv 一次、远端登录 shell 一次），
/// 而登录 shell 还不一定是 `sh`（可能是 csh、fish）。从 stdin 灌给 `sh` 就绕开了这一整摊。
///
/// 只支持 Linux：所有指标都读 `/proc`，格式几十年没变过、也不依赖远端装了什么工具
/// （只用到 `cat` / `head` / `grep` / `df` / `sleep`）。远端没有 `/proc` 时脚本立刻打一行
/// `#m:unsupported` 就退出，面板据此说明情况，而不是空着一片让人以为是 bug。
public enum RemoteMetricsScript {

    /// 分节标记的前缀。`/proc` 与 `df` 的输出都不会有以它开头的行，所以拿它分帧不会串。
    public static let markerPrefix = "#m:"

    /// 一帧结束。本地收到这一行才把攒着的内容交出去解析。
    public static let frameTerminator = markerPrefix + Section.end.rawValue

    /// 远端没有 `/proc`。
    public static let unsupportedMarker = markerPrefix + Section.unsupported.rawValue

    /// 采样间隔的合法范围（秒）。
    public static let minimumInterval = 1
    public static let maximumInterval = 30

    /// 一帧里的各节。`rawValue` 会出现在远端输出里，改动要和 `RemoteMetricsParser` 一起改。
    public enum Section: String {
        case time
        case cpu
        case memory = "mem"
        case load
        case cpuCount = "cpus"
        case network = "net"
        case disk
        case end
        case unsupported
    }

    /// 生成脚本。
    ///
    /// - Parameters:
    ///   - interval: 每帧之间 `sleep` 几秒，会被夹到 `minimumInterval…maximumInterval`。
    ///   - procRoot: `/proc` 的位置。**留这个参数是为了本机测试** —— 测试把它指到一个装了
    ///               假 `stat` / `meminfo` 的临时目录，于是「起进程 → 分帧 → 解析 → 差分」
    ///               整条链路不用真的连一台 Linux 就能验。
    public static func script(interval: Int, procRoot: String = "/proc") -> String {
        let seconds = min(max(interval, minimumInterval), maximumInterval)
        // 脚本里那句 `exec 2>/dev/null`：某一节读不到时（容器里少个文件、`df` 撞上没权限的
        // 挂载点）远端会每帧都往 stderr 写一遍同样的抱怨，攒着只会把真正的失败原因淹掉。
        // ssh 自己的报错（master socket 不在之类）走本地进程的 stderr，不受它影响。
        return """
        export LC_ALL=C
        if [ ! -r \(procRoot)/stat ]; then
        echo '\(unsupportedMarker)'
        exit 0
        fi
        exec 2>/dev/null
        while :; do
        echo '\(marker(.time))'
        cat \(procRoot)/uptime
        echo '\(marker(.cpu))'
        head -n 1 \(procRoot)/stat
        echo '\(marker(.memory))'
        grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree):' \(procRoot)/meminfo
        echo '\(marker(.load))'
        cat \(procRoot)/loadavg
        echo '\(marker(.cpuCount))'
        grep -c '^processor' \(procRoot)/cpuinfo
        echo '\(marker(.network))'
        cat \(procRoot)/net/dev
        echo '\(marker(.disk))'
        df -kP
        echo '\(frameTerminator)'
        sleep \(seconds)
        done

        """
    }

    public static func marker(_ section: Section) -> String {
        markerPrefix + section.rawValue
    }
}
