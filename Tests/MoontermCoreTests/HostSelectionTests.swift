import XCTest
@testable import MoontermCore

final class HostSelectionTests: XCTestCase {

    private let a = UUID()
    private let b = UUID()
    private let c = UUID()
    private let d = UUID()

    private var order: [UUID] { [a, b, c, d] }

    // MARK: - 普通点击

    func testPlainClickSelectsOnlyThatOne() {
        var selection = HostSelection()
        selection.click(a, kind: .plain, in: order)
        XCTAssertEqual(selection.selected, [a])

        selection.click(c, kind: .plain, in: order)
        XCTAssertEqual(selection.selected, [c], "普通点击是重选，不累加")
        XCTAssertEqual(selection.anchor, c)
    }

    // MARK: - ⌘ 点

    func testCommandClickAddsAndRemoves() {
        var selection = HostSelection()
        selection.click(a, kind: .plain, in: order)
        selection.click(c, kind: .toggle, in: order)
        XCTAssertEqual(selection.selected, [a, c])

        selection.click(a, kind: .toggle, in: order)
        XCTAssertEqual(selection.selected, [c], "⌘ 点已选中的那个是取消选中")
    }

    func testCommandClickMovesAnchor() {
        var selection = HostSelection()
        selection.click(a, kind: .plain, in: order)
        selection.click(c, kind: .toggle, in: order)
        // 锚点跟到了 c，所以 ⇧ 点 d 只扩 c…d，不从 a 开始。
        selection.click(d, kind: .extend, in: order)
        XCTAssertEqual(selection.selected, [c, d])
    }

    // MARK: - ⇧ 点

    func testShiftClickExtendsFromAnchor() {
        var selection = HostSelection()
        selection.click(b, kind: .plain, in: order)
        selection.click(d, kind: .extend, in: order)
        XCTAssertEqual(selection.selected, [b, c, d])
    }

    func testShiftClickExtendsUpwards() {
        var selection = HostSelection()
        selection.click(c, kind: .plain, in: order)
        selection.click(a, kind: .extend, in: order)
        XCTAssertEqual(selection.selected, [a, b, c], "往上扩也一样")
    }

    func testRepeatedShiftClickReplacesRangeAndKeepsAnchor() {
        var selection = HostSelection()
        selection.click(b, kind: .plain, in: order)
        selection.click(d, kind: .extend, in: order)
        selection.click(c, kind: .extend, in: order)
        XCTAssertEqual(selection.selected, [b, c], "锚点不动，范围可以反复调")
        XCTAssertEqual(selection.anchor, b)
    }

    func testShiftClickWithoutAnchorBehavesLikePlainClick() {
        var selection = HostSelection()
        selection.click(c, kind: .extend, in: order)
        XCTAssertEqual(selection.selected, [c])
        XCTAssertEqual(selection.anchor, c)
    }

    func testShiftClickAfterAnchorDisappearedBehavesLikePlainClick() {
        var selection = HostSelection()
        selection.click(a, kind: .plain, in: order)
        // a 被删了：剩下的列表里找不到锚点。
        selection.remove([a])
        selection.click(c, kind: .extend, in: [b, c, d])
        XCTAssertEqual(selection.selected, [c])
    }

    // MARK: - 右键作用范围

    func testRightClickInsideSelectionTargetsWholeSelection() {
        var selection = HostSelection()
        selection.click(d, kind: .plain, in: order)
        selection.click(b, kind: .toggle, in: order)
        XCTAssertEqual(
            selection.targets(rightClicking: b, in: order),
            [b, d],
            "按列表顺序返回，不按选中的先后"
        )
    }

    func testRightClickOutsideSelectionTargetsOnlyThatOne() {
        var selection = HostSelection()
        selection.click(a, kind: .plain, in: order)
        selection.click(b, kind: .toggle, in: order)
        XCTAssertEqual(selection.targets(rightClicking: d, in: order), [d])
    }

    func testRightClickOnSingleSelectionTargetsOnlyThatOne() {
        var selection = HostSelection()
        selection.click(a, kind: .plain, in: order)
        XCTAssertEqual(selection.targets(rightClicking: a, in: order), [a])
    }

    // MARK: - 删除后的清理

    func testRemoveClearsDeletedIDsAndAnchor() {
        var selection = HostSelection()
        selection.click(a, kind: .plain, in: order)
        selection.click(b, kind: .toggle, in: order)
        selection.remove([b])
        XCTAssertEqual(selection.selected, [a])
        XCTAssertNil(selection.anchor, "锚点就是 b，删了之后不能留着")
    }
}
