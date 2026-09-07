import CoreGraphics
import Foundation

/// A window frame stored as fractions of its display's usable area.
///
/// Fractions rather than pixels so a recorded layout survives a resolution
/// change, a scaling change, or a change in menu bar / Dock height. Origin is
/// top-left, matching the coordinate space the Accessibility API uses.
public struct UnitRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    /// Left half, right half and so on, for readable defaults and tests.
    public static let full = UnitRect(x: 0, y: 0, w: 1, h: 1)
    public static let leftHalf = UnitRect(x: 0, y: 0, w: 0.5, h: 1)
    public static let rightHalf = UnitRect(x: 0.5, y: 0, w: 0.5, h: 1)

    /// Convert a pixel frame into fractions of `area`.
    ///
    /// Both rects must be in the same top-left-origin global space. A window
    /// that hangs off the edge of its display yields fractions outside 0...1,
    /// which is preserved rather than clamped so that recording is lossless.
    public init(frame: CGRect, in area: CGRect) {
        guard area.width > 0, area.height > 0 else {
            self.init(x: 0, y: 0, w: 1, h: 1)
            return
        }
        self.init(
            x: Double((frame.minX - area.minX) / area.width),
            y: Double((frame.minY - area.minY) / area.height),
            w: Double(frame.width / area.width),
            h: Double(frame.height / area.height)
        )
    }

    /// Convert back to a pixel frame within `area`.
    ///
    /// The result is rounded to whole points, because fractional window
    /// origins make windows look one pixel off and macOS rounds them anyway.
    public func frame(in area: CGRect) -> CGRect {
        CGRect(
            x: (area.minX + CGFloat(x) * area.width).rounded(),
            y: (area.minY + CGFloat(y) * area.height).rounded(),
            width: (CGFloat(w) * area.width).rounded(),
            height: (CGFloat(h) * area.height).rounded()
        )
    }

    /// True when this rect is within a hair of `other`.
    ///
    /// Used to decide whether a window is already where it should be, so a
    /// restore does not nudge windows that are already correct.
    public func isNearly(_ other: UnitRect, tolerance: Double = 0.01) -> Bool {
        abs(x - other.x) <= tolerance
            && abs(y - other.y) <= tolerance
            && abs(w - other.w) <= tolerance
            && abs(h - other.h) <= tolerance
    }
}
