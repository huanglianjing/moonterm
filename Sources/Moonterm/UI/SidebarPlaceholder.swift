import SwiftUI

/// 一个 tab 都没有时的面板占位。
///
/// 文件面板和监控面板看的都是「当前 tab 那台主机」，没 tab 就没什么可显示的，
/// 两边长一个样，所以摊在这里共用。
struct SidebarNoConnectionPanel: View {

    @EnvironmentObject private var appState: AppState

    /// 哪个面板在用它 —— 标题栏文字取自它。
    let panel: SidebarPanel
    /// 第二行小字：说明这个面板打开 tab 之后会显示什么。
    let hint: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(panel.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)

            ChromeHairline()

            VStack(spacing: 8) {
                Text("没有打开的连接")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Text(hint)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)

                Button("打开主机面板") { appState.revealHosts() }
                    .controlSize(.small)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
        .background(ChromeStyle.sidebar)
    }
}
