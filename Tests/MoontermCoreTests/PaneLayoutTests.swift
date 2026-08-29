import XCTest
@testable import MoontermCore

final class PaneLayoutTests: XCTestCase {

    // 用固定的会话 id，断言读起来清楚些。
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()
    private let d = UUID()

    // MARK: - 辅助

    /// 展开成 (轴向, 各分栏当前显示的会话, 占比) 的浅层描述，方便断言。
    private func describe(_ node: PaneNode) -> (axis: PaneAxis, sessions: [UUID?], fractions: [CGFloat])? {
        guard case .split(let axis, let children) = node.content else { return nil }
        return (axis, children.map { $0.node.activeSessionID }, children.map { $0.fraction })
    }

    private func assertFractions(
        _ actual: [CGFloat],
        _ expected: [CGFloat],
        _ message: String = "",
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, message, line: line)
        for (lhs, rhs) in zip(actual, expected) {
            XCTAssertEqual(lhs, rhs, accuracy: 0.0001, message, line: line)
        }
    }

    // MARK: - 插入

    func testInsertOnLeafCreatesSplit() {
        var root = PaneNode.terminal(a)
        XCTAssertTrue(root.insert(sessionID: b, relativeTo: a, edge: .trailing))

        let split = describe(root)
        XCTAssertEqual(split?.axis, .horizontal)
        XCTAssertEqual(split?.sessions, [a, b])
        assertFractions(split?.fractions ?? [], [0.5, 0.5])
    }

    func testInsertLeadingPutsNewPaneFirst() {
        var root = PaneNode.terminal(a)
        root.insert(sessionID: b, relativeTo: a, edge: .leading)
        XCTAssertEqual(describe(root)?.sessions, [b, a])
    }

    func testInsertTopUsesVerticalAxis() {
        var root = PaneNode.terminal(a)
        root.insert(sessionID: b, relativeTo: a, edge: .top)

        XCTAssertEqual(describe(root)?.axis, .vertical)
        XCTAssertEqual(describe(root)?.sessions, [b, a])
    }

    /// 同轴插入要保持扁平：三栏就是三个同级子节点，而不是嵌套。
    func testSameAxisInsertStaysFlat() {
        var root = PaneNode.terminal(a)
        root.insert(sessionID: b, relativeTo: a, edge: .trailing)
        root.insert(sessionID: c, relativeTo: b, edge: .trailing)

        let split = describe(root)
        XCTAssertEqual(split?.axis, .horizontal)
        XCTAssertEqual(split?.sessions, [a, b, c])
        // 新分栏只吃目标分栏的一半，a 不受影响。
        assertFractions(split?.fractions ?? [], [0.5, 0.25, 0.25])
    }

    /// 异轴插入要嵌套：b 变成一个上下分栏的子树。
    func testCrossAxisInsertNests() {
        var root = PaneNode.terminal(a)
        root.insert(sessionID: b, relativeTo: a, edge: .trailing)
        root.insert(sessionID: c, relativeTo: b, edge: .bottom)

        let outer = describe(root)
        XCTAssertEqual(outer?.axis, .horizontal)
        XCTAssertEqual(outer?.sessions, [a, nil])
        assertFractions(outer?.fractions ?? [], [0.5, 0.5])

        guard case .split(_, let children) = root.content else { return XCTFail("根节点应该是 split") }
        let inner = describe(children[1].node)
        XCTAssertEqual(inner?.axis, .vertical)
        XCTAssertEqual(inner?.sessions, [b, c])
    }

    func testInsertRelativeToUnknownSessionFails() {
        var root = PaneNode.terminal(a)
        XCTAssertFalse(root.insert(sessionID: c, relativeTo: b, edge: .trailing))
        XCTAssertEqual(root.sessionIDs, [a])
    }

    func testSessionIDsFollowVisualOrder() {
        var root = PaneNode.terminal(a)
        root.insert(sessionID: b, relativeTo: a, edge: .trailing)
        root.insert(sessionID: c, relativeTo: b, edge: .bottom)
        XCTAssertEqual(root.sessionIDs, [a, b, c])
        XCTAssertEqual(root.paneCount, 3)
    }

    // MARK: - 预设布局

    func testSideBySidePresetKeepsCurrentPaneOnTheLeft() {
        var root = PaneNode.terminal(a)

        XCTAssertTrue(root.split(relativeTo: a, preset: .sideBySide, newSessionIDs: [b]))
        XCTAssertEqual(describe(root)?.axis, .horizontal)
        XCTAssertEqual(describe(root)?.sessions, [a, b])
        assertFractions(describe(root)?.fractions ?? [], [0.5, 0.5])
    }

    func testStackedPresetKeepsCurrentPaneOnTop() {
        var root = PaneNode.terminal(a)

        XCTAssertTrue(root.split(relativeTo: a, preset: .stacked, newSessionIDs: [b]))
        XCTAssertEqual(describe(root)?.axis, .vertical)
        XCTAssertEqual(describe(root)?.sessions, [a, b])
    }

    func testGridPresetCreatesFourEqualPanesWithColumnsOutside() {
        var root = PaneNode.terminal(a)

        XCTAssertTrue(root.split(relativeTo: a, preset: .grid, newSessionIDs: [b, c, d]))
        XCTAssertEqual(root.sessionIDs, [a, c, b, d], "外层按左列、右列遍历")
        XCTAssertEqual(root.paneCount, 4)

        guard case .split(let axis, let columns) = root.content else {
            return XCTFail("四宫格根节点应为左右布局")
        }
        XCTAssertEqual(axis, .horizontal)
        assertFractions(columns.map(\.fraction), [0.5, 0.5])
        XCTAssertEqual(describe(columns[0].node)?.axis, .vertical)
        XCTAssertEqual(describe(columns[0].node)?.sessions, [a, c])
        assertFractions(describe(columns[0].node)?.fractions ?? [], [0.5, 0.5])
        XCTAssertEqual(describe(columns[1].node)?.axis, .vertical)
        XCTAssertEqual(describe(columns[1].node)?.sessions, [b, d])
        assertFractions(describe(columns[1].node)?.fractions ?? [], [0.5, 0.5])
    }

    /// 目标旁边已经有分栏时，四宫格只能吃掉目标原来的那一半，不能重排整棵树。
    func testGridPresetStaysInsideTargetsExistingArea() {
        var root = PaneNode.terminal(a)
        root.insert(sessionID: d, relativeTo: a, edge: .trailing)

        XCTAssertTrue(root.split(relativeTo: a, preset: .grid, newSessionIDs: [b, c, UUID()]))

        guard case .split(let axis, let columns) = root.content else {
            return XCTFail("根节点应保留左右布局")
        }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(columns.count, 3, "同轴的左右布局会拍平到原有父节点")
        assertFractions(columns.map(\.fraction), [0.25, 0.25, 0.5])
        XCTAssertEqual(describe(columns[0].node)?.axis, .vertical)
        XCTAssertEqual(describe(columns[0].node)?.sessions, [a, c])
        XCTAssertEqual(describe(columns[1].node)?.axis, .vertical)
        XCTAssertEqual(describe(columns[1].node)?.sessions.count, 2)
        XCTAssertEqual(columns[2].node.activeSessionID, d)
    }

    func testPresetRejectsWrongOrDuplicateSessionsWithoutChangingTree() {
        let original = PaneNode.terminal(a)
        var root = original

        XCTAssertFalse(root.split(relativeTo: a, preset: .grid, newSessionIDs: [b]))
        XCTAssertEqual(root, original)
        XCTAssertFalse(root.split(relativeTo: a, preset: .grid, newSessionIDs: [b, b, c]))
        XCTAssertEqual(root, original)
    }

    // MARK: - 窗口排列

    func testArrangeGroupSideBySideUsesOriginalWindowOrderAndEqualFractions() {
        var root = PaneNode.terminal(a)
        root.join(sessionID: b, into: a, at: nil)
        root.join(sessionID: c, into: a, at: nil)

        XCTAssertTrue(root.arrangeGroup(containing: b, axis: .horizontal))
        XCTAssertEqual(describe(root)?.axis, .horizontal)
        XCTAssertEqual(describe(root)?.sessions, [a, b, c])
        assertFractions(describe(root)?.fractions ?? [], [1.0 / 3, 1.0 / 3, 1.0 / 3])
        XCTAssertTrue(root.sessionIDs.allSatisfy { root.group(containing: $0)?.count == 1 })
    }

    func testArrangeGroupVerticallyUsesOriginalWindowOrder() {
        var root = PaneNode.terminal(a)
        root.join(sessionID: b, into: a, at: nil)

        XCTAssertTrue(root.arrangeGroup(containing: a, axis: .vertical))
        XCTAssertEqual(describe(root)?.axis, .vertical)
        XCTAssertEqual(describe(root)?.sessions, [a, b])
    }

    func testArrangeGroupIntoMatchingParentOnlyDividesTargetsFraction() {
        var root = PaneNode.terminal(a)
        root.join(sessionID: b, into: a, at: nil)
        root.insert(sessionID: c, relativeTo: a, edge: .trailing)

        XCTAssertTrue(root.arrangeGroup(containing: a, axis: .horizontal))
        XCTAssertEqual(describe(root)?.axis, .horizontal)
        XCTAssertEqual(describe(root)?.sessions, [a, b, c])
        assertFractions(describe(root)?.fractions ?? [], [0.25, 0.25, 0.5])
    }

    func testArrangeGroupAcrossParentAxisNestsInsideTargetArea() {
        var root = PaneNode.terminal(a)
        root.join(sessionID: b, into: a, at: nil)
        root.insert(sessionID: c, relativeTo: a, edge: .bottom)

        XCTAssertTrue(root.arrangeGroup(containing: a, axis: .horizontal))

        guard case .split(let axis, let children) = root.content else {
            return XCTFail("外层应保留上下布局")
        }
        XCTAssertEqual(axis, .vertical)
        XCTAssertEqual(describe(children[0].node)?.axis, .horizontal)
        XCTAssertEqual(describe(children[0].node)?.sessions, [a, b])
        XCTAssertEqual(children[1].node.activeSessionID, c)
    }

    func testArrangeSingleWindowDoesNothing() {
        let original = PaneNode.terminal(a)
        var root = original

        XCTAssertFalse(root.arrangeGroup(containing: a, axis: .horizontal))
        XCTAssertEqual(root, original)
    }

    // MARK: - 删除

    func testRemoveRedistributesFractionsProportionally() {
        var root = PaneNode.terminal(a)
        root.insert(sessionID: b, relativeTo: a, edge: .trailing)
        root.insert(sessionID: c, relativeTo: b, edge: .trailing)  // [a 0.5, b 0.25, c 0.25]

        XCTAssertTrue(root.remove(sessionID: b))
        let split = describe(root)
        XCTAssertEqual(split?.sessions, [a, c])
        // 腾出的 0.25 按原比例分给 a 与 c。
        assertFractions(split?.fractions ?? [], [2.0 / 3, 1.0 / 3])
    }

    func testRemoveCollapsesSingleChildSplit() {
        var root = PaneNode.terminal(a)
        root.insert(sessionID: b, relativeTo: a, edge: .trailing)
        root.insert(sessionID: c, relativeTo: b, edge: .bottom)  // h[a, v[b, c]]

        XCTAssertTrue(root.remove(sessionID: a))
        let split = describe(root)
        XCTAssertEqual(split?.axis, .vertical)
        XCTAssertEqual(split?.sessions, [b, c])
    }

    /// 收起后如果和父级同轴，要拍平成一层。
    func testRemoveFlattensSameAxisNesting() {
        var root = PaneNode.terminal(a)
        root.insert(sessionID: b, relativeTo: a, edge: .trailing)  // h[a, b]
        root.insert(sessionID: c, relativeTo: b, edge: .bottom)    // h[a, v[b, c]]
        root.insert(sessionID: d, relativeTo: b, edge: .trailing)  // h[a, v[h[b, d], c]]

        XCTAssertTrue(root.remove(sessionID: c))

        let split = describe(root)
        XCTAssertEqual(split?.axis, .horizontal)
        XCTAssertEqual(split?.sessions, [a, b, d], "同轴嵌套应被拍平成三栏")
        assertFractions(split?.fractions ?? [], [0.5, 0.25, 0.25])
    }

    func testRemoveRootLeafFails() {
        var root = PaneNode.terminal(a)
        XCTAssertFalse(root.remove(sessionID: a), "树不能为空，根叶子由调用方连整个 tab 一起删")
        XCTAssertEqual(root.sessionIDs, [a])
    }

    func testRemoveUnknownSessionFails() {
        var root = PaneNode.terminal(a)
        root.insert(sessionID: b, relativeTo: a, edge: .trailing)
        XCTAssertFalse(root.remove(sessionID: c))
        XCTAssertEqual(root.sessionIDs, [a, b])
    }

    // MARK: - 移动与交换

    func testMoveRelocatesPane() {
        var root = PaneNode.terminal(a)
        root.insert(sessionID: b, relativeTo: a, edge: .trailing)
        root.insert(sessionID: c, relativeTo: b, edge: .trailing)  // h[a, b, c]

        XCTAssertTrue(root.move(sessionID: c, relativeTo: a, edge: .leading))
        XCTAssertEqual(describe(root)?.sessions, [c, a, b])
    }

    func testMoveAcrossAxisNests() {
        var root = PaneNode.terminal(a)
        root.insert(sessionID: b, relativeTo: a, edge: .trailing)
        root.insert(sessionID: c, relativeTo: b, edge: .trailing)  // h[a, b, c]

        XCTAssertTrue(root.move(sessionID: c, relativeTo: a, edge: .bottom))
        XCTAssertEqual(root.sessionIDs, [a, c, b])

        guard case .split(let axis, let children) = root.content else { return XCTFail("应为 split") }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(describe(children[0].node)?.axis, .vertical)
        XCTAssertEqual(describe(children[0].node)?.sessions, [a, c])
    }

    func testMoveOntoItselfFails() {
        var root = PaneNode.terminal(a)
        root.insert(sessionID: b, relativeTo: a, edge: .trailing)
        XCTAssertFalse(root.move(sessionID: a, relativeTo: a, edge: .bottom))
        XCTAssertEqual(root.sessionIDs, [a, b])
    }

    /// 落回当前所在的一侧不能把树拆掉重建：节点 id 一换，UI 层会把长期持有的终端 NSView 拆下来。
    func testMoveToCurrentTrailingPositionKeepsTreeIdentity() {
        var root = PaneNode.terminal(a)
        root.insert(sessionID: b, relativeTo: a, edge: .trailing)
        let original = root

        XCTAssertFalse(root.move(sessionID: b, relativeTo: a, edge: .trailing))
        XCTAssertEqual(root, original)
    }

    func testMoveToCurrentLeadingAndVerticalPositionsKeepsTreeIdentity() {
        for edge in [PaneEdge.leading, .top, .bottom] {
            var root = PaneNode.terminal(a)
            root.insert(sessionID: b, relativeTo: a, edge: edge)
            let original = root

            XCTAssertFalse(root.move(sessionID: b, relativeTo: a, edge: edge))
            XCTAssertEqual(root, original)
        }
    }

    func testMoveToCurrentPositionInsideNestedSplitKeepsTreeIdentity() {
        var root = PaneNode.terminal(a)
        root.insert(sessionID: c, relativeTo: a, edge: .top)
        root.insert(sessionID: b, relativeTo: a, edge: .trailing)  // v[c, h[a, b]]
        let original = root

        XCTAssertFalse(root.move(sessionID: b, relativeTo: a, edge: .trailing))
        XCTAssertEqual(root, original)
    }

    /// 同一栏里还有别的窗口时，拖出去仍然是在创建独立分栏，不能被“已经相邻”短路。
    func testMoveFromGroupToAdjacentEdgeStillSplits() {
        var root = PaneNode.terminal(a)
        root.join(sessionID: b, into: a, at: nil)
        root.insert(sessionID: c, relativeTo: a, edge: .trailing)  // h[[a, b], c]

        XCTAssertTrue(root.move(sessionID: b, relativeTo: c, edge: .leading))
        XCTAssertEqual(root.paneCount, 3)
        XCTAssertEqual(root.sessionIDs, [a, b, c])
        XCTAssertEqual(root.group(containing: a)?.sessionIDs, [a])
    }

    // MARK: - 会话组（一个分栏里放多个会话）

    func testJoinPutsSessionIntoAnotherPanesGroup() {
        var root = PaneNode.terminal(a)
        root.insert(sessionID: b, relativeTo: a, edge: .trailing)  // h[a, b]

        XCTAssertTrue(root.join(sessionID: b, into: a, at: nil))

        // 两栏并成一栏：分栏数回到 1，会话还是两个。
        XCTAssertEqual(root.paneCount, 1)
        XCTAssertEqual(root.sessionCount, 2)
        XCTAssertEqual(root.group?.sessionIDs, [a, b])
        XCTAssertEqual(root.group?.activeID, b, "并进来的那个直接显示")
        XCTAssertEqual(root.activeSessionIDs, [b])
    }

    func testJoinAtIndex() {
        var root = PaneNode.terminal(a)
        root.insert(sessionID: b, relativeTo: a, edge: .trailing)
        root.insert(sessionID: c, relativeTo: b, edge: .trailing)  // h[a, b, c]

        XCTAssertTrue(root.join(sessionID: c, into: a, at: 0))
        XCTAssertEqual(root.paneCount, 2)
        XCTAssertEqual(root.group(containing: a)?.sessionIDs, [c, a])
    }

    func testJoinReordersWithinSameGroup() {
        var root = PaneNode.terminal(a)
        root.insert(sessionID: b, relativeTo: a, edge: .trailing)
        root.join(sessionID: b, into: a, at: nil)  // 一栏里 [a, b]

        XCTAssertTrue(root.join(sessionID: b, into: a, at: 0))
        XCTAssertEqual(root.group?.sessionIDs, [b, a])
        XCTAssertEqual(root.paneCount, 1)
    }

    func testJoinFromOutsideTheTree() {
        var root = PaneNode.terminal(a)
        XCTAssertTrue(root.join(sessionID: d, into: a, at: nil))
        XCTAssertEqual(root.group?.sessionIDs, [a, d])
    }

    func testActivateSwitchesVisibleSession() {
        var root = PaneNode.terminal(a)
        root.join(sessionID: b, into: a, at: nil)
        XCTAssertEqual(root.group?.activeID, b)

        XCTAssertTrue(root.activate(sessionID: a))
        XCTAssertEqual(root.group?.activeID, a)
        XCTAssertEqual(root.sessionIDs, [a, b], "切换显示不改顺序")
    }

    func testRemoveFromGroupKeepsThePane() {
        var root = PaneNode.terminal(a)
        root.insert(sessionID: c, relativeTo: a, edge: .trailing)  // h[a, c]
        root.join(sessionID: b, into: a, at: nil)                  // h[[a, b], c]

        XCTAssertTrue(root.remove(sessionID: b))
        XCTAssertEqual(root.paneCount, 2, "组里还有 a，分栏不该消失")
        XCTAssertEqual(root.group(containing: a)?.sessionIDs, [a])
        XCTAssertEqual(describe(root)?.sessions, [a, c])
    }

    func testRemoveActiveSessionShiftsToNeighbour() {
        var root = PaneNode.terminal(a)
        root.join(sessionID: b, into: a, at: nil)  // [a, b]，显示 b
        root.join(sessionID: c, into: a, at: nil)  // [a, b, c]，显示 c

        XCTAssertTrue(root.remove(sessionID: c))
        XCTAssertEqual(root.group?.sessionIDs, [a, b])
        XCTAssertEqual(root.group?.activeID, b, "关掉最后一个小标签时焦点退到左边")
    }

    func testRemoveLastSessionOfPaneCollapsesSplit() {
        var root = PaneNode.terminal(a)
        root.insert(sessionID: c, relativeTo: a, edge: .trailing)  // h[a, c]
        root.join(sessionID: b, into: a, at: nil)                  // h[[a, b], c]

        XCTAssertTrue(root.remove(sessionID: c))
        XCTAssertEqual(root.paneCount, 1)
        XCTAssertEqual(root.group?.sessionIDs, [a, b])
    }

    func testRemoveLastSessionOfRootPaneFails() {
        var root = PaneNode.terminal(a)
        root.join(sessionID: b, into: a, at: nil)
        XCTAssertTrue(root.remove(sessionID: b))
        XCTAssertFalse(root.remove(sessionID: a), "整棵树只剩一个会话时交给调用方删 tab")
    }

    func testInsertNextToMultiSessionPaneKeepsGroupIntact() {
        var root = PaneNode.terminal(a)
        root.join(sessionID: b, into: a, at: nil)  // 一栏两个会话

        XCTAssertTrue(root.insert(sessionID: c, relativeTo: b, edge: .trailing))
        XCTAssertEqual(root.paneCount, 2)
        XCTAssertEqual(root.group(containing: a)?.sessionIDs, [a, b])
        XCTAssertEqual(describe(root)?.sessions, [b, c], "左栏显示的还是原来那个 b")
    }

    func testMovePullsSessionOutOfGroupIntoItsOwnPane() {
        var root = PaneNode.terminal(a)
        root.join(sessionID: b, into: a, at: nil)  // 一栏 [a, b]

        // 以同组的 a 为锚点，把 b 拉到右边单独成栏。
        XCTAssertTrue(root.move(sessionID: b, relativeTo: a, edge: .trailing))
        XCTAssertEqual(root.paneCount, 2)
        XCTAssertEqual(describe(root)?.sessions, [a, b])
        XCTAssertEqual(root.group(containing: a)?.count, 1)
    }

    // MARK: - 占比

    func testSetFractionsNormalizes() {
        var root = PaneNode.terminal(a)
        root.insert(sessionID: b, relativeTo: a, edge: .trailing)

        XCTAssertTrue(root.setFractions([3, 1], forSplit: root.id))
        assertFractions(describe(root)?.fractions ?? [], [0.75, 0.25])
    }

    func testSetFractionsClampsNegatives() {
        var root = PaneNode.terminal(a)
        root.insert(sessionID: b, relativeTo: a, edge: .trailing)

        XCTAssertTrue(root.setFractions([-1, 1], forSplit: root.id))
        assertFractions(describe(root)?.fractions ?? [], [0, 1])
    }

    func testSetFractionsRejectsWrongCount() {
        var root = PaneNode.terminal(a)
        root.insert(sessionID: b, relativeTo: a, edge: .trailing)
        XCTAssertFalse(root.setFractions([1, 1, 1], forSplit: root.id))
    }

    func testSetFractionsReachesNestedSplit() {
        var root = PaneNode.terminal(a)
        root.insert(sessionID: b, relativeTo: a, edge: .trailing)
        root.insert(sessionID: c, relativeTo: b, edge: .bottom)  // h[a, v[b, c]]

        guard case .split(_, let children) = root.content else { return XCTFail("应为 split") }
        let innerID = children[1].node.id

        XCTAssertTrue(root.setFractions([0.8, 0.2], forSplit: innerID))
        guard case .split(_, let updated) = root.content else { return XCTFail("应为 split") }
        assertFractions(describe(updated[1].node)?.fractions ?? [], [0.8, 0.2])
        assertFractions(describe(root)?.fractions ?? [], [0.5, 0.5], "外层占比不受影响")
    }

    // MARK: - 分隔线归中

    func testEqualizeDividerOnlyChangesItsAdjacentPair() {
        var root = PaneNode.terminal(a)
        root.insert(sessionID: b, relativeTo: a, edge: .trailing)
        root.insert(sessionID: c, relativeTo: b, edge: .trailing)
        XCTAssertTrue(root.setFractions([0.5, 0.1, 0.4], forSplit: root.id))

        XCTAssertTrue(root.equalizeAdjacentChildren(atDivider: 1, forSplit: root.id))
        assertFractions(describe(root)?.fractions ?? [], [0.5, 0.25, 0.25])
    }

    func testEqualizeDividerReachesNestedSplit() {
        var root = PaneNode.terminal(a)
        root.insert(sessionID: b, relativeTo: a, edge: .trailing)
        root.insert(sessionID: c, relativeTo: b, edge: .bottom)

        guard case .split(_, let children) = root.content else {
            return XCTFail("根节点应为左右分栏")
        }
        let nestedID = children[1].node.id
        XCTAssertTrue(root.setFractions([0.8, 0.2], forSplit: nestedID))
        XCTAssertTrue(root.equalizeAdjacentChildren(atDivider: 0, forSplit: nestedID))

        guard case .split(_, let updated) = root.content else {
            return XCTFail("根节点应保持左右分栏")
        }
        assertFractions(describe(updated[1].node)?.fractions ?? [], [0.5, 0.5])
        assertFractions(updated.map(\.fraction), [0.5, 0.5])
    }

    func testEqualizeDividerRejectsInvalidTargetWithoutChangingTree() {
        var root = PaneNode.terminal(a)
        root.insert(sessionID: b, relativeTo: a, edge: .trailing)
        let original = root

        XCTAssertFalse(root.equalizeAdjacentChildren(atDivider: 1, forSplit: root.id))
        XCTAssertEqual(root, original)
        XCTAssertFalse(root.equalizeAdjacentChildren(atDivider: 0, forSplit: UUID()))
        XCTAssertEqual(root, original)
    }

    // MARK: - 分隔线接点

    func testDividerJunctionLinksWholeCross() {
        let verticalID = UUID()
        let leftID = UUID()
        let rightID = UUID()
        let dividers = [
            PaneDividerGeometry(
                splitID: verticalID,
                dividerIndex: 0,
                splitAxis: .horizontal,
                frame: CGRect(x: 99, y: 0, width: 2, height: 200)
            ),
            PaneDividerGeometry(
                splitID: leftID,
                dividerIndex: 0,
                splitAxis: .vertical,
                frame: CGRect(x: 0, y: 99, width: 99, height: 2)
            ),
            PaneDividerGeometry(
                splitID: rightID,
                dividerIndex: 0,
                splitAxis: .vertical,
                frame: CGRect(x: 101, y: 99, width: 99, height: 2)
            )
        ]

        let linked = PaneDividerJunction.linkedDividers(
            dragging: leftID,
            dividerIndex: 0,
            at: CGPoint(x: 99, y: 100),
            among: dividers
        )

        XCTAssertEqual(Set(linked.map(\.splitID)), Set([verticalID, leftID, rightID]))
        XCTAssertEqual(PaneDividerJunction.dragShape(
            dragging: leftID,
            dividerIndex: 0,
            at: CGPoint(x: 99, y: 100),
            among: dividers
        ), .cross)
    }

    func testDividerJunctionLinksTShape() {
        let verticalID = UUID()
        let branchID = UUID()
        let dividers = [
            PaneDividerGeometry(
                splitID: verticalID,
                dividerIndex: 0,
                splitAxis: .horizontal,
                frame: CGRect(x: 99, y: 0, width: 2, height: 200)
            ),
            PaneDividerGeometry(
                splitID: branchID,
                dividerIndex: 0,
                splitAxis: .vertical,
                frame: CGRect(x: 101, y: 99, width: 100, height: 2)
            )
        ]

        let linked = PaneDividerJunction.linkedDividers(
            dragging: verticalID,
            dividerIndex: 0,
            at: CGPoint(x: 100, y: 100),
            among: dividers
        )

        XCTAssertEqual(Set(linked.map(\.splitID)), Set([verticalID, branchID]))
        XCTAssertEqual(PaneDividerJunction.dragShape(
            dragging: verticalID,
            dividerIndex: 0,
            at: CGPoint(x: 100, y: 100),
            among: dividers
        ), .teeLeft)
    }

    func testDividerDragShapeRecognizesSinglesAndFourTOrientations() {
        let point = CGPoint(x: 100, y: 100)

        func shape(_ parts: [(PaneAxis, CGRect)]) -> PaneDividerDragShape? {
            let dividers = parts.map { part in
                PaneDividerGeometry(
                    splitID: UUID(),
                    dividerIndex: 0,
                    splitAxis: part.0,
                    frame: part.1
                )
            }
            return PaneDividerJunction.dragShape(
                dragging: dividers[0].splitID,
                dividerIndex: 0,
                at: point,
                among: dividers
            )
        }

        XCTAssertEqual(shape([
            (.horizontal, CGRect(x: 99, y: 0, width: 2, height: 200))
        ]), .leftRight)
        XCTAssertEqual(shape([
            (.vertical, CGRect(x: 0, y: 99, width: 200, height: 2))
        ]), .upDown)
        XCTAssertEqual(shape([
            (.vertical, CGRect(x: 0, y: 99, width: 200, height: 2)),
            (.horizontal, CGRect(x: 99, y: 101, width: 2, height: 99))
        ]), .teeTop)
        XCTAssertEqual(shape([
            (.vertical, CGRect(x: 0, y: 99, width: 200, height: 2)),
            (.horizontal, CGRect(x: 99, y: 0, width: 2, height: 99))
        ]), .teeBottom)
        XCTAssertEqual(shape([
            (.horizontal, CGRect(x: 99, y: 0, width: 2, height: 200)),
            (.vertical, CGRect(x: 101, y: 99, width: 99, height: 2))
        ]), .teeLeft)
        XCTAssertEqual(shape([
            (.horizontal, CGRect(x: 99, y: 0, width: 2, height: 200)),
            (.vertical, CGRect(x: 0, y: 99, width: 99, height: 2))
        ]), .teeRight)
    }

    func testDividerJunctionAcceptsFivePointGapButNotMore() {
        let verticalID = UUID()
        let nearID = UUID()
        let farID = UUID()
        let dividers = [
            PaneDividerGeometry(
                splitID: verticalID,
                dividerIndex: 0,
                splitAxis: .horizontal,
                frame: CGRect(x: 99, y: 0, width: 2, height: 200)
            ),
            PaneDividerGeometry(
                splitID: nearID,
                dividerIndex: 0,
                splitAxis: .vertical,
                frame: CGRect(x: 0, y: 99, width: 94, height: 2)
            ),
            PaneDividerGeometry(
                splitID: farID,
                dividerIndex: 0,
                splitAxis: .vertical,
                frame: CGRect(x: 0, y: 99, width: 93, height: 2)
            )
        ]

        let linked = PaneDividerJunction.linkedDividers(
            dragging: verticalID,
            dividerIndex: 0,
            // 按在 2 点主动线的远侧，仍应按两条线之间的 5 点空隙判定。
            at: CGPoint(x: 101, y: 100),
            among: dividers
        )

        XCTAssertEqual(Set(linked.map(\.splitID)), Set([verticalID, nearID]))
    }

    func testDividerJunctionDoesNotLinkAwayFromIntersection() {
        let verticalID = UUID()
        let horizontalID = UUID()
        let dividers = [
            PaneDividerGeometry(
                splitID: verticalID,
                dividerIndex: 0,
                splitAxis: .horizontal,
                frame: CGRect(x: 99, y: 0, width: 2, height: 200)
            ),
            PaneDividerGeometry(
                splitID: horizontalID,
                dividerIndex: 0,
                splitAxis: .vertical,
                frame: CGRect(x: 0, y: 99, width: 200, height: 2)
            )
        ]

        XCTAssertTrue(PaneDividerJunction.linkedDividers(
            dragging: verticalID,
            dividerIndex: 0,
            at: CGPoint(x: 100, y: 40),
            among: dividers
        ).isEmpty)
    }

    /// 高亮的整组不能随鼠标在热区里的位置增减：否则同一个接点上会时而三条线亮、时而一条。
    func testDividerJunctionGroupIsStableAcrossTheWholeHitZone() {
        let verticalID = UUID()
        let leftID = UUID()
        let rightID = UUID()
        let dividers = [
            PaneDividerGeometry(
                splitID: verticalID,
                dividerIndex: 0,
                splitAxis: .horizontal,
                frame: CGRect(x: 99, y: 0, width: 2, height: 200)
            ),
            PaneDividerGeometry(
                splitID: leftID,
                dividerIndex: 0,
                splitAxis: .vertical,
                frame: CGRect(x: 0, y: 99, width: 99, height: 2)
            ),
            PaneDividerGeometry(
                splitID: rightID,
                dividerIndex: 0,
                splitAxis: .vertical,
                frame: CGRect(x: 101, y: 99, width: 99, height: 2)
            )
        ]
        let whole = Set([verticalID, leftID, rightID])

        // 竖线热区：左右各 6 点。
        for x in [93, 96, 100, 104, 107] {
            XCTAssertEqual(Set(PaneDividerJunction.linkedDividers(
                dragging: verticalID,
                dividerIndex: 0,
                at: CGPoint(x: CGFloat(x), y: 100),
                among: dividers,
                sourceHitOutset: 6
            ).map(\.splitID)), whole, "竖线上 x=\(x) 处应锁住整个十字")
        }

        // 横线热区：上下各 6 点。
        for y in [93, 96, 100, 104, 107] {
            XCTAssertEqual(Set(PaneDividerJunction.linkedDividers(
                dragging: leftID,
                dividerIndex: 0,
                at: CGPoint(x: 96, y: CGFloat(y)),
                among: dividers,
                sourceHitOutset: 6
            ).map(\.splitID)), whole, "左横线上 y=\(y) 处应锁住整个十字")
        }
    }

    /// 热区伸出的那几点不能被当成“接点在鼠标处”：T 形在热区最外侧也还是 T 形。
    func testDividerDragShapeKeepsTeeAcrossTheWholeHitZone() {
        let verticalID = UUID()
        let branchID = UUID()
        let dividers = [
            PaneDividerGeometry(
                splitID: verticalID,
                dividerIndex: 0,
                splitAxis: .horizontal,
                frame: CGRect(x: 99, y: 0, width: 2, height: 200)
            ),
            PaneDividerGeometry(
                splitID: branchID,
                dividerIndex: 0,
                splitAxis: .vertical,
                frame: CGRect(x: 101, y: 99, width: 100, height: 2)
            )
        ]

        // 竖线一侧：贴着热区外沿（右侧 6 点）时，右边那条横线不能被算出一条“左腿”。
        for x in [93, 96, 100, 104, 107] {
            XCTAssertEqual(PaneDividerJunction.dragShape(
                dragging: verticalID,
                dividerIndex: 0,
                at: CGPoint(x: CGFloat(x), y: 100),
                among: dividers,
                sourceHitOutset: 6
            ), .teeLeft, "竖线上 x=\(x) 处应仍是 ├")
        }

        // 横线一侧：沿着横线离开接点时同样不该冒出左腿。
        for x in [102, 104, 106, 108] {
            XCTAssertEqual(PaneDividerJunction.dragShape(
                dragging: branchID,
                dividerIndex: 0,
                at: CGPoint(x: CGFloat(x), y: 100),
                among: dividers,
                sourceHitOutset: 6
            ), .teeLeft, "横线上 x=\(x) 处应仍是 ├")
        }
    }

    /// 十字接点里，鼠标偏到任一侧都不该退化成 T 形。
    func testDividerDragShapeKeepsCrossAcrossTheWholeHitZone() {
        let verticalID = UUID()
        let leftID = UUID()
        let rightID = UUID()
        let dividers = [
            PaneDividerGeometry(
                splitID: verticalID,
                dividerIndex: 0,
                splitAxis: .horizontal,
                frame: CGRect(x: 99, y: 0, width: 2, height: 200)
            ),
            PaneDividerGeometry(
                splitID: leftID,
                dividerIndex: 0,
                splitAxis: .vertical,
                frame: CGRect(x: 0, y: 99, width: 99, height: 2)
            ),
            PaneDividerGeometry(
                splitID: rightID,
                dividerIndex: 0,
                splitAxis: .vertical,
                frame: CGRect(x: 101, y: 99, width: 99, height: 2)
            )
        ]

        for x in [93, 100, 107] {
            XCTAssertEqual(PaneDividerJunction.dragShape(
                dragging: verticalID,
                dividerIndex: 0,
                at: CGPoint(x: CGFloat(x), y: 100),
                among: dividers,
                sourceHitOutset: 6
            ), .cross, "竖线上 x=\(x) 处应仍是 ┼")
        }
        for y in [94, 100, 106] {
            XCTAssertEqual(PaneDividerJunction.dragShape(
                dragging: leftID,
                dividerIndex: 0,
                at: CGPoint(x: 95, y: CGFloat(y)),
                among: dividers,
                sourceHitOutset: 6
            ), .cross, "左横线上 y=\(y) 处应仍是 ┼")
        }
    }

    func testDividerDragShapeUsesExpandedSourceHitOutset() {
        let verticalID = UUID()
        let horizontalID = UUID()
        let dividers = [
            PaneDividerGeometry(
                splitID: verticalID,
                dividerIndex: 0,
                splitAxis: .horizontal,
                frame: CGRect(x: 99, y: 0, width: 2, height: 200)
            ),
            PaneDividerGeometry(
                splitID: horizontalID,
                dividerIndex: 0,
                splitAxis: .vertical,
                frame: CGRect(x: 0, y: 99, width: 200, height: 2)
            )
        ]

        XCTAssertEqual(PaneDividerJunction.dragShape(
            dragging: verticalID,
            dividerIndex: 0,
            at: CGPoint(x: 107, y: 100),
            among: dividers,
            sourceHitOutset: 6
        ), .cross)
        XCTAssertNil(PaneDividerJunction.dragShape(
            dragging: verticalID,
            dividerIndex: 0,
            at: CGPoint(x: 108, y: 100),
            among: dividers,
            sourceHitOutset: 6
        ))
    }

    // MARK: - 分隔线磁吸

    func testDividerMagnetSnapsParallelVerticalLinesAtBoundary() {
        let source = PaneDividerGeometry(
            splitID: UUID(),
            dividerIndex: 0,
            splitAxis: .horizontal,
            frame: CGRect(x: 99, y: 0, width: 2, height: 100)
        )
        let lower = PaneDividerGeometry(
            splitID: UUID(),
            dividerIndex: 0,
            splitAxis: .horizontal,
            frame: CGRect(x: 149, y: 102, width: 2, height: 100)
        )

        // 两条线中心相距 50 点：位移差得刚好等于容差时要吸过去，多差 1 点就自由拖动。
        // 用容差本身表达而不写死数字 —— 这个值是可调的手感参数，要钉住的是边界规则。
        let gap: CGFloat = 50
        let tolerance = PaneDividerMagnet.tolerance
        XCTAssertEqual(PaneDividerMagnet.snappedTranslation(
            dragging: source,
            translation: gap - tolerance,
            among: [source, lower]
        ), gap)
        XCTAssertEqual(PaneDividerMagnet.snappedTranslation(
            dragging: source,
            translation: gap - tolerance - 1,
            among: [source, lower]
        ), gap - tolerance - 1)
    }

    func testDividerMagnetSnapsHorizontalLinesAndIgnoresPerpendicularOnes() {
        let source = PaneDividerGeometry(
            splitID: UUID(),
            dividerIndex: 0,
            splitAxis: .vertical,
            frame: CGRect(x: 0, y: 99, width: 100, height: 2)
        )
        let parallel = PaneDividerGeometry(
            splitID: UUID(),
            dividerIndex: 0,
            splitAxis: .vertical,
            frame: CGRect(x: 102, y: 129, width: 100, height: 2)
        )
        let perpendicular = PaneDividerGeometry(
            splitID: UUID(),
            dividerIndex: 0,
            splitAxis: .horizontal,
            frame: CGRect(x: 123, y: 0, width: 2, height: 200)
        )

        XCTAssertEqual(PaneDividerMagnet.snappedTranslation(
            dragging: source,
            translation: 24,
            among: [source, parallel, perpendicular]
        ), 30)
    }

    // MARK: - 落点判定

    private let rect = CGRect(x: 100, y: 200, width: 400, height: 300)

    func testResolveCenter() {
        XCTAssertEqual(PaneDropZone.resolve(point: CGPoint(x: 300, y: 350), in: rect), .center)
    }

    func testResolveEdges() {
        XCTAssertEqual(PaneDropZone.resolve(point: CGPoint(x: 120, y: 350), in: rect), .edge(.leading))
        XCTAssertEqual(PaneDropZone.resolve(point: CGPoint(x: 480, y: 350), in: rect), .edge(.trailing))
        // y 向下增长，所以靠上的点是 .top。
        XCTAssertEqual(PaneDropZone.resolve(point: CGPoint(x: 300, y: 210), in: rect), .edge(.top))
        XCTAssertEqual(PaneDropZone.resolve(point: CGPoint(x: 300, y: 490), in: rect), .edge(.bottom))
    }

    func testResolvePicksNearestEdgeInCorner() {
        // 左上角：归一化后 x 更近，取 .leading。
        XCTAssertEqual(PaneDropZone.resolve(point: CGPoint(x: 104, y: 215), in: rect), .edge(.leading))
    }

    func testNearestEdgeIgnoresCenter() {
        // 正中偏右一点：resolve 会说 center，nearestEdge 仍要给出一条边。
        XCTAssertEqual(PaneDropZone.resolve(point: CGPoint(x: 320, y: 350), in: rect), .center)
        XCTAssertEqual(PaneDropZone.nearestEdge(point: CGPoint(x: 320, y: 350), in: rect), .trailing)
    }

    func testResolveOnEmptyRectIsCenter() {
        XCTAssertEqual(PaneDropZone.resolve(point: .zero, in: .zero), .center)
    }

    func testMovePreviewUsesCenterForOnlyWindowDraggedOntoItself() {
        let sessionID = UUID()
        let zone = PaneDropZone.edge(.leading).previewingMove(
            movingSessionID: sessionID,
            targetSessionID: sessionID,
            targetPaneSessionCount: 1
        )

        XCTAssertEqual(zone, .center)
    }

    func testMovePreviewKeepsEdgeWhenSelfSplitCanChangeLayout() {
        let sessionID = UUID()
        let zone = PaneDropZone.edge(.bottom).previewingMove(
            movingSessionID: sessionID,
            targetSessionID: sessionID,
            targetPaneSessionCount: 2
        )

        XCTAssertEqual(zone, .edge(.bottom))
    }

    func testMovePreviewKeepsEdgeForAnotherTargetPane() {
        let zone = PaneDropZone.edge(.trailing).previewingMove(
            movingSessionID: UUID(),
            targetSessionID: UUID(),
            targetPaneSessionCount: 1
        )

        XCTAssertEqual(zone, .edge(.trailing))
    }

    // MARK: - 方位

    func testEdgeAxisAndOrder() {
        XCTAssertEqual(PaneEdge.leading.axis, .horizontal)
        XCTAssertEqual(PaneEdge.bottom.axis, .vertical)
        XCTAssertTrue(PaneEdge.top.insertsBefore)
        XCTAssertFalse(PaneEdge.trailing.insertsBefore)
    }
}
