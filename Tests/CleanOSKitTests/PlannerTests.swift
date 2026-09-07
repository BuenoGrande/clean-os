import CoreGraphics
import XCTest
@testable import CleanOSKit

final class PlannerTests: XCTestCase {

    let monitor = Fixtures.display(uuid: "A", isMain: true)

    var displays: DisplaySet { DisplaySet(displays: [monitor]) }

    func resolution(_ snapshot: Snapshot) -> ProfileResolver.Resolution {
        ProfileResolver.resolve(snapshots: [snapshot], current: displays)!
    }

    /// Restoring twice in a row should be silent, not shuffle everything again.
    func testWindowsAlreadyInPlaceProduceNoActions() {
        let target = UnitRect.leftHalf
        let placement = Fixtures.placement(bundleID: "app", rect: target)
        let window = Fixtures.window(
            id: 1,
            bundleID: "app",
            frame: target.frame(in: monitor.visibleFrame),
            displayUUID: "A",
            spaceIndex: 1
        )

        let plan = Planner.plan(
            resolution: resolution(Fixtures.snapshot(displays: [monitor], placements: [placement])),
            assignments: WindowResolver.resolve(placements: [placement], windows: [window]),
            current: displays
        )

        XCTAssertTrue(plan.actions.isEmpty)
    }

    func testAWindowInTheWrongPlaceIsResized() {
        let placement = Fixtures.placement(bundleID: "app", rect: .rightHalf)
        let window = Fixtures.window(
            id: 1,
            bundleID: "app",
            frame: UnitRect.leftHalf.frame(in: monitor.visibleFrame),
            spaceIndex: 1
        )

        let plan = Planner.plan(
            resolution: resolution(Fixtures.snapshot(displays: [monitor], placements: [placement])),
            assignments: WindowResolver.resolve(placements: [placement], windows: [window]),
            current: displays
        )

        guard case .setFrame(_, let bundleID, let frame)? = plan.actions.first else {
            return XCTFail("expected a resize, got \(plan.actions)")
        }
        XCTAssertEqual(bundleID, "app")
        XCTAssertEqual(frame, UnitRect.rightHalf.frame(in: monitor.visibleFrame))
    }

    func testAMissingAppIsLaunchedWhenAllowed() {
        let placement = Fixtures.placement(bundleID: "app", launchIfMissing: true)
        let plan = Planner.plan(
            resolution: resolution(Fixtures.snapshot(displays: [monitor], placements: [placement])),
            assignments: WindowResolver.resolve(placements: [placement], windows: []),
            current: displays
        )
        XCTAssertEqual(plan.actions, [.launch(bundleID: "app")])
        XCTAssertTrue(plan.unmatched.isEmpty)
    }

    func testAMissingAppIsReportedWhenLaunchingIsNotAllowed() {
        let placement = Fixtures.placement(bundleID: "app", launchIfMissing: false)
        let plan = Planner.plan(
            resolution: resolution(Fixtures.snapshot(displays: [monitor], placements: [placement])),
            assignments: WindowResolver.resolve(placements: [placement], windows: []),
            current: displays
        )
        XCTAssertTrue(plan.actions.isEmpty)
        XCTAssertEqual(plan.unmatched.count, 1)
    }

    /// Each desktop switch costs an animation, so windows coming from the same
    /// desktop must be handled together rather than switching back and forth.
    func testDesktopMovesAreGroupedByWhereTheWindowIsNow() {
        let placements = [
            Fixtures.placement(bundleID: "one", spaceIndex: 2),
            Fixtures.placement(bundleID: "two", spaceIndex: 2),
        ]
        let windows = [
            Fixtures.window(id: 1, bundleID: "one", spaceIndex: 1),
            Fixtures.window(id: 2, bundleID: "two", spaceIndex: 1),
        ]

        let plan = Planner.plan(
            resolution: resolution(Fixtures.snapshot(displays: [monitor], placements: placements)),
            assignments: WindowResolver.resolve(placements: placements, windows: windows),
            current: displays
        )

        let switches = plan.actions.filter {
            if case .switchToSpace = $0 { return true }
            return false
        }
        XCTAssertEqual(switches.count, 1, "one switch for both windows, not two")

        // And the switch must come before the moves that depend on it.
        let firstMove = plan.actions.firstIndex {
            if case .moveWindowToSpace = $0 { return true }
            return false
        }
        let firstSwitch = plan.actions.firstIndex {
            if case .switchToSpace = $0 { return true }
            return false
        }
        XCTAssertNotNil(firstMove)
        XCTAssertNotNil(firstSwitch)
        XCTAssertLessThan(firstSwitch!, firstMove!)
    }

    /// Sizing has to happen after the desktop move, because moving a window
    /// between desktops can shift it.
    func testResizingComesAfterMoving() {
        let placement = Fixtures.placement(bundleID: "app", spaceIndex: 2, rect: .rightHalf)
        let window = Fixtures.window(
            id: 1,
            bundleID: "app",
            frame: UnitRect.leftHalf.frame(in: monitor.visibleFrame),
            spaceIndex: 1
        )

        let plan = Planner.plan(
            resolution: resolution(Fixtures.snapshot(displays: [monitor], placements: [placement])),
            assignments: WindowResolver.resolve(placements: [placement], windows: [window]),
            current: displays
        )

        let move = plan.actions.firstIndex { if case .moveWindowToSpace = $0 { return true }; return false }
        let frame = plan.actions.firstIndex { if case .setFrame = $0 { return true }; return false }
        XCTAssertNotNil(move)
        XCTAssertNotNil(frame)
        XCTAssertLessThan(move!, frame!)
    }

    /// Better to leave a window alone than to move it somewhere wrong.
    func testAWindowWhoseDesktopCannotBeReadIsNotMoved() {
        let placement = Fixtures.placement(bundleID: "app", spaceIndex: 2, rect: .leftHalf)
        let window = Fixtures.window(
            id: 1,
            bundleID: "app",
            frame: UnitRect.leftHalf.frame(in: monitor.visibleFrame),
            spaceIndex: nil
        )

        let plan = Planner.plan(
            resolution: resolution(Fixtures.snapshot(displays: [monitor], placements: [placement])),
            assignments: WindowResolver.resolve(placements: [placement], windows: [window]),
            current: displays
        )

        XCTAssertFalse(plan.actions.contains { if case .moveWindowToSpace = $0 { return true }; return false })
    }

    /// A recording with no desktop information still places windows.
    func testRecordingsWithoutDesktopsStillResize() {
        let placement = Fixtures.placement(bundleID: "app", spaceIndex: nil, rect: .rightHalf)
        let window = Fixtures.window(
            id: 1,
            bundleID: "app",
            frame: UnitRect.leftHalf.frame(in: monitor.visibleFrame),
            spaceIndex: 1
        )

        let plan = Planner.plan(
            resolution: resolution(Fixtures.snapshot(displays: [monitor], placements: [placement])),
            assignments: WindowResolver.resolve(placements: [placement], windows: [window]),
            current: displays
        )

        XCTAssertEqual(plan.actions.count, 1)
        XCTAssertTrue(plan.actions.contains { if case .setFrame = $0 { return true }; return false })
    }
}
