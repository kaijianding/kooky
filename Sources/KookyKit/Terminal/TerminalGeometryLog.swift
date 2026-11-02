import Foundation

/// Append-only flight recorder for the terminal size chain — and for whatever
/// the terminal grid actually holds when that chain misfires.
///
/// One class of bug motivated this: an app (omp & co) repaints its whole
/// scrollback after a resize, and the finished screen shows a torn table — a
/// frame written for one grid width glued onto a frame written for another.
/// Every input that can produce that is invisible today: which `setFrameSize`
/// landed, whether the push was suppressed, what pixel size libghostty was told,
/// what grid it derived from it, and whether the PTY ever saw the missing rows.
/// This logger records all of it, plus a dump of the grid itself, so the next
/// bad frame can be attributed to the app, to the size chain, or to the VT.
///
/// Output lands in `~/Library/Logs/kooky/geometry/`:
///  - `geometry.log` — one line per event: `<seq> <iso> up=<ms> th=<thread> <event> k=v …`
///  - `grid-<seq>-<tag>.json` — libghostty's render-grid export (content truth)
///  - `pty-<tty>.bin` — raw PTY bytes, `bytes` mode only
///
/// `KOOKY_GEOMETRY_LOG` selects the mode: `0`/`off` disables everything,
/// `1`/`on` (default) keeps the text log and the grid dumps, `bytes` adds the
/// raw PTY stream.
public final class TerminalGeometryLog: @unchecked Sendable {
    public static let shared = TerminalGeometryLog()

    public enum Mode: String, Sendable {
        case off
        case log
        case bytes
    }

    public let mode: Mode
    public var isEnabled: Bool { mode != .off }
    public var recordsPTYBytes: Bool { mode == .bytes }

    /// Per-file ceilings — a long-running tab must never fill the disk.
    private static let maxLogBytes = 8 << 20
    private static let maxDumpFiles = 240
    private static let maxDumpsPerSurface = 40
    private static let maxPTYBytes = 64 << 20

    private let queue = DispatchQueue(label: "com.iamcorey.kooky.geometry-log", qos: .utility)
    private let directory: URL
    private let logURL: URL
    private let started = Date()
    private var sequence = 0
    /// Bytes currently in `geometry.log`, seeded from the file on open so a
    /// restart doesn't reset the budget.
    private var logBytes = 0
    private var logHandle: FileHandle?
    private var ptyHandles: [String: (handle: FileHandle, bytes: Int)] = [:]

    private init() {
        mode = Self.resolveMode()
        directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/kooky/geometry", isDirectory: true)
        logURL = directory.appendingPathComponent("geometry.log")
        guard mode != .off else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        rotateIfNeeded(logURL, limit: Self.maxLogBytes, backup: directory.appendingPathComponent("geometry.1.log"))
        logHandle = Self.openAppend(logURL)
        if let size = try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int {
            logBytes = size
        }
    }

    private static func resolveMode() -> Mode {
        guard let raw = ProcessInfo.processInfo.environment["KOOKY_GEOMETRY_LOG"]?
            .trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return .log }
        switch raw {
        case "0", "off", "false", "no": return .off
        case "bytes", "pty", "all": return .bytes
        default: return .log
        }
    }

    /// Directories worth handing to a bug report.
    public var captureDirectory: URL { directory }

    // MARK: - Events

    /// Records one event. Fields are pre-formatted `key=value` pairs — callers
    /// know their own shapes (frames, pixel sizes, grid counters) and string
    /// interpolation keeps the logger free of formatting policy.
    public func event(_ name: String, _ fields: [(String, String)]) {
        guard isEnabled else { return }
        // Read the thread here: by the time the block runs on the logger queue
        // every thread would look like "bg".
        let thread = Thread.isMainThread ? "main" : "bg"
        queue.async { self.write(self.render(name, fields, thread: thread)) }
    }

    /// Drops a free-form note; used for the launch header and for anything a
    /// human has to read back later (paths, flags, which mode is live).
    public func note(_ text: String) {
        guard isEnabled else { return }
        queue.async { self.write("# " + text) }
    }

    /// Writes one blob next to the log and returns its path (nil when disabled
    /// or unwritable). Grid dumps go through here.
    @discardableResult
    public func blob(tag: String, ext: String, data: Data) -> String? {
        guard isEnabled else { return nil }
        var path: String?
        let thread = Thread.isMainThread ? "main" : "bg"
        queue.sync {
            // The file name carries the sequence number of the line that will
            // record it, so a dump is always findable from its log line.
            // Zero-padded so a lexicographic prune is a chronological prune.
            let name = "\(Self.pathSafe(tag))-\(String(format: "%08d", sequence + 1)).\(Self.pathSafe(ext))"
            let url = directory.appendingPathComponent(name)
            guard (try? data.write(to: url, options: .atomic)) != nil else {
                write(render("blob-failed", [("name", name), ("bytes", "\(data.count)")], thread: thread))
                return
            }
            path = url.path
            write(render("blob", [("name", name), ("bytes", "\(data.count)")], thread: thread))
            pruneDumps()
        }
        return path
    }

    /// Appends raw PTY bytes for one stream, stopping once the ceiling is hit
    /// so a chatty session can't grow without bound. Called from the PTY read
    /// thread; everything crosses to the logger queue as a copied `Data`.
    public func appendPTYBytes(_ data: Data, stream: String) {
        guard recordsPTYBytes, !data.isEmpty else { return }
        queue.async {
            if let entry = self.ptyHandles[stream] {
                guard entry.bytes + data.count <= Self.maxPTYBytes else { return }
                try? entry.handle.write(contentsOf: data)
                self.ptyHandles[stream] = (entry.handle, entry.bytes + data.count)
                return
            }
            let base = self.directory.appendingPathComponent("pty-\(Self.pathSafe(stream))")
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let url = base.appendingPathComponent("stream.bin")
            self.rotateIfNeeded(url, limit: Self.maxPTYBytes, backup: base.appendingPathComponent("stream.1.bin"))
            guard let handle = Self.openAppend(url) else { return }
            try? handle.write(contentsOf: data)
            self.ptyHandles[stream] = (handle, data.count)
            self.write(self.render("pty-stream", [("path", "\(base.lastPathComponent)/stream.bin")], thread: "pty"))
        }
    }

    // MARK: - Formatting

    private func render(_ name: String, _ fields: [(String, String)], thread: String) -> String {
        sequence += 1
        let now = Date()
        let elapsed = now.timeIntervalSince(started) * 1000
        let uptime = ProcessInfo.processInfo.systemUptime * 1000
        var line = String(
            format: "%06d %@ up=%.0fms sys=%.0fms th=%@ %@",
            sequence,
            stamp.string(from: now),
            elapsed,
            uptime,
            thread,
            name
        )
        for (key, value) in fields {
            line += " " + key + "=" + (value.contains(" ") ? "\"\(value)\"" : value)
        }
        return line
    }

    private func write(_ line: String) {
        guard let handle = logHandle, let data = (line + "\n").data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
        logBytes += data.count
        guard logBytes > Self.maxLogBytes else { return }
        rotateLog()
    }

    /// The startup rotation only ever runs once, so a recorder left on for days
    /// grew `geometry.log` past 17 MB against an 8 MB ceiling. Rotation now
    /// happens from the writer itself, which is the only place that knows how
    /// much has actually accumulated.
    private func rotateLog() {
        try? logHandle?.close()
        logHandle = nil
        let backup = directory.appendingPathComponent("geometry.1.log")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: logURL, to: backup)
        logHandle = Self.openAppend(logURL)
        logBytes = 0
        if let handle = logHandle, let data = "# rotated\n".data(using: .utf8) {
            try? handle.write(contentsOf: data)
            logBytes = data.count
        }
    }

    // MARK: - Files

    private static func openAppend(_ url: URL) -> FileHandle? {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }

    private func rotateIfNeeded(_ url: URL, limit: Int, backup: URL) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? Int) ?? 0
        guard size > limit else { return }
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
    }

    /// Keeps every dump newer than `maxDumpsPerSurface` per surface and the
    /// newest `maxDumpFiles` overall; manual captures are never pruned.
    ///
    /// The previous FIFO sorted all `grid-*` names and dropped the lowest 60,
    /// which pruned by *tag* first (names sort `grid-manual-…` before
    /// `grid-push-…`) and by surface second, so one chatty tab's automatic
    /// dumps silently deleted every manual capture and every other tab's
    /// history within minutes — a capture taken on demand was gone before the
    /// log line that recorded it was read.
    private func pruneDumps() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in Self.dumpsToPrune(names) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Which of `names` must go: every dump newer than `maxPerSurface` per
    /// surface, then the busiest surface's oldest until `maxFiles` fits. Manual
    /// captures are never pruned.
    ///
    /// The previous FIFO sorted all `grid-*` names and dropped the lowest 60,
    /// which pruned by *tag* first (names sort `grid-manual-…` before
    /// `grid-push-…`) and by surface second, so one chatty tab's automatic
    /// dumps silently deleted every manual capture and every other tab's
    /// history within minutes — a capture taken on demand was gone before the
    /// log line that recorded it was read.
    static func dumpsToPrune(
        _ names: [String],
        maxFiles: Int = maxDumpFiles,
        maxPerSurface: Int = maxDumpsPerSurface
    ) -> [String] {
        var manual = 0
        var perSurface: [String: [(seq: Int, name: String)]] = [:]
        for name in names where name.hasPrefix("grid-") && name.hasSuffix(".json") {
            guard let seq = dumpSequence(name) else { continue }
            if name.hasPrefix(manualTagPrefix) {
                manual += 1
            } else {
                perSurface[dumpSurface(name), default: []].append((seq, name))
            }
        }

        var doomed: [String] = []
        // Newest first, so the tail of each bucket is what gets dropped.
        var buckets: [[(seq: Int, name: String)]] = perSurface.values.map { $0.sorted { $0.seq > $1.seq } }
        buckets = buckets.map { bucket in
            guard bucket.count > maxPerSurface else { return bucket }
            doomed += bucket[maxPerSurface...].map(\.name)
            return Array(bucket.prefix(maxPerSurface))
        }

        // Per-surface caps can still overshoot the global budget; then the
        // busiest surface gives up its oldest, never its last dump.
        var total = manual + buckets.reduce(0) { $0 + $1.count }
        while total > maxFiles,
              let busiest = buckets.indices.max(by: { buckets[$0].count < buckets[$1].count }),
              buckets[busiest].count > 1 {
            doomed.append(buckets[busiest].removeLast().name)
            total -= 1
        }
        return doomed
    }

    private static let manualTagPrefix = "grid-manual-"

    /// `grid-<label>-<tty>-<8-digit seq>.json` → the sequence number, which is
    /// the only part that orders the files chronologically.
    private static func dumpSequence(_ name: String) -> Int? {
        let stem = name.dropLast(5)
        guard let dash = stem.lastIndex(of: "-") else { return nil }
        return Int(stem[stem.index(after: dash)...])
    }

    /// The `tty` segment the dump belongs to: the last dash-delimited field
    /// before the sequence number. Labels carry dashes, so it can't be second.
    private static func dumpSurface(_ name: String) -> String {
        let stem = name.dropLast(5)
        guard let seqDash = stem.lastIndex(of: "-") else { return String(stem) }
        let head = stem[..<seqDash]
        guard let ttyDash = head.lastIndex(of: "-") else { return String(head) }
        return String(head[head.index(after: ttyDash)...])
    }

    /// Instance-owned and only touched on `queue`, which is what keeps a
    /// non-`Sendable` formatter out of the global-state checker's teeth.
    private let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    private static func pathSafe(_ raw: String) -> String {
        raw.replacingOccurrences(of: "/dev/", with: "")
            .replacingOccurrences(of: "/", with: "-")
    }
}
