import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Reads what is on screen right now.
public enum Capturer {

    /// A window, paired with the handle needed to move it later.
    ///
    /// The handle is kept separate from the plain data so the data stays simple
    /// to store, compare and test, while the handle stays available to restore.
    public struct CapturedWindow {
        public var observed: ObservedWindow
        public var element: AXUIElement

        public init(observed: ObservedWindow, element: AXUIElement) {
            self.observed = observed
            self.element = element
        }
    }

    /// Every ordinary window of every ordinary app.
    ///
    /// Background and menu-bar-only apps are skipped: they have no windows a
    /// person arranges. Windows on desktops other than the visible one are
    /// included when macOS reports them, but it does not always, which is why
    /// recording sweeps the desktops rather than relying on one pass.
    public static func capture(displays: DisplaySet) -> [CapturedWindow] {
        let spaceLookup = spaceIndexLookup(displays: displays)
        var result: [CapturedWindow] = []

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier
            else { continue }

            for element in Accessibility.windows(pid: app.processIdentifier) {
                guard let frame = Accessibility.frame(of: element) else { continue }
                let windowID = SkyLight.windowID(of: element) ?? 0
                let spaceIDs = windowID == 0 ? [] : SkyLight.spaceIDs(forWindow: windowID)
                let located = spaceIDs.compactMap { spaceLookup[$0] }.first

                let observed = ObservedWindow(
                    windowID: windowID,
                    pid: app.processIdentifier,
                    bundleID: bundleID,
                    title: Accessibility.title(of: element),
                    frame: frame,
                    displayUUID: located?.displayUUID
                        ?? Displays.display(containing: frame, in: displays)?.uuid,
                    spaceIndex: located?.index,
                    isMinimized: Accessibility.isMinimized(element)
                )
                result.append(CapturedWindow(observed: observed, element: element))
            }
        }
        return result
    }

    /// Desktop identifier to the monitor and number it corresponds to.
    static func spaceIndexLookup(displays: DisplaySet) -> [UInt64: (displayUUID: String, index: Int)] {
        var lookup: [UInt64: (displayUUID: String, index: Int)] = [:]
        for group in SkyLight.displaySpaces() {
            guard let display = Displays.resolve(skyLightIdentifier: group.displayIdentifier, in: displays)
            else { continue }
            for space in group.spaces where space.isUserSpace {
                lookup[space.id] = (display.uuid, space.index)
            }
        }
        return lookup
    }

    // MARK: Building a recording

    /// Turn what is on screen into a recording.
    ///
    /// Ordinals are assigned by position on screen rather than by the order
    /// macOS happened to return the windows in, so that the same window gets
    /// the same number next time. Titles are stored as a note rather than as a
    /// matching rule, because window titles change constantly and a recording
    /// that matched on them would go stale within the hour.
    public static func makeSnapshot(
        from windows: [CapturedWindow],
        displays: DisplaySet,
        name: String,
        sweptAllSpaces: Bool,
        appVersion: String
    ) -> Snapshot {
        var placements: [Placement] = []
        let byBundle = Dictionary(grouping: windows.map(\.observed)) { $0.bundleID }

        for bundleID in byBundle.keys.sorted() {
            let ordered = (byBundle[bundleID] ?? [])
                .filter { !$0.isMinimized }
                .sorted { lhs, rhs in
                    if lhs.frame.minY != rhs.frame.minY { return lhs.frame.minY < rhs.frame.minY }
                    if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
                    return lhs.windowID < rhs.windowID
                }

            for (ordinal, window) in ordered.enumerated() {
                guard let displayUUID = window.displayUUID,
                      let display = displays.display(uuid: displayUUID)
                else { continue }
                placements.append(Placement(
                    match: WindowMatch(bundleID: bundleID, titleRegex: nil, ordinal: ordinal),
                    target: PlacementTarget(
                        displayUUID: displayUUID,
                        spaceIndex: window.spaceIndex,
                        unitRect: UnitRect(frame: window.frame, in: display.visibleFrame)
                    ),
                    launchIfMissing: true,
                    note: window.title.isEmpty ? nil : window.title
                ))
            }
        }

        return Snapshot(
            profileKey: displays.key,
            name: name,
            displays: displays.displays,
            placements: placements,
            provenance: Snapshot.Provenance(
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                appVersion: appVersion,
                sweptAllSpaces: sweptAllSpaces
            )
        )
    }
}
