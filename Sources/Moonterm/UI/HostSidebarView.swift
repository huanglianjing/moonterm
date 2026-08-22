import AppKit
import MoontermCore
import SwiftUI

/// 竖栏「主机」图标展开的面板：已保存的主机列成一竖列，单击选中、双击连接。
///
/// 选择语义照 Finder：⌘ 点单独加减一台，⇧ 点从锚点整段扩选；右键落在选区里就对整个选区操作。
/// 这里只放常用的几件事（连接、新建、编辑、复制、删除）。排序之类的低频操作留在 ⌘, 的完整面板里。
struct HostSidebarView: View {

    @EnvironmentObject private var appState: AppState

    /// 选中的主机。选择那套语义（重选 / 加减 / 扩选）是 `MoontermCore` 里的纯逻辑，有单测。
    @State private var selection = HostSelection()
    /// 待确认删除的主机，可能是一批。空 = 没在删。删主机会连密码一起删，不能点一下就没了。
    @State private var hostsPendingDeletion: [HostConfig] = []

    private var hosts: [HostConfig] { appState.configStore.hosts }
    private var order: [UUID] { hosts.map { $0.id } }

    var body: some View {
        VStack(spacing: 0) {
            header
            ChromeHairline()

            if hosts.isEmpty {
                empty
            } else {
                list
            }

            ChromeHairline()
            footer
        }
        .frame(maxHeight: .infinity)
        .background(ChromeStyle.sidebar)
        .alert(
            deletionTitle,
            isPresented: Binding(
                get: { !hostsPendingDeletion.isEmpty },
                set: { if !$0 { hostsPendingDeletion = [] } }
            ),
            presenting: hostsPendingDeletion
        ) { targets in
            Button("删除", role: .destructive) {
                targets.forEach { appState.configStore.remove(id: $0.id) }
                selection.remove(targets.map { $0.id })
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("配置和保存的密码都会被删除，此操作不可撤销。已经连上的窗口不受影响。")
        }
    }

    private var deletionTitle: String {
        if hostsPendingDeletion.count > 1 {
            return "删除选中的 \(hostsPendingDeletion.count) 台主机？"
        }
        return "删除「\(hostsPendingDeletion.first?.displayName ?? "")」？"
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(SidebarPanel.hosts.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button {
                appState.beginCreatingHost()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help("新建主机")
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text("还没有保存任何主机")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("新建主机…") { appState.beginCreatingHost() }
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(hosts) { host in
                    HostSidebarRow(
                        host: host,
                        isSelected: selection.contains(host.id),
                        openTabCount: appState.tabs.filter { $0.host.id == host.id }.count
                    ) { clickCount, modifiers in
                        if clickCount > 1 {
                            connect([host])
                        } else {
                            click(host, modifiers: modifiers)
                        }
                    }
                    .contextMenu { menu(for: host) }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - 选择

    /// 修饰键翻译成选择语义。⌘ 和 ⇧ 一起按时以 ⌘ 为准（macOS 各家列表都这么处理）。
    private func click(_ host: HostConfig, modifiers: NSEvent.ModifierFlags) {
        let kind: HostSelection.Click
        if modifiers.contains(.command) {
            kind = .toggle
        } else if modifiers.contains(.shift) {
            kind = .extend
        } else {
            kind = .plain
        }
        selection.click(host.id, kind: kind, in: order)
    }

    // MARK: - 操作

    /// 一台一个新 tab，按列表顺序开；最后开的那个成为当前 tab。
    private func connect(_ targets: [HostConfig]) {
        targets.forEach { appState.open(host: $0) }
    }

    @ViewBuilder
    private func menu(for host: HostConfig) -> some View {
        let targets = menuTargets(for: host)

        if targets.count > 1 {
            Button("连接选中的 \(targets.count) 台") { connect(targets) }
            Divider()
            Button("删除选中的 \(targets.count) 台…") { hostsPendingDeletion = targets }
        } else {
            Button("连接") { connect(targets) }
            Button("编辑…") { appState.beginEditing(host: host) }
            Button("复制") { appState.configStore.duplicate(id: host.id) }
            Divider()
            Button("删除…") { hostsPendingDeletion = targets }
        }
    }

    private func menuTargets(for host: HostConfig) -> [HostConfig] {
        let ids = selection.targets(rightClicking: host.id, in: order)
        return hosts.filter { ids.contains($0.id) }
    }

    private var footer: some View {
        Button {
            appState.isHostManagerPresented = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 9))
                Text("管理主机…")
                    .font(.system(size: 11))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("排序、批量管理（⌘,）")
    }
}

/// 列表里的一行主机。单击选中，双击连接（每次双击都是一个新 tab，同一台主机开几个都行）。
private struct HostSidebarRow: View {

    let host: HostConfig
    let isSelected: Bool
    /// 这台主机当前开着几个 tab。0 就不显示。
    let openTabCount: Int
    /// 点击次数 + 修饰键，选择与打开的判定都交给列表那边做。
    let onClick: (Int, NSEvent.ModifierFlags) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(host.displayName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(host.endpointDescription)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            if openTabCount > 0 {
                Text("\(openTabCount)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(Color.white.opacity(0.10))
                    )
                    .help("已经开着 \(openTabCount) 个标签页")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(background)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onLeftClick(perform: onClick)
        .help("\(host.endpointDescription)（单击选中，双击连接；⌘ / ⇧ 点可多选）")
    }

    private var background: Color {
        if isSelected { return ChromeStyle.selected(emphasized: false) }
        return isHovering ? ChromeStyle.hover : .clear
    }
}

/// 面板右边缘：拖着改宽度。
///
/// 和分栏分割线一个道理，位移必须取**全局坐标** —— 这条边自己会跟着宽度移动，
/// 用局部坐标算等于把输出接回输入。
struct SidebarResizeHandle: View {

    @EnvironmentObject private var appState: AppState

    /// 起手时的宽度：每帧拿它加位移算绝对值，避免误差累积。
    @State private var base: CGFloat?
    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(isHovering ? ChromeStyle.dividerHovered : ChromeStyle.divider)
            .frame(width: 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = base ?? appState.sidebarWidth
                        base = start
                        appState.setSidebarWidth(start + value.translation.width)
                    }
                    .onEnded { _ in base = nil }
            )
    }
}
