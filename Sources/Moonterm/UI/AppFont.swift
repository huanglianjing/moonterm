import AppKit

/// 终端字体。等宽是硬要求，Menlo 在 macOS 上一定存在，取不到再退回系统等宽字体。
enum AppFont {

    static let minimumSize: CGFloat = 8
    static let maximumSize: CGFloat = 32
    static let defaultSize: CGFloat = 13

    static func terminalFont(size: CGFloat) -> NSFont {
        let clamped = min(max(size, minimumSize), maximumSize)
        return NSFont(name: "Menlo", size: clamped)
            ?? NSFont.monospacedSystemFont(ofSize: clamped, weight: .regular)
    }
}
