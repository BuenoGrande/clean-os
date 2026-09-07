import CoreGraphics
import XCTest
@testable import CleanOSKit

final class GeometryTests: XCTestCase {

    let area = CGRect(x: 0, y: 25, width: 1920, height: 1055)

    func testRoundTripPreservesFrame() {
        let frame = CGRect(x: 100, y: 125, width: 960, height: 500)
        let unit = UnitRect(frame: frame, in: area)
        XCTAssertEqual(unit.frame(in: area), frame)
    }

    func testLeftHalfIsHalfTheArea() {
        let frame = UnitRect.leftHalf.frame(in: area)
        XCTAssertEqual(frame.origin.x, 0)
        XCTAssertEqual(frame.origin.y, 25)
        XCTAssertEqual(frame.width, 960)
        XCTAssertEqual(frame.height, 1055)
    }

    /// The reason fractions are stored rather than pixels: the same recording
    /// has to mean the same thing on a different sized monitor.
    func testFractionsSurviveADifferentResolution() {
        let recorded = UnitRect(
            frame: CGRect(x: 0, y: 25, width: 960, height: 1055),
            in: area
        )
        let smaller = CGRect(x: 0, y: 25, width: 1280, height: 775)
        let frame = recorded.frame(in: smaller)
        XCTAssertEqual(frame.width, 640)
        XCTAssertEqual(frame.height, 775)
    }

    func testFramesOnASecondMonitorKeepThatMonitorsOrigin() {
        let second = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        let frame = UnitRect.rightHalf.frame(in: second)
        XCTAssertEqual(frame.origin.x, 1920 + 1280)
        XCTAssertEqual(frame.width, 1280)
    }

    func testOffScreenWindowsAreNotClamped() {
        // A window dragged half off the left edge records a negative fraction,
        // because recording must be lossless even when the layout is silly.
        let frame = CGRect(x: -100, y: 25, width: 400, height: 300)
        let unit = UnitRect(frame: frame, in: area)
        XCTAssertLessThan(unit.x, 0)
        XCTAssertEqual(unit.frame(in: area), frame)
    }

    func testNearlyToleratesSmallDrift() {
        let a = UnitRect(x: 0, y: 0, w: 0.5, h: 1)
        let b = UnitRect(x: 0.002, y: 0, w: 0.5, h: 1)
        XCTAssertTrue(a.isNearly(b))
        XCTAssertFalse(a.isNearly(UnitRect(x: 0.2, y: 0, w: 0.5, h: 1)))
    }

    func testZeroSizedAreaDoesNotDivideByZero() {
        let unit = UnitRect(frame: CGRect(x: 0, y: 0, width: 10, height: 10), in: .zero)
        XCTAssertEqual(unit, UnitRect.full)
    }
}
