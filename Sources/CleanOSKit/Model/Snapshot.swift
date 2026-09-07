import CoreGraphics
import Foundation

/// A recorded clean setup for one arrangement of monitors.
public struct Snapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// Sorted display UUIDs joined, identifying which monitor arrangement this
    /// recording belongs to.
    public var profileKey: String
    /// Free text so you can tell recordings apart when you have several.
    public var name: String
    public var createdAt: Date
    /// What the monitors looked like when this was recorded. Kept so a restore
    /// can explain why it could not find a monitor, and so the file is
    /// self-describing.
    public var displays: [DisplayInfo]
    public var placements: [Placement]
    /// What machine and OS recorded this. When a restore misbehaves months
    /// later this is how you work out what changed.
    public var provenance: Provenance

    public struct Provenance: Codable, Equatable, Sendable {
        public var osVersion: String
        public var appVersion: String
        /// True when the recording walked every desktop, false when it only saw
        /// the visible one. A partial recording is still useful but explains
        /// why an app you expected is missing.
        public var sweptAllSpaces: Bool

        public init(osVersion: String, appVersion: String, sweptAllSpaces: Bool) {
            self.osVersion = osVersion
            self.appVersion = appVersion
            self.sweptAllSpaces = sweptAllSpaces
        }
    }

    public init(
        schemaVersion: Int = Snapshot.currentSchemaVersion,
        profileKey: String,
        name: String,
        createdAt: Date = Date(),
        displays: [DisplayInfo],
        placements: [Placement],
        provenance: Provenance
    ) {
        self.schemaVersion = schemaVersion
        self.profileKey = profileKey
        self.name = name
        self.createdAt = createdAt
        self.displays = displays
        self.placements = placements
        self.provenance = provenance
    }

    public var displaySet: DisplaySet { DisplaySet(displays: displays) }
}

/// A window as it exists right now. Not persisted; this is what capture reads
/// and what restore compares against.
public struct ObservedWindow: Equatable, Sendable {
    /// Window server identifier. Valid for this session only.
    public var windowID: UInt32
    public var pid: pid_t
    public var bundleID: String
    public var title: String
    /// Top-left-origin global coordinates, in points.
    public var frame: CGRect
    /// Which display the window's centre falls on. Nil when it falls on none,
    /// which happens for windows parked off-screen.
    public var displayUUID: String?
    /// One-based index within its display. Nil when it could not be read.
    public var spaceIndex: Int?
    public var isMinimized: Bool

    public init(
        windowID: UInt32,
        pid: pid_t,
        bundleID: String,
        title: String,
        frame: CGRect,
        displayUUID: String?,
        spaceIndex: Int?,
        isMinimized: Bool
    ) {
        self.windowID = windowID
        self.pid = pid
        self.bundleID = bundleID
        self.title = title
        self.frame = frame
        self.displayUUID = displayUUID
        self.spaceIndex = spaceIndex
        self.isMinimized = isMinimized
    }
}
