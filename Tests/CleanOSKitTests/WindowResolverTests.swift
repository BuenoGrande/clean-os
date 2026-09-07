import CoreGraphics
import XCTest
@testable import CleanOSKit

final class WindowResolverTests: XCTestCase {

    func testOrdinalsFollowPositionOnScreenNotEnumerationOrder() {
        // Deliberately supplied in the wrong order, as the accessibility API
        // often does. The lower window must still be ordinal 1.
        let lower = Fixtures.window(id: 1, bundleID: "app", frame: CGRect(x: 0, y: 500, width: 100, height: 100))
        let upper = Fixtures.window(id: 2, bundleID: "app", frame: CGRect(x: 0, y: 0, width: 100, height: 100))

        let assignments = WindowResolver.resolve(
            placements: [
                Fixtures.placement(bundleID: "app", ordinal: 0),
                Fixtures.placement(bundleID: "app", ordinal: 1),
            ],
            windows: [lower, upper]
        )

        XCTAssertEqual(assignments[0].window?.windowID, 2)
        XCTAssertEqual(assignments[1].window?.windowID, 1)
    }

    func testAWindowIsNeverAssignedTwice() {
        let only = Fixtures.window(id: 1, bundleID: "app")
        let assignments = WindowResolver.resolve(
            placements: [
                Fixtures.placement(bundleID: "app", ordinal: 0),
                Fixtures.placement(bundleID: "app", ordinal: 1),
            ],
            windows: [only]
        )
        XCTAssertEqual(assignments[0].window?.windowID, 1)
        XCTAssertNil(assignments[1].window)
    }

    /// A placement that names a title must not have its window taken by a
    /// vaguer placement for the same app.
    func testTitleMatchesAreResolvedBeforeBareOnes() {
        let inbox = Fixtures.window(
            id: 1, bundleID: "browser", title: "Inbox",
            frame: CGRect(x: 0, y: 0, width: 10, height: 10)
        )
        let other = Fixtures.window(
            id: 2, bundleID: "browser", title: "Docs",
            frame: CGRect(x: 0, y: 100, width: 10, height: 10)
        )

        let assignments = WindowResolver.resolve(
            placements: [
                Fixtures.placement(bundleID: "browser", ordinal: 0),
                Fixtures.placement(bundleID: "browser", titleRegex: "^Inbox", ordinal: 0),
            ],
            windows: [inbox, other]
        )

        XCTAssertEqual(assignments[1].window?.windowID, 1, "the titled placement takes Inbox")
        XCTAssertEqual(assignments[0].window?.windowID, 2, "the bare placement takes what is left")
    }

    func testMinimizedWindowsAreNotPlaced() {
        let hidden = Fixtures.window(id: 1, bundleID: "app", minimized: true)
        let assignments = WindowResolver.resolve(
            placements: [Fixtures.placement(bundleID: "app")],
            windows: [hidden]
        )
        XCTAssertNil(assignments[0].window)
    }

    /// Closing one of three windows should not strand the other two.
    func testAMissingOrdinalFallsBackRatherThanGivingUp() {
        let single = Fixtures.window(id: 9, bundleID: "app")
        let assignments = WindowResolver.resolve(
            placements: [Fixtures.placement(bundleID: "app", ordinal: 2)],
            windows: [single]
        )
        XCTAssertEqual(assignments[0].window?.windowID, 9)
    }

    func testAnInvalidTitlePatternMatchesNothingRatherThanCrashing() {
        let window = Fixtures.window(id: 1, bundleID: "app", title: "anything")
        let assignments = WindowResolver.resolve(
            placements: [Fixtures.placement(bundleID: "app", titleRegex: "[unclosed")],
            windows: [window]
        )
        // The pattern cannot compile, so it is ignored and the bundle match
        // stands. What matters is that nothing throws and the window is still
        // placed rather than silently dropped.
        XCTAssertEqual(assignments[0].window?.windowID, 1)
    }
}
