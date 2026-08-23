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

    /// 副本紧挨着原主机：同一个分组，就在它下一个，不是排到分组末尾。
    func testDuplicateLandsRightAfterTheOriginal() throws {
        let store = makeStore()
        let group = store.addGroup(name: "生产")
        let first = HostConfig(name: "1", host: "10.0.0.1", username: "root", groupID: group.id)
        let second = HostConfig(name: "2", host: "10.0.0.2", username: "root", groupID: group.id)
        let loose = HostConfig(name: "3", host: "10.0.0.3", username: "root")
        [first, second, loose].forEach { store.save($0, password: "") }

        let copy = try XCTUnwrap(store.duplicate(id: first.id))
        XCTAssertEqual(copy.groupID, group.id)
        XCTAssertEqual(store.hosts(inGroup: group.id).map { $0.name }, ["1", "1 副本", "2"])
        XCTAssertEqual(store.hosts(inGroup: nil).map { $0.name }, ["3"], "未分组那段不受影响")

        // 重新读一遍：位置是存下来的，不是只在内存里对。
        XCTAssertEqual(makeStore().hosts.map { $0.name }, ["1", "1 副本", "2", "3"])
    }

    // MARK: - 分组

    /// 新建的主机一律排到最后 —— 也就是列表最下面（没选分组的话）。
    func testNewHostGoesToTheEnd() {
        let store = makeStore()
        let first = HostConfig(name: "1", host: "10.0.0.1", username: "root")
        let second = HostConfig(name: "2", host: "10.0.0.2", username: "root")
        store.save(first, password: "")
        store.save(second, password: "")
        XCTAssertEqual(store.hosts.map { $0.name }, ["1", "2"])
    }

    func testSectionsPutGroupsFirstAndUngroupedLast() {
        let store = makeStore()
        let a = store.addGroup(name: "A")
        let b = store.addGroup(name: "B")
        let loose = HostConfig(name: "loose", host: "10.0.0.9", username: "root")
        store.save(loose, password: "")
        store.save(HostConfig(name: "inB", host: "10.0.0.2", username: "root", groupID: b.id), password: "")
        store.save(HostConfig(name: "inA", host: "10.0.0.1", username: "root", groupID: a.id), password: "")

        // 数组顺序是 loose、inB、inA，但显示顺序按分组分段，未分组垫最后。
        XCTAssertEqual(store.sections.count, 3)
        XCTAssertEqual(store.sections[0].group?.name, "A")
        XCTAssertEqual(store.sections[0].hosts.map { $0.name }, ["inA"])
        XCTAssertEqual(store.sections[1].hosts.map { $0.name }, ["inB"])
        XCTAssertNil(store.sections[2].group)
        XCTAssertEqual(store.sections[2].hosts.map { $0.name }, ["loose"])
    }

    func testMoveHostIntoGroupBeforeAnchor() {
        let store = makeStore()
        let group = store.addGroup(name: "生产")
        let one = HostConfig(name: "1", host: "10.0.0.1", username: "root", groupID: group.id)
        let two = HostConfig(name: "2", host: "10.0.0.2", username: "root", groupID: group.id)
        let loose = HostConfig(name: "3", host: "10.0.0.3", username: "root")
        [one, two, loose].forEach { store.save($0, password: "") }

        store.move(hostIDs: [loose.id], toGroup: group.id, before: two.id)
        XCTAssertEqual(store.hosts(inGroup: group.id).map { $0.name }, ["1", "3", "2"])
        XCTAssertTrue(store.hosts(inGroup: nil).isEmpty)
    }

    /// `before: nil` = 放到那一段的末尾。
    func testMoveHostToEndOfGroup() {
        let store = makeStore()
        let group = store.addGroup(name: "生产")
        let one = HostConfig(name: "1", host: "10.0.0.1", username: "root", groupID: group.id)
        let two = HostConfig(name: "2", host: "10.0.0.2", username: "root", groupID: group.id)
        [one, two].forEach { store.save($0, password: "") }

        store.move(hostIDs: [one.id], toGroup: group.id, before: nil)
        XCTAssertEqual(store.hosts(inGroup: group.id).map { $0.name }, ["2", "1"])
    }

    func testMoveHostOutOfGroupKeepsGivenOrder() {
        let store = makeStore()
        let group = store.addGroup(name: "生产")
        let one = HostConfig(name: "1", host: "10.0.0.1", username: "root", groupID: group.id)
        let two = HostConfig(name: "2", host: "10.0.0.2", username: "root", groupID: group.id)
        let three = HostConfig(name: "3", host: "10.0.0.3", username: "root", groupID: group.id)
        [one, two, three].forEach { store.save($0, password: "") }

        // 多选拖动：传进来的先后决定落地后的相对顺序。
        store.move(hostIDs: [three.id, one.id], toGroup: nil, before: nil)
        XCTAssertEqual(store.hosts(inGroup: group.id).map { $0.name }, ["2"])
        XCTAssertEqual(store.hosts(inGroup: nil).map { $0.name }, ["3", "1"])
    }

    func testMoveOntoItselfDoesNothing() {
        let store = makeStore()
        let one = HostConfig(name: "1", host: "10.0.0.1", username: "root")
        let two = HostConfig(name: "2", host: "10.0.0.2", username: "root")
        [one, two].forEach { store.save($0, password: "") }

        // 落点就在被拖的那几台里面：原地不动，尤其不能被顺手挪到末尾。
        store.move(hostIDs: [one.id, two.id], toGroup: nil, before: two.id)
        XCTAssertEqual(store.hosts.map { $0.name }, ["1", "2"])
    }

    func testMoveToUnknownGroupFallsBackToUngrouped() {
        let store = makeStore()
        let group = store.addGroup(name: "生产")
        let host = HostConfig(host: "10.0.0.1", username: "root", groupID: group.id)
        store.save(host, password: "")

        store.move(hostIDs: [host.id], toGroup: UUID(), before: nil)
        XCTAssertNil(store.hosts[0].groupID, "分组不存在就当未分组，别把主机丢进看不见的段里")
    }

    /// 在编辑框里换分组：排到新分组末尾，而不是留在原来的下标上。
    func testSaveWithNewGroupMovesHostToEnd() {
        let store = makeStore()
        let group = store.addGroup(name: "生产")
        var moving = HostConfig(name: "1", host: "10.0.0.1", username: "root", groupID: group.id)
        let other = HostConfig(name: "2", host: "10.0.0.2", username: "root", groupID: group.id)
        [moving, other].forEach { store.save($0, password: "") }

        moving.groupID = nil
        store.save(moving, password: "")
        XCTAssertEqual(store.hosts.map { $0.name }, ["2", "1"])
        XCTAssertEqual(store.hosts(inGroup: nil).map { $0.name }, ["1"])
    }

    func testSaveKeepsPositionWhenGroupUnchanged() {
        let store = makeStore()
        var first = HostConfig(name: "1", host: "10.0.0.1", username: "root")
        store.save(first, password: "")
        store.save(HostConfig(name: "2", host: "10.0.0.2", username: "root"), password: "")

        first.name = "1 改过"
        store.save(first, password: "")
        XCTAssertEqual(store.hosts.map { $0.name }, ["1 改过", "2"], "只改名字不该换位置")
    }

    func testRemoveGroupKeepsItsHosts() {
        let store = makeStore()
        let group = store.addGroup(name: "生产")
        let inGroup = HostConfig(name: "1", host: "10.0.0.1", username: "root", groupID: group.id)
        let loose = HostConfig(name: "2", host: "10.0.0.2", username: "root")
        store.save(inGroup, password: "s3cret")
        store.save(loose, password: "")

        store.removeGroup(id: group.id)
        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertEqual(store.hosts.map { $0.name }, ["2", "1"], "原分组里的主机挪到未分组末尾")
        XCTAssertNil(store.hosts[1].groupID)
        XCTAssertEqual(store.password(for: inGroup), "s3cret", "删分组不该动密码")
    }

    // MARK: - 「移到分组」的去处

    func testMoveDestinationsAreEmptyWithoutAnyGroup() {
        let store = makeStore()
        let host = HostConfig(host: "10.0.0.1", username: "root")
        store.save(host, password: "")
        XCTAssertTrue(
            store.moveDestinations(forHostIDs: [host.id]).isEmpty,
            "一个分组都没建就没有任何去处，菜单那边显示一条灰着的「未创建分组」"
        )
    }

    func testMoveDestinationsSkipTheGroupTheHostIsAlreadyIn() {
        let store = makeStore()
        let a = store.addGroup(name: "A")
        let b = store.addGroup(name: "B")
        let host = HostConfig(host: "10.0.0.1", username: "root", groupID: a.id)
        store.save(host, password: "")

        XCTAssertEqual(
            store.moveDestinations(forHostIDs: [host.id]),
            [.group(b), .ungrouped],
            "自己已经在 A 里，A 不该出现"
        )
    }

    func testMoveDestinationsSkipUngroupedForUngroupedHost() {
        let store = makeStore()
        let a = store.addGroup(name: "A")
        let host = HostConfig(host: "10.0.0.1", username: "root")
        store.save(host, password: "")

        XCTAssertEqual(store.moveDestinations(forHostIDs: [host.id]), [.group(a)])
    }

    func testMoveDestinationsForSeveralHostsInTheSameSection() {
        let store = makeStore()
        let a = store.addGroup(name: "A")
        let b = store.addGroup(name: "B")
        let one = HostConfig(host: "10.0.0.1", username: "root", groupID: a.id)
        let two = HostConfig(host: "10.0.0.2", username: "root", groupID: a.id)
        [one, two].forEach { store.save($0, password: "") }

        XCTAssertEqual(store.moveDestinations(forHostIDs: [one.id, two.id]), [.group(b), .ungrouped])
    }

    /// 选中的几台分散在不同段里：怎么归拢都说得通，所以全都列出来。
    func testMoveDestinationsForHostsAcrossSections() {
        let store = makeStore()
        let a = store.addGroup(name: "A")
        let b = store.addGroup(name: "B")
        let inA = HostConfig(host: "10.0.0.1", username: "root", groupID: a.id)
        let inB = HostConfig(host: "10.0.0.2", username: "root", groupID: b.id)
        let loose = HostConfig(host: "10.0.0.3", username: "root")
        [inA, inB, loose].forEach { store.save($0, password: "") }

        XCTAssertEqual(
            store.moveDestinations(forHostIDs: [inA.id, inB.id]),
            [.group(a), .group(b), .ungrouped]
        )
        XCTAssertEqual(
            store.moveDestinations(forHostIDs: [inA.id, loose.id]),
            [.group(a), .group(b), .ungrouped]
        )
    }

    func testMoveGroupReorders() {
        let store = makeStore()
        let a = store.addGroup(name: "A")
        let b = store.addGroup(name: "B")
        let c = store.addGroup(name: "C")

        store.moveGroup(id: c.id, before: a.id)
        XCTAssertEqual(store.groups.map { $0.name }, ["C", "A", "B"])

        store.moveGroup(id: c.id, before: nil)
        XCTAssertEqual(store.groups.map { $0.name }, ["A", "B", "C"])

        store.moveGroup(id: b.id, before: b.id)
        XCTAssertEqual(store.groups.map { $0.name }, ["A", "B", "C"], "插到自己前面是空操作")
    }

    func testGroupsRoundTrip() throws {
        let store = makeStore()
        let group = store.addGroup(name: "  生产  ")
        store.setGroup(id: group.id, collapsed: true)
        store.save(HostConfig(host: "10.0.0.1", username: "root", groupID: group.id), password: "")

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.groups.count, 1)
        XCTAssertEqual(reloaded.groups[0].name, "生产")
        XCTAssertTrue(reloaded.groups[0].isCollapsed)
        XCTAssertEqual(reloaded.hosts(inGroup: group.id).count, 1)
    }

    /// 旧版本（v1，没有 groups 字段）或手改过的文件：指向不存在分组的主机退回未分组，
    /// 否则它哪一段都进不去，等于从列表里消失。
    func testLoadDropsUnknownGroupReference() throws {
        let json = """
        {"version":1,"hosts":[{"host":"10.0.0.1","username":"root","groupID":"\(UUID().uuidString)"}]}
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("hosts.json"))

        let store = makeStore()
        XCTAssertEqual(store.hosts.count, 1)
        XCTAssertNil(store.hosts[0].groupID)
        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertEqual(store.sections.last?.hosts.count, 1)
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
