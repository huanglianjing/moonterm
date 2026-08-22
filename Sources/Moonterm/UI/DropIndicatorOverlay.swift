import MoontermCore
import SwiftUI

/// 拖拽时盖在整个窗口上的提示层：一个跟着指针走的「幽灵」，加一块表示落点的高亮。
///
/// 只观察 `DragController`，不碰 `AppState` —— 每帧重画的只有这一层。
struct DropIndicatorOverlay: View {

    @EnvironmentObject private var drag: DragController

    private var accent: Color { ChromeStyle.accent }

    /// 落点框的边框用和「当前分栏」同一个暗蓝：亮蓝的边压在黑终端上太扎眼，
    /// 而且拖完松手落点就会变成当前分栏，两处同色看着是一回事。
    private var border: Color { ChromeStyle.focusRing }

    var body: some View {
        GeometryReader { proxy in
            if let state = drag.state {
                // 手势和各视图的矩形都取全局坐标，这里换算回本层坐标。
                let origin = proxy.frame(in: .global).origin

                ZStack(alignment: .topLeading) {
                    if let rect = drag.highlightRect(for: state.target) {
                        highlight(for: state.target)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX - origin.x, y: rect.midY - origin.y)
                    }

                    // 拖 tab 时那个 tab 本身就跟着指针走，再挂个幽灵反而重影。
                    if case .pane = state.payload {
                        ghost(title: state.title)
                            .position(x: state.location.x - origin.x + 14, y: state.location.y - origin.y + 12)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func highlight(for target: DragController.Target) -> some View {
        switch target {
        case .paneHeader:
            // 分栏小标签之间的插入位。（tab 之间不画线：tab 会实时滑开。）
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accent)

        case .tabBar:
            EmptyView()

        case .pane(_, .center):
            // 落在正中 = 并进这个分栏，多一个小标签。用虚线和「开新分栏」区分开。
            RoundedRectangle(cornerRadius: 6)
                .fill(accent.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(border, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                )

        case .pane(_, .edge):
            // 新分栏将要占据的那一半。
            RoundedRectangle(cornerRadius: 4)
                .fill(accent.opacity(0.22))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(border, lineWidth: 2)
                )

        case .none:
            EmptyView()
        }
    }

    private func ghost(title: String) -> some View {
        Text(title)
            .font(.system(size: 11))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.primary.opacity(0.18))
            )
            .opacity(0.92)
    }
}
