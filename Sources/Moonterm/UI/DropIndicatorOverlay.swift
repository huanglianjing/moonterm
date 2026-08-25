import MoontermCore
import SwiftUI

/// 拖拽时盖在整个窗口上的提示层：一个跟着指针走的「幽灵」，加一块表示落点的高亮。
///
/// 只观察 `DragController`，不碰 `AppState` —— 每帧重画的只有这一层。
struct DropIndicatorOverlay: View {

    @EnvironmentObject private var drag: DragController

    /// 落点框换位置时的动画：一下到位、几乎不回弹。
    ///
    /// 落点在拖拽中是跳变的（半栏 → 另半栏 → 整栏），硬切会一格一格地闪；
    /// 但拖拽要跟手，回弹或者慢半拍都会让人以为落点还没定下来，所以取短周期 + 高阻尼。
    private static let motion = Animation.spring(response: 0.2, dampingFraction: 0.88, blendDuration: 0)

    var body: some View {
        GeometryReader { proxy in
            if let state = drag.state {
                // 手势和各视图的矩形都取全局坐标，这里换算回本层坐标。
                let origin = proxy.frame(in: .global).origin

                ZStack(alignment: .topLeading) {
                    // 高亮单独一层：动画只能加在它身上，不能罩住下面的幽灵。
                    highlightLayer(for: state.target, origin: origin)

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

    /// 落点高亮。
    ///
    /// 三种落点共用**同一个**视图（只换 `kind`），因此换落点时矩形是插值过去的，
    /// 而不是拆掉重画一个 —— 这是这层动画唯一成立的前提。样式差异都做成透明度叠化。
    private func highlightLayer(for target: DragController.Target, origin: CGPoint) -> some View {
        let highlight = self.highlight(for: target)

        return ZStack(alignment: .topLeading) {
            if let highlight {
                DropHighlightShape(kind: highlight.kind)
                    .frame(width: highlight.rect.width, height: highlight.rect.height)
                    .position(x: highlight.rect.midX - origin.x, y: highlight.rect.midY - origin.y)
                    // 出现/消失也别硬切：从落点自己的位置微微涨开，收的时候原地淡掉。
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        // 松手那一下 `drag.state` 直接变 nil，整层随之消失、不带动画 ——
        // 布局在同一帧就变了，留个框在原处淡出反而像没跟上。
        .animation(Self.motion, value: highlight)
    }

    /// 当前落点该画成什么样、画在哪儿（全局坐标）。`nil` 表示没有有效落点。
    private func highlight(for target: DragController.Target) -> DropHighlight? {
        guard let rect = drag.highlightRect(for: target) else { return nil }
        switch target {
        case .paneHeader:
            // 分栏小标签之间的插入位。（tab 之间不画线：tab 会实时滑开。）
            return DropHighlight(kind: .insertLine, rect: rect)
        case .pane(_, .center):
            return DropHighlight(kind: .merge, rect: rect)
        case .pane(_, .edge):
            return DropHighlight(kind: .split, rect: rect)
        case .tabBar, .none:
            return nil
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

/// 一个落点高亮：画成什么样 + 画在哪儿。整体做动画的插值单位。
private struct DropHighlight: Equatable {

    enum Kind {
        /// 小标签之间的插入位：一根细条。
        case insertLine
        /// 并进这个分栏，多一个小标签。
        case merge
        /// 新分栏将要占据的那一半。
        case split
    }

    let kind: Kind
    let rect: CGRect
}

/// 落点框本身。
///
/// 实线框和虚线框**同时存在**，靠透明度互相叠化：`StrokeStyle` 的虚线段没法插值，
/// 换成两个视图交替显示又会把框的身份也换掉（矩形就不再是移过去的了）。
private struct DropHighlightShape: View {

    let kind: DropHighlight.Kind

    private var accent: Color { ChromeStyle.accent }

    /// 落点框的边框用和「当前分栏」同一个暗蓝：亮蓝的边压在黑终端上太扎眼，
    /// 而且拖完松手落点就会变成当前分栏，两处同色看着是一回事。
    private var border: Color { ChromeStyle.focusRing }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)

        return shape
            .fill(fill)
            .overlay(
                shape
                    .strokeBorder(border, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .opacity(kind == .merge ? 1 : 0)
            )
            .overlay(
                shape
                    .strokeBorder(border, lineWidth: 2)
                    .opacity(kind == .split ? 1 : 0)
            )
    }

    /// 细条那点宽度容不下圆角；两种框统一取一个折中值，免得半径也跟着跳。
    private var cornerRadius: CGFloat {
        kind == .insertLine ? 1.5 : 5
    }

    private var fill: Color {
        switch kind {
        case .insertLine: return accent
        case .merge: return accent.opacity(0.14)
        case .split: return accent.opacity(0.22)
        }
    }
}
