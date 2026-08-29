import AppKit
import SwiftUI

// MARK: - 一次待确认的操作

/// 一次待确认的破坏性操作。
///
/// 只有一行标题，说清楚要删的是谁 —— 底下不再加一行说明：删除弹窗要的是「一眼看清删的是哪个，
/// 然后回车」，多一行字只会让人多读一遍。
///
/// 标题在**弹出那一刻**就定死，不是每帧照数据算出来的：确认之后底层数据立刻就变了（主机被删、
/// 分组没了），而弹窗还要淡出一会儿；照数据实时算的话，这段时间里名字会变成空的。
struct DestructiveConfirmationRequest: Identifiable {

    let id = UUID()
    let title: String
    /// 破坏性按钮上的字，比如「删除」「删除分组」。
    let confirmTitle: String
    let perform: () -> Void
}

// MARK: - 弹窗状态

/// 一个「弹窗表面」上的确认弹窗状态。
///
/// 每个能盖满自己那一层的表面各持一份：主窗口挂在 `ContentView`，主机管理是独立 sheet
/// （另一个窗口），主窗口那层盖不到它，所以它自己再持一份。发起方只管 `ask`，不关心画在哪。
///
/// 淡入淡出都在这里 `withAnimation`：确认、取消、按键、点弹窗外面 —— 所有路径都走这三个方法，
/// 动画就不会漏掉哪一条。
final class ConfirmationCenter: ObservableObject {

    @Published private(set) var request: DestructiveConfirmationRequest?

    /// 淡入淡出的时长。比系统 sheet 快一档：确认弹窗是「问一句就走」，慢了像卡住。
    static let fade = Animation.easeInOut(duration: 0.16)

    var isPresenting: Bool { request != nil }

    /// 一次只问一件事：已经有弹窗时不再叠一个（多选删除时按住删除键会连发）。
    func ask(title: String, confirmTitle: String, perform: @escaping () -> Void) {
        guard request == nil else { return }
        withAnimation(Self.fade) {
            request = DestructiveConfirmationRequest(
                title: title,
                confirmTitle: confirmTitle,
                perform: perform
            )
        }
    }

    /// 先让弹窗开始淡出，再执行操作 —— 反过来的话，列表在弹窗还在的时候就少了一行，
    /// 会看见弹窗底下的内容先跳一下。
    func confirm() {
        guard let request else { return }
        withAnimation(Self.fade) { self.request = nil }
        request.perform()
    }

    func cancel() {
        guard request != nil else { return }
        withAnimation(Self.fade) { request = nil }
    }
}

// MARK: - 挂载

extension View {

    /// 给这一层挂上破坏性确认弹窗。
    ///
    /// **挂的位置决定弹窗能盖多大**，所以要挂在窗口（或整张 sheet）的最外层：弹窗期间底下的
    /// 内容全都不该点得到，挂在侧栏上就只压得住侧栏那一条。
    func destructiveConfirmations(_ center: ConfirmationCenter) -> some View {
        overlay(DestructiveConfirmationLayer(center: center))
    }
}

/// 确认弹窗那一层：压暗底下内容的背板 + 居中的卡片。
///
/// 系统 `.alert` 换成自绘的，唯一原因是**它关不出淡出效果**：macOS 上 SwiftUI 的 alert 是真的
/// `_NSAlertPanel` sheet，无论点按钮还是翻绑定，面板都在一帧之内 `isVisible=false`（alpha 全程 1），
/// 属于瞬间消失，外面加 `withAnimation` 也管不到它。
private struct DestructiveConfirmationLayer: View {

    @ObservedObject var center: ConfirmationCenter

    var body: some View {
        ZStack {
            if let request = center.request {
                // 插入和移除都只做透明度过渡，位置不动 —— 要的就是淡入淡出。
                ChromeStyle.dialogScrim
                    .transition(.opacity)

                DestructiveConfirmationCard(
                    request: request,
                    onConfirm: center.confirm,
                    onCancel: center.cancel
                )
                .transition(.opacity)
            }
        }
        // 没弹窗时这一层必须彻底透明于点击，否则整个窗口都别想点了。
        .allowsHitTesting(center.isPresenting)
    }
}

// MARK: - 卡片

private struct DestructiveConfirmationCard: View {

    let request: DestructiveConfirmationRequest
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(request.title)
                .font(.system(size: 13, weight: .semibold))
                // 名字长的主机会换行，别压成一行省略号 —— 删错对象的代价太大。
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                ConfirmationButton(title: "取消", isDestructive: false, action: onCancel)
                ConfirmationButton(title: request.confirmTitle, isDestructive: true, action: onConfirm)
            }
            .padding(.top, 6)
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(ChromeStyle.dialog)
                .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.12))
        )
        // 放在最后一层：这样它的尺寸就是整张卡片的尺寸，正好当「弹窗内 / 弹窗外」的分界。
        .background(
            ConfirmationModalGuard(onConfirm: onConfirm, onCancel: onCancel)
        )
    }
}

/// 弹窗上那两个按钮。
///
/// 不用系统按钮是为了拿到那个红：破坏性操作得一眼看出来，而固定深色外壳里 `.borderedProminent`
/// 跟的是系统强调色（可能被用户改成粉或绿）。悬停加白、按下压暗，跟外壳上其它按钮一个手感。
private struct ConfirmationButton: View {

    let title: String
    let isDestructive: Bool
    let action: () -> Void

    /// 悬停状态得由 View 自己盯着：`ButtonStyle` 不是 View，`@State` 放在里面不受管理
    /// （外壳上的 `ChromeIconButton` 也是这么分工的）。
    @State private var isHovering = false

    var body: some View {
        Button(title, action: action)
            .buttonStyle(Style(isDestructive: isDestructive, isHovering: isHovering))
            .onHover { isHovering = $0 }
    }

    private struct Style: ButtonStyle {

        let isDestructive: Bool
        let isHovering: Bool

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.system(size: 12, weight: isDestructive ? .semibold : .regular))
                .foregroundStyle(isDestructive ? Color.white : Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(background(pressed: configuration.isPressed))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.white.opacity(isDestructive ? 0 : 0.14))
                )
                .contentShape(Rectangle())
        }

        private func background(pressed: Bool) -> Color {
            guard isDestructive else {
                if pressed { return Color.black.opacity(0.22) }
                return Color.white.opacity(isHovering ? 0.18 : 0.10)
            }
            if pressed { return ChromeStyle.destructivePressed }
            return isHovering ? ChromeStyle.destructiveHovered : ChromeStyle.destructive
        }
    }
}

// MARK: - 键盘与「模态」

/// 自绘弹窗缺的那层模态，靠一个本地事件监听器补上。
///
/// 系统 alert 是窗口模态：弹着的时候底下点不到、也打不进去。自绘的没有这层保护 —— 终端那个
/// NSView 还是第一响应者，不接的话打字会直接进 shell。所以弹窗存在期间：
///
/// - Return / 小键盘 Enter = 确认，Esc = 取消。**破坏性按钮不能标成系统默认按钮**
///   （`.keyboardShortcut(.defaultAction)`）：那会让它一出现就是蓝色，只有按下时才短暂露出该有的红。
/// - 其余不带 ⌘ 的按键一律吃掉，别漏到终端里去；带 ⌘ 的放行 —— ⌘Q 这类不该被一个小弹窗卡住。
/// - 弹窗外的点击和滚动也吃掉，点外面等于取消。这里连事件本身都不放下去，所以底下的终端连
///   焦点变化都不会有（只靠一层 SwiftUI 背板挡不住 AppKit 那边的命中）。
///
/// 只处理**自己这个窗口**的事件：主窗口和主机管理 sheet 各挂一份，互相不能抢。
private struct ConfirmationModalGuard: NSViewRepresentable {

    let onConfirm: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> GuardView {
        let view = GuardView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: GuardView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: GuardView) {
        view.onConfirm = onConfirm
        view.onCancel = onCancel
    }

    final class GuardView: NSView {

        var onConfirm: (() -> Void)?
        var onCancel: (() -> Void)?

        private var monitor: Any?

        /// 这层只用来量卡片的矩形和收全局事件，本身不该接命中 —— 不然卡片上的按钮都点不到。
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                stopMonitoring()
            } else {
                startMonitoring()
            }
        }

        private func startMonitoring() {
            guard monitor == nil else { return }
            let mask: NSEvent.EventTypeMask = [
                .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
            ]
            monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                return event.type == .keyDown ? self.handle(key: event) : self.handle(mouse: event)
            }
        }

        private func handle(key event: NSEvent) -> NSEvent? {
            guard !event.modifierFlags.contains(.command) else { return event }

            switch event.keyCode {
            case 36, 76: // Return、小键盘 Enter
                onConfirm?()
            case 53: // Esc
                onCancel?()
            default:
                break // 别的键：什么都不做，但也不放过去。
            }
            return nil
        }

        private func handle(mouse event: NSEvent) -> NSEvent? {
            // 卡片自己身上的点击照常往下走，按钮要靠它。
            guard !bounds.contains(convert(event.locationInWindow, from: nil)) else { return event }

            // 标题栏不算「弹窗外面」：吃掉的话弹窗期间窗口既拖不动也关不掉，
            // 而那儿本来就没有会被误触的破坏性操作。
            if let content = window?.contentView,
               !content.bounds.contains(content.convert(event.locationInWindow, from: nil)) {
                return event
            }

            if event.type != .scrollWheel { onCancel?() }
            return nil
        }

        private func stopMonitoring() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        deinit {
            stopMonitoring()
        }
    }
}
