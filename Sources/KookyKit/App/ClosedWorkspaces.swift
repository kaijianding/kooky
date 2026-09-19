import Foundation

/// Records the identity settings of plain local workspaces the user closes
/// while they carry non-default settings (a tag/colour, a custom name, a
/// pin). When the same folder is reopened via Open Recent / ⌘P / the top-strip
/// folder button, those settings are restored onto the fresh workspace — so
/// closing and reopening a project doesn't silently lose its colour and name.
///
/// Separate JSON file from `state.json` for the same reason `RecentFolders`
/// is: this list outlives the window that held the workspace and is keyed by
/// directory path across all windows, not one window's store.
@MainActor
final class ClosedWorkspaces {
    static let shared = ClosedWorkspaces()

    static let cap = 20

    struct Record: Codable, Equatable {
        /// Standardized directory path — the join key with a recent folder.
        var directoryPath: String
        var customTitle: String?
        /// Tag, stored flat like `PersistedWorkspace`: exactly one of
        /// `tagPreset`/`tagCustomHex`, plus an optional name.
        var tagPreset: String?
        var tagCustomHex: String?
        var tagName: String?
        var isPinned: Bool?
    }

    /// Most recent first, deduped by `directoryPath` at insert.
    private(set) var records: [Record] = []

    private let fileURL: URL

    static var defaultFileURL: URL {
        KookyShellIntegration.kookyAppSupport("closed-workspaces.json", isDirectory: false)
    }

    /// `fileURL` injectable so tests write a scratch file instead of the
    /// user's real App Support list (same seam shape as `RecentFolders`).
    init(fileURL: URL = ClosedWorkspaces.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    /// Whether a workspace's settings are worth remembering. Only plain local
    /// workspaces qualify — a worktree's dir dies with the worktree and is
    /// never a recent folder; an SSH workspace's local cwd isn't the project
    /// (the same provenance filter `RecentFolders.note` applies). And only
    /// when at least one setting is non-default: closing a default workspace
    /// leaves nothing to restore.
    func isRecordable(_ workspace: Workspace) -> Bool {
        guard workspace.worktreeParentId == nil, workspace.sshRemoteHost == nil else { return false }
        let hasCustomTitle = workspace.customTitle.flatMap { $0.isEmpty ? nil : $0 } != nil
        return hasCustomTitle || workspace.tag != nil || workspace.isPinned
    }

    /// LRU insert keyed by directory path: a re-record moves the entry to the
    /// front (the user just closed + reopened it). No-op for workspaces that
    /// carry nothing worth restoring (`isRecordable`).
    func record(_ workspace: Workspace) {
        guard isRecordable(workspace) else { return }
        let record = Record(
            directoryPath: workspace.workingDirectory.standardizedFileURL.path,
            customTitle: workspace.customTitle.flatMap { $0.isEmpty ? nil : $0 },
            tagPreset: workspace.tag?.color.preset?.rawValue,
            tagCustomHex: workspace.tag?.color.customHex,
            tagName: workspace.tag?.name,
            isPinned: workspace.isPinned ? true : nil
        )
        records.removeAll { $0.directoryPath == record.directoryPath }
        records.insert(record, at: 0)
        if records.count > Self.cap { records.removeLast(records.count - Self.cap) }
        save()
    }

    /// Consume (one-shot restore) and return the record for `directoryPath`,
    /// if any. Removing it means a folder restores once per close cycle —
    /// closing it again with settings re-records.
    func pop(matching directoryPath: String) -> Record? {
        guard let idx = records.firstIndex(where: { $0.directoryPath == directoryPath }) else { return nil }
        let record = records.remove(at: idx)
        save()
        return record
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Record].self, from: data) else { return }
        records = Array(decoded.prefix(Self.cap))
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
