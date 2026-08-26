import XCTest
@testable import MoontermCore

final class RemoteFileMutationValidatorTests: XCTestCase {

    func testRenameDestinationDetectsEveryEntryKind() {
        let entries = [
            entry("folder", kind: .directory),
            entry("file.txt", kind: .file),
            entry("link", kind: .symlink)
        ]

        XCTAssertTrue(RemoteFileMutationValidator.renameDestinationExists("/work/folder", in: entries))
        XCTAssertTrue(RemoteFileMutationValidator.renameDestinationExists("/work/file.txt", in: entries))
        XCTAssertTrue(RemoteFileMutationValidator.renameDestinationExists("/work/link", in: entries))
        XCTAssertFalse(RemoteFileMutationValidator.renameDestinationExists("/work/new-name", in: entries))
    }

    func testRenameDestinationNormalizesPath() {
        XCTAssertTrue(
            RemoteFileMutationValidator.renameDestinationExists(
                "/work//folder/",
                in: [entry("folder", kind: .directory)]
            )
        )
    }

    private func entry(_ name: String, kind: RemoteFileEntry.Kind) -> RemoteFileEntry {
        RemoteFileEntry(
            path: "/work/\(name)",
            name: name,
            kind: kind,
            size: 0,
            modeText: kind == .directory ? "drwxr-xr-x" : "-rw-r--r--",
            owner: "me",
            group: "me",
            dateText: "Aug 26 13:00"
        )
    }
}
