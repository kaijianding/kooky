import XCTest
@testable import KookyKit

@MainActor
final class ClosedWorkspacesTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kooky-closed-test-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func makeClosed() -> ClosedWorkspaces {
        ClosedWorkspaces(fileURL: fileURL)
    }

    private func makeWorkspace(
        at path: String,
        tag: WorkspaceTag? = nil,
        customTitle: String? = nil,
        isPinned: Bool = false,
        worktreeParent: UUID? = nil,
        sshRemoteHost: String? = nil
    ) -> Workspace {
        let ws = Workspace(workingDirectory: URL(fileURLWithPath: path, isDirectory: true), root: PaneNode(pane: Pane()))
        ws.tag = tag
        ws.customTitle = customTitle
        ws.isPinned = isPinned
        ws.worktreeParentId = worktreeParent
        ws.sshRemoteHost = sshRemoteHost
        return ws
    }

    func testIsRecordableRequiresNonDefaultSettings() {
        let closed = makeClosed()
        XCTAssertFalse(closed.isRecordable(makeWorkspace(at: "/tmp/plain")), "a default workspace leaves nothing to restore")
        XCTAssertTrue(closed.isRecordable(makeWorkspace(at: "/tmp/tagged", tag: .init(preset: .blue))))
        XCTAssertTrue(closed.isRecordable(makeWorkspace(at: "/tmp/named", customTitle: "My Project")))
        XCTAssertTrue(closed.isRecordable(makeWorkspace(at: "/tmp/pinned", isPinned: true)))
    }

    func testIsRecordableExcludesWorktreeAndSSH() {
        let closed = makeClosed()
        // Provenance filter mirrors RecentFolders.note: worktree dirs die with
        // the worktree, SSH cwd isn't where the project lives.
        XCTAssertFalse(closed.isRecordable(makeWorkspace(
            at: "/tmp/wt", tag: .init(preset: .red), worktreeParent: UUID()
        )))
        XCTAssertFalse(closed.isRecordable(makeWorkspace(
            at: "/tmp/remote", tag: .init(preset: .red), sshRemoteHost: "host"
        )))
    }

    func testRecordIgnoresDefaultWorkspace() {
        let closed = makeClosed()
        closed.record(makeWorkspace(at: "/tmp/plain"))
        XCTAssertTrue(closed.records.isEmpty, "no settings → no record")
    }

    func testPopRoundTripsSettingsThenConsumes() {
        let closed = makeClosed()
        let tag = WorkspaceTag(color: .custom(hex: "#ff8800"), name: "urgent")
        closed.record(makeWorkspace(at: "/tmp/proj", tag: tag, customTitle: "Starrocks", isPinned: true))

        guard let record = closed.pop(matching: "/tmp/proj") else {
            return XCTFail("record must be found by directory path")
        }
        XCTAssertEqual(record.directoryPath, "/tmp/proj")
        XCTAssertEqual(record.customTitle, "Starrocks")
        XCTAssertEqual(record.tagPreset, nil)
        XCTAssertEqual(record.tagCustomHex, "FF8800", "WorkspaceTag normalizes hex to uppercase")
        XCTAssertEqual(record.tagName, "urgent")
        XCTAssertEqual(record.isPinned, true)

        XCTAssertNil(closed.pop(matching: "/tmp/proj"), "restore is one-shot")
    }

    func testRecordIsLRUDedupByPath() {
        let closed = makeClosed()
        closed.record(makeWorkspace(at: "/tmp/a", tag: .init(preset: .red)))
        closed.record(makeWorkspace(at: "/tmp/b", tag: .init(preset: .blue)))
        closed.record(makeWorkspace(at: "/tmp/a", tag: .init(preset: .green)))

        XCTAssertEqual(closed.records.map(\.directoryPath), ["/tmp/a", "/tmp/b"], "re-record moves to the front")
        XCTAssertEqual(closed.records.first?.tagPreset, WorkspaceColorTag.green.rawValue, "latest settings win")
    }

    func testCapDropsOldest() {
        let closed = makeClosed()
        for i in 0..<(ClosedWorkspaces.cap + 5) {
            closed.record(makeWorkspace(at: "/tmp/project-\(i)", tag: .init(preset: .gray)))
        }
        XCTAssertEqual(closed.records.count, ClosedWorkspaces.cap)
        XCTAssertEqual(closed.records.first?.directoryPath, "/tmp/project-\(ClosedWorkspaces.cap + 4)")
        XCTAssertNil(closed.records.last { $0.directoryPath == "/tmp/project-0" })
    }

    func testPersistsAcrossInstances() {
        makeClosed().record(makeWorkspace(at: "/tmp/persisted", tag: .init(preset: .blue), customTitle: "Keep"))
        XCTAssertEqual(makeClosed().records.map(\.directoryPath), ["/tmp/persisted"])
    }
}
