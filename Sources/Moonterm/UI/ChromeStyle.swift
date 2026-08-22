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
    static let dividerHovered = Color.white.opacity(0.28)

    /// 鼠标悬停时的浅浅一层高亮。
    static let hover = Color.white.opacity(0.10)

    static let accent = Color(nsColor: .controlAccentColor)

    /// 当前分栏的焦点边框。系统强调色的亮蓝压在纯黑终端上太扎眼，这里用暗一档的蓝，
    /// 能看出「键盘在这一栏」就够了，不抢终端内容的注意力。
    static let focusRing = Color(red: 0.11, green: 0.33, blue: 0.60)

    /// 选中项的底色。`emphasized` 用于「键盘焦点就在这儿」。
    static func selected(emphasized: Bool) -> Color {
        accent.opacity(emphasized ? 0.42 : 0.24)
    }

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

/// 竖着的那一条，用在左侧竖栏与右边内容之间。
struct ChromeVerticalHairline: View {

    var body: some View {
        Rectangle()
            .fill(ChromeStyle.hairline)
            .frame(width: 1)
    }
}
