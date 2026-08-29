import XCTest
@testable import MoontermCore

final class UploadProgressProbeTests: XCTestCase {

    func testNewFileAcceptsFirstObservedSize() {
        var probe = UploadProgressProbe(initialRemoteSize: nil)

        XCTAssertEqual(probe.accept(remoteSize: 12), 12)
    }

    func testOverwriteIgnoresOldSizeUntilWriteIsObserved() {
        var probe = UploadProgressProbe(initialRemoteSize: 100)

        XCTAssertNil(probe.accept(remoteSize: 100))
        XCTAssertEqual(probe.accept(remoteSize: 0), 0)
        XCTAssertEqual(probe.accept(remoteSize: 100), 100)
    }
}
