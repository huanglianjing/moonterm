import SwiftUI

extension SSHSession.State {

    /// tab 与分栏子标题条上那颗小圆点的颜色。
    var indicatorColor: Color {
        switch self {
        case .connecting: return .orange
        case .connected: return .green
        case .disconnected: return .secondary
        case .failed: return .red
        }
    }
}

enum SessionStatus {

    /// 一个 tab 里多个分栏的状态汇总：有失败的先报红，其次连接中报橙，全连上才是绿。
    static func aggregateColor(of states: [SSHSession.State]) -> Color {
        guard !states.isEmpty else { return .secondary }
        if states.contains(where: { if case .failed = $0 { return true } else { return false } }) {
            return .red
        }
        if states.contains(.connecting) { return .orange }
        if states.allSatisfy({ $0 == .connected }) { return .green }
        return .secondary
    }
}
