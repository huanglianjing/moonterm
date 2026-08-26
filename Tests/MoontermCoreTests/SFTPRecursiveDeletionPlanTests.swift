import XCTest
@testable import MoontermCore

final class SFTPRecursiveDeletionPlanTests: XCTestCase {

    func testDiscoveryProducesFilesFirstAndDirectoriesDeepestFirst() throws {
        var plan = SFTPRecursiveDeletionPlan(rootDirectory: "/tree")
        XCTAssertEqual(plan.nextDirectory, "/tree")
        XCTAssertNil(plan.deletionCommands)

        XCTAssertTrue(plan.record(contents: [
            entry("/tree/a", kind: .directory),
            entry("/tree/root.txt", kind: .file),
            entry("/tree/link", kind: .symlink)
        ], of: "/tree"))
        XCTAssertEqual(plan.nextDirectory, "/tree/a")

        XCTAssertTrue(plan.record(contents: [
            entry("/tree/a/b", kind: .directory),
            entry("/tree/a/a.txt", kind: .file)
        ], of: "/tree/a"))
        XCTAssertTrue(plan.record(contents: [
            entry("/tree/a/b/deep.txt", kind: .file)
        ], of: "/tree/a/b"))

        XCTAssertNil(plan.nextDirectory)
        XCTAssertEqual(plan.deletionCommands, [
            "rm \"/tree/root.txt\"",
            "rm \"/tree/link\"",
            "rm \"/tree/a/a.txt\"",
            "rm \"/tree/a/b/deep.txt\"",
            "rmdir \"/tree/a/b\"",
            "rmdir \"/tree/a\"",
            "rmdir \"/tree\""
        ])
    }

    func testOutOfOrderListingDoesNotAdvancePlan() {
        var plan = SFTPRecursiveDeletionPlan(rootDirectory: "/tree")

        XCTAssertFalse(plan.record(contents: [], of: "/other"))
        XCTAssertEqual(plan.nextDirectory, "/tree")
        XCTAssertNil(plan.deletionCommands)
    }

    private func entry(_ path: String, kind: RemoteFileEntry.Kind) -> RemoteFileEntry {
        RemoteFileEntry(
            path: path,
            name: RemotePath.name(of: path),
            kind: kind,
            size: 0,
            modeText: "",
            owner: "",
            group: "",
            dateText: ""
        )
    }
}
