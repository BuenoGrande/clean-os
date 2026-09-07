import CoreGraphics
import XCTest
@testable import CleanOSKit

/// What happens when you take the laptop off the desk. This is the case the
/// tool closest to this idea gets wrong, so it gets its own tests.
final class UndockingTests: XCTestCase {

    let laptop = Fixtures.display(
        uuid: "LAPTOP", name: "Built-in", vendor: 1, model: 1, serial: 1,
        isMain: true, origin: .zero, size: CGSize(width: 1512, height: 982)
    )
    let external = Fixtures.display(
        uuid: "STUDIO", name: "Studio Display", vendor: 2, model: 2, serial: 2,
        origin: CGPoint(x: 1512, y: 0), size: CGSize(width: 2560, height: 1440)
    )

    func testWindowsFromTheMissingMonitorLandOnTheLaptopKeepingTheirShape() {
        let onExternal = Placement(
            match: WindowMatch(bundleID: "slack"),
            target: PlacementTarget(displayUUID: "STUDIO", spaceIndex: nil, unitRect: .rightHalf)
        )
        let snapshot = Fixtures.snapshot(displays: [laptop, external], placements: [onExternal])
        let present = DisplaySet(displays: [laptop])

        let resolution = ProfileResolver.resolve(snapshots: [snapshot], current: present)!
        let window = Fixtures.window(
            id: 1, bundleID: "slack",
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayUUID: "LAPTOP", spaceIndex: 1
        )
        let plan = Planner.plan(
            resolution: resolution,
            assignments: WindowResolver.resolve(placements: [onExternal], windows: [window]),
            current: present
        )

        guard case .setFrame(_, _, let frame)? = plan.actions.first else {
            return XCTFail("expected the window to be placed on the laptop, got \(plan.actions)")
        }
        // Right half of the laptop, not of the monitor that is not there, and
        // in the laptop's own coordinates.
        XCTAssertEqual(frame, UnitRect.rightHalf.frame(in: laptop.visibleFrame))
        XCTAssertLessThanOrEqual(frame.maxX, external.frame.minX)
    }

    func testPluggingTheMonitorBackInRestoresTheDeskLayout() {
        let onExternal = Placement(
            match: WindowMatch(bundleID: "slack"),
            target: PlacementTarget(displayUUID: "STUDIO", spaceIndex: nil, unitRect: .rightHalf)
        )
        let snapshot = Fixtures.snapshot(displays: [laptop, external], placements: [onExternal])
        let present = DisplaySet(displays: [laptop, external])

        let resolution = ProfileResolver.resolve(snapshots: [snapshot], current: present)!
        XCTAssertTrue(resolution.isExact)

        let window = Fixtures.window(
            id: 1, bundleID: "slack",
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayUUID: "LAPTOP", spaceIndex: 1
        )
        let plan = Planner.plan(
            resolution: resolution,
            assignments: WindowResolver.resolve(placements: [onExternal], windows: [window]),
            current: present
        )

        guard case .setFrame(_, _, let frame)? = plan.actions.first else {
            return XCTFail("expected a placement, got \(plan.actions)")
        }
        XCTAssertEqual(frame, UnitRect.rightHalf.frame(in: external.visibleFrame))
        XCTAssertGreaterThanOrEqual(frame.minX, external.frame.minX)
    }
}
