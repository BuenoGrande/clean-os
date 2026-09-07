import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Enumerating monitors, and translating between the two coordinate spaces
/// macOS uses.
///
/// This is a real source of bugs rather than a detail. The Accessibility API and
/// Core Graphics put the origin at the top left of the primary display and count
/// downwards. AppKit's NSScreen puts it at the bottom left and counts upwards.
/// Everything this package stores or compares is in the top-left space, and the
/// only place the other one appears is inside `visibleFrame` below, where it is
/// converted immediately.
public enum Displays {

    /// Every attached monitor.
    public static func current() -> DisplaySet {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return DisplaySet(displays: [])
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return DisplaySet(displays: [])
        }
        let mainID = CGMainDisplayID()
        return DisplaySet(displays: ids.compactMap { info(for: $0, mainID: mainID) })
    }

    static func info(for id: CGDirectDisplayID, mainID: CGDirectDisplayID) -> DisplayInfo? {
        guard let uuid = uuidString(for: id) else { return nil }
        let screen = screen(for: id)
        // CGDisplayBounds is already in the top-left global space, so it needs
        // no conversion. visibleFrame only exists on NSScreen, so it does.
        let frame = CGDisplayBounds(id)
        let visible = screen.map { flip($0.visibleFrame) } ?? frame
        return DisplayInfo(
            uuid: uuid,
            name: screen?.localizedName ?? "Display \(id)",
            vendor: CGDisplayVendorNumber(id),
            model: CGDisplayModelNumber(id),
            serial: CGDisplaySerialNumber(id),
            isMain: id == mainID,
            frame: frame,
            visibleFrame: visible
        )
    }

    /// The stable identity of a monitor across reboots and cable changes.
    ///
    /// A CGDirectDisplayID deliberately is not used for this: it is a handle
    /// valid for the current session only, and matching on it across a reboot
    /// works by coincidence.
    ///
    /// If this function fails to resolve at build time, the declaration lives in
    /// ColorSync; add `import ColorSync` here.
    public static func uuidString(for id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            return (screen.deviceDescription[key] as? NSNumber)?.uint32Value == id
        }
    }

    // MARK: Coordinate spaces

    /// Height of the primary display, which is the axis both spaces are
    /// measured against.
    static var primaryHeight: CGFloat {
        // The primary display is the one sitting at the Cocoa origin, not
        // necessarily the first in the list and not necessarily the one with
        // the menu bar on a multi-monitor setup.
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
        return primary?.frame.height ?? 0
    }

    /// Convert a rect between the bottom-left and top-left origin spaces. The
    /// conversion is its own inverse, so one function serves both directions.
    public static func flip(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    // MARK: Lookup

    /// Which monitor a window sits on, decided by where its centre falls.
    ///
    /// The centre rather than the origin, so that a window straddling two
    /// monitors is attributed to the one showing most of it, which is also how
    /// macOS itself decides.
    public static func display(containing frame: CGRect, in set: DisplaySet) -> DisplayInfo? {
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        if let hit = set.displays.first(where: { $0.frame.contains(centre) }) {
            return hit
        }
        // Off every screen, which happens to minimised and parked windows.
        // Fall back to whichever monitor is nearest so the window still gets
        // attributed somewhere rather than being dropped from the recording.
        return set.displays.min {
            distance(from: centre, to: $0.frame) < distance(from: centre, to: $1.frame)
        }
    }

    static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    /// Resolve the identifier the window server uses for a display, which is
    /// either a UUID or the literal "Main", to a monitor in `set`.
    public static func resolve(skyLightIdentifier: String, in set: DisplaySet) -> DisplayInfo? {
        if skyLightIdentifier == "Main" { return set.main }
        return set.display(uuid: skyLightIdentifier)
    }
}
