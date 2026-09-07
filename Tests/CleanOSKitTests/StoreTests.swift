import CoreGraphics
import XCTest
@testable import CleanOSKit

final class StoreTests: XCTestCase {

    var directory: URL!
    var store: SnapshotStore!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clean-os-tests-\(UUID().uuidString)", isDirectory: true)
        store = SnapshotStore(root: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testARecordingSurvivesARoundTrip() throws {
        let monitor = Fixtures.display(uuid: "A", isMain: true)
        let original = Fixtures.snapshot(
            name: "desk",
            displays: [monitor],
            placements: [
                Fixtures.placement(bundleID: "net.whatsapp.WhatsApp", rect: .leftHalf),
                Fixtures.placement(bundleID: "com.tinyspeck.slackmacgap", rect: .rightHalf),
            ]
        )

        try store.save(original)
        let loaded = try store.loadAll()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first, original)
    }

    func testRecordingTheSameMonitorsTwiceReplacesRatherThanAccumulates() throws {
        let monitor = Fixtures.display(uuid: "A", isMain: true)
        try store.save(Fixtures.snapshot(name: "first", displays: [monitor]))
        try store.save(Fixtures.snapshot(name: "second", displays: [monitor]))

        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "second")
    }

    func testDifferentMonitorSetsAreKeptSeparately() throws {
        let a = Fixtures.display(uuid: "A", isMain: true)
        let b = Fixtures.display(uuid: "B", vendor: 2)
        try store.save(Fixtures.snapshot(name: "laptop", displays: [a]))
        try store.save(Fixtures.snapshot(name: "desk", displays: [a, b]))

        XCTAssertEqual(try store.loadAll().count, 2)
    }

    /// The key must not depend on the order macOS lists monitors in.
    func testProfileKeyIsIndependentOfMonitorOrder() {
        let a = Fixtures.display(uuid: "A")
        let b = Fixtures.display(uuid: "B")
        XCTAssertEqual(
            DisplaySet(displays: [a, b]).key,
            DisplaySet(displays: [b, a]).key
        )
    }

    func testLoadingFromAnEmptyDirectoryIsNotAnError() throws {
        XCTAssertEqual(try store.loadAll(), [])
    }

    func testCorruptFilesAreSkippedRatherThanFailingEverything() throws {
        let monitor = Fixtures.display(uuid: "A", isMain: true)
        try store.save(Fixtures.snapshot(displays: [monitor]))
        try FileManager.default.createDirectory(at: store.snapshotsDirectory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(
            to: store.snapshotsDirectory.appendingPathComponent("broken.json")
        )

        XCTAssertEqual(try store.loadAll().count, 1)
    }

    func testUndoIsStoredPerMonitorSet() throws {
        let monitor = Fixtures.display(uuid: "A", isMain: true)
        let before = Fixtures.snapshot(name: "before restore", displays: [monitor])
        try store.saveUndo(before)

        XCTAssertEqual(try store.loadUndo(profileKey: before.profileKey), before)
        XCTAssertNil(try store.loadUndo(profileKey: "nothing-here"))
        // The undo slot must not show up as a recording.
        XCTAssertEqual(try store.loadAll(), [])
    }

    func testTheLogAppendsRatherThanOverwrites() throws {
        store.appendLog(["event": "one"])
        store.appendLog(["event": "two"])

        let contents = try String(contentsOf: store.logURL, encoding: .utf8)
        let lines = contents.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(contents.contains("\"event\":\"one\""))
        XCTAssertTrue(contents.contains("\"event\":\"two\""))
    }
}
