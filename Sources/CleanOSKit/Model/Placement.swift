import Foundation

/// How a recorded placement finds its window again.
///
/// Not by window identifier: those are handed out by the window server and are
/// not stable across a relaunch of the owning app, so a recording keyed on them
/// would stop working the first time you quit anything.
public struct WindowMatch: Codable, Equatable, Sendable {
    /// Bundle identifier, for example `com.brave.Browser`. Never the display
    /// name, which is localised and changes.
    public var bundleID: String
    /// Optional regular expression against the window title, for apps that keep
    /// several windows open and where the title says which is which.
    public var titleRegex: String?
    /// Which of the matching windows this is, when more than one matches.
    /// Ordered by the window's position on screen so the answer is stable.
    public var ordinal: Int

    public init(bundleID: String, titleRegex: String? = nil, ordinal: Int = 0) {
        self.bundleID = bundleID
        self.titleRegex = titleRegex
        self.ordinal = ordinal
    }
}

/// Where a window belongs.
public struct PlacementTarget: Codable, Equatable, Sendable {
    public var displayUUID: String
    /// One-based, counted within this display rather than globally, because
    /// global numbering shifts whenever a desktop is added or removed.
    /// Nil means the recording did not capture desktops.
    public var spaceIndex: Int?
    public var unitRect: UnitRect

    public init(displayUUID: String, spaceIndex: Int?, unitRect: UnitRect) {
        self.displayUUID = displayUUID
        self.spaceIndex = spaceIndex
        self.unitRect = unitRect
    }
}

/// One line of the recording: this window goes there.
public struct Placement: Codable, Equatable, Sendable {
    public var match: WindowMatch
    public var target: PlacementTarget
    public var launchIfMissing: Bool
    /// Human-readable label, only so the JSON file reads well when you open it.
    public var note: String?

    public init(
        match: WindowMatch,
        target: PlacementTarget,
        launchIfMissing: Bool = true,
        note: String? = nil
    ) {
        self.match = match
        self.target = target
        self.launchIfMissing = launchIfMissing
        self.note = note
    }
}
