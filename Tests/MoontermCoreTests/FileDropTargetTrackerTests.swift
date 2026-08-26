import XCTest
@testable import MoontermCore

final class FileDropTargetTrackerTests: XCTestCase {

    /// 向下跨行时 AppKit 可能先报新行进入、再报旧行离开；旧事件不能清掉同目录的新落点。
    func testLateExitFromPreviousRowKeepsSameDirectoryHighlighted() {
        var tracker = FileDropTargetTracker()
        tracker.setTarget(rowPath: "/folder/a", destination: "/folder", isTargeted: true)
        tracker.setTarget(rowPath: "/folder/b", destination: "/folder", isTargeted: true)
        tracker.setTarget(rowPath: "/folder/a", destination: "/folder", isTargeted: false)

        XCTAssertEqual(tracker.destination, "/folder")
    }

    func testLateExitFromPreviousRowKeepsNewDifferentDestination() {
        var tracker = FileDropTargetTracker()
        tracker.setTarget(rowPath: "/folder/a", destination: "/folder", isTargeted: true)
        tracker.setTarget(rowPath: "/other", destination: "/other", isTargeted: true)
        tracker.setTarget(rowPath: "/folder/a", destination: "/folder", isTargeted: false)

        XCTAssertEqual(tracker.destination, "/other")
    }

    func testLeavingCurrentRowFallsBackToStillActivePreviousRow() {
        var tracker = FileDropTargetTracker()
        tracker.setTarget(rowPath: "/folder/a", destination: "/folder", isTargeted: true)
        tracker.setTarget(rowPath: "/other", destination: "/other", isTargeted: true)
        tracker.setTarget(rowPath: "/other", destination: "/other", isTargeted: false)

        XCTAssertEqual(tracker.destination, "/folder")
    }

    func testClearDropsAllTargets() {
        var tracker = FileDropTargetTracker()
        tracker.setTarget(rowPath: "/folder/a", destination: "/folder", isTargeted: true)

        tracker.clear()

        XCTAssertNil(tracker.destination)
    }
}
