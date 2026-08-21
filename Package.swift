// swift-tools-version:6.0
// Moonterm —— macOS 原生 SSH 客户端
//
// 依赖 SwiftTerm 提供终端仿真（VT/xterm 解析、PTY、渲染、选区）。
// SwiftTerm 的清单是 swift-tools-version:6.0，因此本包也用 6.0；
// 但语言模式固定在 v5，避免 Swift 6 严格并发检查与 AppKit/SwiftUI 混用产生大量噪音。

import PackageDescription

let package = Package(
    name: "Moonterm",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Moonterm", targets: ["Moonterm"]),
        .executable(name: "MoontermAskpass", targets: ["MoontermAskpass"]),
        .library(name: "MoontermCore", targets: ["MoontermCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.20.0")
    ],
    targets: [
        // 不依赖 UI / SwiftTerm 的纯逻辑：模型、持久化、ssh 命令行构造、输出诊断。
        .target(
            name: "MoontermCore",
            path: "Sources/MoontermCore"
        ),
        // App 本体：SwiftUI + AppKit + SwiftTerm。
        .executableTarget(
            name: "Moonterm",
            dependencies: [
                "MoontermCore",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/Moonterm"
        ),
        // ssh 的 SSH_ASKPASS 助手：把密码交给 ssh，避免密码出现在命令行或终端输入流里。
        .executableTarget(
            name: "MoontermAskpass",
            path: "Sources/MoontermAskpass"
        ),
        .testTarget(
            name: "MoontermCoreTests",
            dependencies: ["MoontermCore"],
            path: "Tests/MoontermCoreTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
