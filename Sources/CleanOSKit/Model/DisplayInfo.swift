import CoreGraphics
import Foundation

/// A monitor, identified so that it can be recognised again after a reboot,
/// a cable swap, or a change of port.
///
/// `uuid` is the primary key. A `CGDirectDisplayID` deliberately is not, because
/// it is a session handle that changes across reboots. The vendor, model and
/// serial numbers exist as a fallback because display UUIDs are known to
/// collide between two identical monitors, and are reported to be unstable
/// across reboots on some Apple silicon machines.
public struct DisplayInfo: Codable, Equatable, Sendable {
    public var uuid: String
    public var name: String
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32
    public var isMain: Bool

    /// Full bounds in the top-left-origin global space, in points.
    public var frame: CGRect
    /// Bounds excluding the menu bar and the Dock. Windows are placed in here.
    public var visibleFrame: CGRect

    public init(
        uuid: String,
        name: String,
        vendor: UInt32,
        model: UInt32,
        serial: UInt32,
        isMain: Bool,
        frame: CGRect,
        visibleFrame: CGRect
    ) {
        self.uuid = uuid
        self.name = name
        self.vendor = vendor
        self.model = model
        self.serial = serial
        self.isMain = isMain
        self.frame = frame
        self.visibleFrame = visibleFrame
    }

    /// Identity ignoring position and size, for the fallback match.
    public var hardwareKey: String {
        "\(vendor):\(model):\(serial)"
    }
}

/// The set of monitors attached right now.
///
/// A recorded layout belongs to one of these. Its `key` is the sorted list of
/// display UUIDs, joined. Sorted so that the key does not depend on the order
/// macOS happens to enumerate monitors in, and readable rather than hashed so
/// that the file name on disk tells you which setup it belongs to.
public struct DisplaySet: Codable, Equatable, Sendable {
    public var displays: [DisplayInfo]

    public init(displays: [DisplayInfo]) {
        self.displays = displays
    }

    public var key: String {
        displays.map(\.uuid).sorted().joined(separator: "_")
    }

    public var uuids: Set<String> {
        Set(displays.map(\.uuid))
    }

    public var main: DisplayInfo? {
        displays.first(where: \.isMain) ?? displays.first
    }

    public func display(uuid: String) -> DisplayInfo? {
        displays.first { $0.uuid == uuid }
    }
}
