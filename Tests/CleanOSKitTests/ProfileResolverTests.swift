import XCTest
@testable import CleanOSKit

final class ProfileResolverTests: XCTestCase {

    func testExactMatchWins() {
        let a = Fixtures.display(uuid: "A", isMain: true)
        let b = Fixtures.display(uuid: "B", vendor: 2)
        let desk = Fixtures.snapshot(name: "desk", displays: [a, b])
        let laptop = Fixtures.snapshot(name: "laptop", displays: [a])

        let resolution = ProfileResolver.resolve(
            snapshots: [laptop, desk],
            current: DisplaySet(displays: [a, b])
        )

        XCTAssertEqual(resolution?.snapshot.name, "desk")
        XCTAssertEqual(resolution?.isExact, true)
        XCTAssertEqual(resolution?.matchedCount, 2)
    }

    /// The failure this whole type exists to avoid: undock the laptop and the
    /// desk recording should still place what it can rather than giving up.
    func testMissingMonitorFoldsOntoTheMainOne() {
        let a = Fixtures.display(uuid: "A", isMain: true)
        let b = Fixtures.display(uuid: "B", vendor: 2)
        let desk = Fixtures.snapshot(name: "desk", displays: [a, b])

        let resolution = ProfileResolver.resolve(
            snapshots: [desk],
            current: DisplaySet(displays: [a])
        )

        XCTAssertNotNil(resolution)
        XCTAssertEqual(resolution?.isExact, false)
        XCTAssertEqual(resolution?.matchedCount, 1)
        XCTAssertEqual(resolution?.currentUUID(for: "A"), "A")
        // Windows recorded on the absent monitor land on the one that is here.
        XCTAssertEqual(resolution?.currentUUID(for: "B"), "A")
    }

    /// Display UUIDs are reported to change across reboots on some machines,
    /// so the same physical monitor has to be recognised by its hardware.
    func testMonitorRecognisedAfterItsUUIDChanges() {
        let recorded = Fixtures.display(uuid: "OLD", vendor: 7, model: 9, serial: 42, isMain: true)
        let present = Fixtures.display(uuid: "NEW", vendor: 7, model: 9, serial: 42, isMain: true)
        let snapshot = Fixtures.snapshot(displays: [recorded])

        let resolution = ProfileResolver.resolve(
            snapshots: [snapshot],
            current: DisplaySet(displays: [present])
        )

        XCTAssertEqual(resolution?.currentUUID(for: "OLD"), "NEW")
        XCTAssertEqual(resolution?.matchedCount, 1)
        // Matched, but not by UUID, so not claimed as exact.
        XCTAssertEqual(resolution?.isExact, false)
    }

    /// A UUID match must not be stolen by an earlier hardware match.
    func testUUIDMatchesTakePrecedenceOverHardwareMatches() {
        let one = Fixtures.display(uuid: "ONE", vendor: 5, model: 5, serial: 0, isMain: true)
        let two = Fixtures.display(uuid: "TWO", vendor: 5, model: 5, serial: 0)
        let snapshot = Fixtures.snapshot(displays: [one, two])

        let resolution = ProfileResolver.resolve(
            snapshots: [snapshot],
            current: DisplaySet(displays: [one, two])
        )

        XCTAssertEqual(resolution?.currentUUID(for: "ONE"), "ONE")
        XCTAssertEqual(resolution?.currentUUID(for: "TWO"), "TWO")
        XCTAssertEqual(resolution?.isExact, true)
    }

    func testNoSharedMonitorMeansNoMatch() {
        let recorded = Fixtures.display(uuid: "A", vendor: 1, model: 1, serial: 1)
        let present = Fixtures.display(uuid: "Z", vendor: 9, model: 9, serial: 9, isMain: true)

        XCTAssertNil(ProfileResolver.resolve(
            snapshots: [Fixtures.snapshot(displays: [recorded])],
            current: DisplaySet(displays: [present])
        ))
    }

    func testMoreRecentRecordingWinsATie() {
        let a = Fixtures.display(uuid: "A", isMain: true)
        let older = Fixtures.snapshot(
            name: "older", displays: [a],
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let newer = Fixtures.snapshot(
            name: "newer", displays: [a],
            createdAt: Date(timeIntervalSince1970: 2)
        )

        let resolution = ProfileResolver.resolve(
            snapshots: [older, newer],
            current: DisplaySet(displays: [a])
        )
        XCTAssertEqual(resolution?.snapshot.name, "newer")
    }
}
