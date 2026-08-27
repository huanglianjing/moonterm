import AppKit
import SwiftUI

/// 界面外壳（最左侧竖栏、侧栏面板、tab 条、分栏小标签条、分割线）的配色。
///
/// 终端本身的底色由 SwiftTerm 固定成黑色，不跟随系统外观；所以外壳也固定走深色，
/// 免得系统在浅色模式时出现「黑终端 + 白标题栏」的割裂感。
/// 由外到内逐层变暗：系统标题栏 → tab 条 → 分栏小标签条 → 终端（纯黑）；
/// 左边那两条竖的另算：功能竖栏最深（它是「框」），展开的面板亮一档（它是「内容」）。
enum ChromeStyle {

    /// tab 条背景。
    static let bar = Color(red: 0.145, green: 0.149, blue: 0.165)

    /// 最左侧那条常驻功能竖栏。全窗口最深的一块，让它读起来像窗口的边框。
    static let activityBar = Color(red: 0.085, green: 0.090, blue: 0.105)

    /// 竖栏展开后的面板背景。比竖栏亮一档 —— 它装的是内容，不是框。
    static let sidebar = Color(red: 0.125, green: 0.130, blue: 0.145)

    /// 分栏小标签条背景，比 tab 条再深一档，靠近终端。
    static let paneHeader = Color(red: 0.105, green: 0.110, blue: 0.125)

    /// 深色面之间的分隔线：用偏亮的一点白，比黑线清楚。
    static let hairline = Color.white.opacity(0.09)

    /// 分栏之间可拖动的分割线。
    static let divider = Color.white.opacity(0.12)
    static let dividerHovered = Color.white.opacity(0.45)

    /// 鼠标悬停时的浅浅一层高亮。
    static let hover = Color.white.opacity(0.10)

    /// 小图标按钮（关闭 ✕、新建 +）悬停时的高亮。比 `hover` 重一档 ——
    /// 它压在已经高亮着的 tab / 小标签上面，同样浓度就看不出来了。
    static let iconHover = Color.white.opacity(0.20)

    /// 同上，按下去还没松手时。往**暗**的方向走：悬停已经占了「加白」，
    /// 按下再加白就分不出来了，压暗才一眼能看出「这一下按到了」。
    static let iconPressed = Color.black.opacity(0.32)

    static let accent = Color(nsColor: .controlAccentColor)

    /// 当前分栏的焦点边框。系统强调色的亮蓝压在纯黑终端上太扎眼，这里用暗一档的蓝，
    /// 能看出「键盘在这一栏」就够了，不抢终端内容的注意力。
    static let focusRing = Color(red: 0.11, green: 0.33, blue: 0.60)

    /// 选中项的底色。`emphasized` 用于「键盘焦点就在这儿」。
    static func selected(emphasized: Bool) -> Color {
        accent.opacity(emphasized ? 0.42 : 0.24)
    }

    /// 分栏小标签「当前显示的那个」用的绿。终端里的字就是这种绿，
    /// 小标签黑底绿字绿边，读起来和它底下那块终端是一件事，不像块贴上去的蓝方块。
    private static let terminalGreen = Color(red: 0.30, green: 0.85, blue: 0.42)

    /// 小标签选中时的底色：和终端一个底，纯黑。
    static let paneChipBackground = Color.black

    /// 小标签那圈绿边。`emphasized` = 键盘焦点就在这一栏，绿得实一档。
    static func paneChipBorder(emphasized: Bool) -> Color {
        terminalGreen.opacity(emphasized ? 1 : 0.55)
    }

    /// 小标签上的绿字（连右端那个 ✕）。比边框淡一点，边框才是「圈住」的那一笔。
    static func paneChipText(emphasized: Bool) -> Color {
        terminalGreen.opacity(emphasized ? 1 : 0.8)
    }

    /// 主机列表里选中的那几行。这里不跟系统强调色 —— 它可能被改成粉或绿，
    /// 而「哪几台主机被选中了」得一眼认出来，读作和分栏焦点那圈蓝同一件事。
    static let selectedRow = Color(red: 0.13, green: 0.38, blue: 0.70)

    /// 固定成深色外观。终端是黑的，外壳跟着深色才协调。
    static func applyDarkAppearance() {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }
}

/// 一条 1 像素的分隔线。系统的 `Divider()` 在浅色模式下是亮灰的，深色外壳里太扎眼。
struct ChromeHairline: View {

    var body: some View {
        Rectangle()
            .fill(ChromeStyle.hairline)
            .frame(height: 1)
    }
}

/// 外壳上那些小图标按钮（tab 的关闭 ✕、分栏小标签的 ✕、标题栏与侧栏的 +）。
///
/// 图标画得小是为了不抢注意力，但**手不该跟着变准**：可点击范围是一整块正方形
/// （一般取所在那条栏的高度，正好铺满右侧一格），悬停时整块亮一下、按下去整块压暗，
/// 让人看清点哪儿有效、也知道这一下按到了。
struct ChromeIconButton: View {

    let systemName: String
    /// 正方形的边长，也就是命中范围。
    let side: CGFloat
    /// 图标本身的字号 —— 和边长无关，图标该多小还是多小。
    let iconSize: CGFloat
    /// 高亮块的圆角，跟所在容器的圆角对齐。
    var cornerRadius: CGFloat = 4
    let action: () -> Void

    @State private var isHovering = false
    /// 自己盯着的按下状态，见下面 `simultaneousGesture` 那段注释。
    @GestureState private var isPressing = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .bold))
        }
        // 按下的状态只有 `ButtonStyle` 拿得到，所以底色画在这儿，不画在 label 里。
        .buttonStyle(
            CellStyle(
                side: side,
                cornerRadius: cornerRadius,
                isHovering: isHovering,
                isPressing: isPressing
            )
        )
        // 分栏小标签那个 ✕ 待在一个自己带拖拽 + 单击 + 双击手势的父视图里，
        // 祖先手势会把按钮的按下状态压掉（动作照样触发，就是不高亮）。
        // 所以自己再盯一遍：`simultaneousGesture` 不抢按钮的点击，只用来点亮那块底。
        .simultaneousGesture(
            DragGesture(minimumDistance: 0).updating($isPressing) { _, pressing, _ in
                pressing = true
            }
        )
        .onHover { isHovering = $0 }
    }

    private struct CellStyle: ButtonStyle {
        let side: CGFloat
        let cornerRadius: CGFloat
        let isHovering: Bool
        let isPressing: Bool

        func makeBody(configuration: Configuration) -> some View {
            let pressed = configuration.isPressed || isPressing
            return configuration.label
                // 图标本身也跟着暗一档：小方块上那层底色变化不一定看得清，
                // 图标变淡是压在任何底色上都看得见的。
                .opacity(pressed ? 0.65 : 1)
                .chromeIconCell(
                    side: side,
                    cornerRadius: cornerRadius,
                    hovering: isHovering,
                    pressed: pressed
                )
        }
    }
}

extension View {

    /// 小图标按钮那块方形底：悬停浅高亮、按下压暗。
    ///
    /// 单独拆出来是因为侧栏那个 `+` 是个 `Menu` 而不是 `Button`，用不了 `ButtonStyle`，
    /// 但底该长一个样。
    func chromeIconCell(
        side: CGFloat,
        cornerRadius: CGFloat = 4,
        hovering: Bool,
        pressed: Bool = false
    ) -> some View {
        frame(width: side, height: side)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(pressed ? ChromeStyle.iconPressed : (hovering ? ChromeStyle.iconHover : .clear))
            )
            // 图标周围的空白也算命中范围，不然「正方形」只是看着大。
            .contentShape(Rectangle())
    }
}

/// 竖着的那一条，用在左侧竖栏与右边内容之间。
struct ChromeVerticalHairline: View {

    var body: some View {
        Rectangle()
            .fill(ChromeStyle.hairline)
            .frame(width: 1)
    }
}
