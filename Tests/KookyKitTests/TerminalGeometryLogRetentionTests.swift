import XCTest
@testable import KookyKit

final class TerminalGeometryLogRetentionTests: XCTestCase {
    /// A manual capture taken on demand must outlive any number of automatic
    /// dumps — the recorder used to prune `grid-manual-…` first because it
    /// sorted names before sequences, so a capture was gone within minutes.
    func testManualCapturesSurviveAutomaticFlood() {
        var names = ["grid-manual-ttys002-00000001.json"]
        names += (2...200).map { String(format: "grid-push-fast-ttys009-%08d.json", $0) }

        let doomed = TerminalGeometryLog.dumpsToPrune(names, maxFiles: 60, maxPerSurface: 40)

        XCTAssertFalse(doomed.contains("grid-manual-ttys002-00000001.json"))
        XCTAssertEqual(names.count - doomed.count, 41)
    }

    /// One chatty surface must not delete another surface's history.
    func testPerSurfaceCapKeepsQuietSurfaceHistory() {
        var names = (1...50).map { String(format: "grid-push-slow-ttys009-%08d.json", $0) }
        names += (1...3).map { String(format: "grid-push-slow-ttys002-%08d.json", $0) }

        let doomed = TerminalGeometryLog.dumpsToPrune(names, maxFiles: 60, maxPerSurface: 40)

        XCTAssertEqual(doomed.count, 10)
        XCTAssertTrue(doomed.allSatisfy { $0.contains("ttys009") })
        // Oldest of the chatty surface go, newest stay.
        XCTAssertTrue(doomed.contains("grid-push-slow-ttys009-00000001.json"))
        XCTAssertFalse(doomed.contains("grid-push-slow-ttys009-00000050.json"))
    }

    /// The global budget is enforced even when every surface is under its own
    /// cap, and it never empties a surface completely.
    func testGlobalBudgetDropsFromBusiestSurface() {
        var names: [String] = []
        for tty in ["ttys001", "ttys002", "ttys003"] {
            names += (1...30).map { String(format: "grid-push-fast-%@-%08d.json", tty, $0) }
        }

        let doomed = TerminalGeometryLog.dumpsToPrune(names, maxFiles: 60, maxPerSurface: 40)

        XCTAssertEqual(names.count - doomed.count, 60)
        for tty in ["ttys001", "ttys002", "ttys003"] {
            XCTAssertFalse(doomed.contains(String(format: "grid-push-fast-%@-%08d.json", tty, 30)))
        }
    }

    /// Under budget nothing is pruned; non-grid files are never touched.
    func testNothingPrunedBelowBudget() {
        let names = [
            "grid-push-fast-ttys002-00000001.json",
            "grid-manual-ttys002-00000002.json",
            "geometry.log",
        ]

        XCTAssertTrue(TerminalGeometryLog.dumpsToPrune(names, maxFiles: 60, maxPerSurface: 40).isEmpty)
    }
}
