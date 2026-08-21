import XCTest
@testable import MoontermCore

final class HostConfigTests: XCTestCase {

    func testDisplayNameFallsBackToUserAtHost() {
        var host = HostConfig(host: "10.0.0.1", username: "root")
        XCTAssertEqual(host.displayName, "root@10.0.0.1")
        host.name = "生产机"
        XCTAssertEqual(host.displayName, "生产机")
    }

    func testEndpointDescriptionHidesDefaultPort() {
        XCTAssertEqual(
            HostConfig(host: "10.0.0.1", port: 22, username: "root").endpointDescription,
            "root@10.0.0.1"
        )
        XCTAssertEqual(
            HostConfig(host: "10.0.0.1", port: 2222, username: "root").endpointDescription,
            "root@10.0.0.1:2222"
        )
    }

    func testValidation() {
        XCTAssertThrowsError(try HostConfig(host: "", username: "root").validate())
        XCTAssertThrowsError(try HostConfig(host: "10.0.0.1", username: "").validate())
        XCTAssertThrowsError(try HostConfig(host: "10.0.0.1", port: 0, username: "root").validate())
        XCTAssertThrowsError(try HostConfig(host: "10.0.0.1", port: 70000, username: "root").validate())
        // 以 - 开头会被 ssh 当成选项。
        XCTAssertThrowsError(try HostConfig(host: "-oProxyCommand=x", username: "root").validate())
        XCTAssertNoThrow(try HostConfig(host: "10.0.0.1", port: 2222, username: "root").validate())
    }

    func testDecodingToleratesMissingFields() throws {
        let json = Data(#"{"host":"10.0.0.1"}"#.utf8)
        let host = try JSONDecoder().decode(HostConfig.self, from: json)
        XCTAssertEqual(host.host, "10.0.0.1")
        XCTAssertEqual(host.port, 22)
        XCTAssertTrue(host.acceptNewHostKey)
    }
}

final class ConfigStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moonterm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> ConfigStore {
        ConfigStore(
            fileURL: directory.appendingPathComponent("hosts.json"),
            secrets: PlaintextFileSecretStore(directory: directory)
        )
    }

    func testSaveAndReloadRoundTrip() {
        let store = makeStore()
        let host = HostConfig(name: "  生产机  ", host: " 10.0.0.1 ", port: 2222, username: " root ")
        store.save(host, password: "s3cret")

        // 保存时会 trim。
        XCTAssertEqual(store.hosts.first?.name, "生产机")
        XCTAssertEqual(store.hosts.first?.host, "10.0.0.1")
        XCTAssertEqual(store.hosts.first?.username, "root")

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.hosts.count, 1)
        XCTAssertEqual(reloaded.hosts.first?.port, 2222)
        XCTAssertEqual(reloaded.password(for: reloaded.hosts[0]), "s3cret")
    }

    func testSaveOverwritesSameID() {
        let store = makeStore()
        var host = HostConfig(host: "10.0.0.1", username: "root")
        store.save(host, password: "a")
        host.username = "deploy"
        store.save(host, password: "b")

        XCTAssertEqual(store.hosts.count, 1)
        XCTAssertEqual(store.hosts[0].username, "deploy")
        XCTAssertEqual(store.password(for: host), "b")
    }

    func testRemoveAlsoDropsPassword() {
        let store = makeStore()
        let host = HostConfig(host: "10.0.0.1", username: "root")
        store.save(host, password: "s3cret")
        store.remove(id: host.id)

        XCTAssertTrue(store.hosts.isEmpty)
        XCTAssertEqual(store.password(for: host), "")
        XCTAssertEqual(makeStore().password(for: host), "")
    }

    func testDuplicateCopiesPassword() throws {
        let store = makeStore()
        let host = HostConfig(name: "生产机", host: "10.0.0.1", username: "root")
        store.save(host, password: "s3cret")

        let copy = try XCTUnwrap(store.duplicate(id: host.id))
        XCTAssertNotEqual(copy.id, host.id)
        XCTAssertEqual(copy.name, "生产机 副本")
        XCTAssertEqual(store.password(for: copy), "s3cret")
        XCTAssertEqual(store.hosts.count, 2)
    }

    func testFilesAreOwnerOnly() throws {
        let store = makeStore()
        store.save(HostConfig(host: "10.0.0.1", username: "root"), password: "s3cret")

        for name in ["hosts.json", "secrets.json"] {
            let path = directory.appendingPathComponent(name).path
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
            XCTAssertEqual(permissions.int16Value, 0o600, "\(name) 的权限应该是 0600")
        }
    }
}
