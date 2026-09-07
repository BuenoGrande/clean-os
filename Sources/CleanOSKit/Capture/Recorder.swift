import Foundation

/// Records the current arrangement.
public struct Recorder {

    public var store: SnapshotStore
    public var appVersion: String

    public init(store: SnapshotStore, appVersion: String) {
        self.store = store
        self.appVersion = appVersion
    }

    public enum Failure: Error, CustomStringConvertible {
        case notTrusted
        case noDisplays

        public var description: String {
            switch self {
            case .notTrusted:
                return "Accessibility permission has not been granted, so windows cannot be read."
            case .noDisplays:
                return "No monitors were found, which should not be possible."
            }
        }
    }

    public struct Result: Sendable {
        public var snapshot: Snapshot
        public var url: URL
        public var sweptSpaces: Int
        public var notes: [String]
    }

    /// Walk the desktops, read every window, write the recording.
    ///
    /// The sweep exists because macOS will not list the windows on a desktop
    /// you are not looking at. Rather than record a partial picture and have a
    /// restore quietly miss half your apps, the recorder visits each desktop in
    /// turn and comes back. It costs a couple of seconds and some animation.
    ///
    /// Set `sweep` to false to record only what is visible, which is right when
    /// you only use one desktop.
    public func record(name: String, sweep: Bool = true) throws -> Result {
        guard Accessibility.isTrusted else { throw Failure.notTrusted }
        let displays = Displays.current()
        guard !displays.displays.isEmpty else { throw Failure.noDisplays }

        var notes: [String] = []
        var merged: [UInt32: Capturer.CapturedWindow] = [:]
        var visited = 0

        func absorb() {
            for window in Capturer.capture(displays: displays) {
                // Keyed by window so a second sighting on another desktop
                // replaces the first rather than duplicating it.
                merged[window.observed.windowID] = window
            }
        }

        absorb()

        let shortcuts = SystemSettings.enabledDesktopShortcuts()
        let spaceCount = SkyLight.displaySpaces()
            .map { $0.spaces.filter(\.isUserSpace).count }
            .max() ?? 1

        if sweep, spaceCount > 1 {
            if shortcuts.isEmpty {
                notes.append(
                    "Only the visible desktop was recorded. Keyboard shortcuts for switching desktops are turned off, so the other desktops could not be visited. Turn them on in System Settings, Keyboard, Keyboard Shortcuts, Mission Control."
                )
            } else {
                let startIndex = SkyLight.displaySpaces().first?.currentIndex
                for index in 1...min(spaceCount, 9) where shortcuts.contains(index) {
                    SpaceMover.switchToSpace(index: index)
                    absorb()
                    visited += 1
                }
                if let startIndex, shortcuts.contains(startIndex) {
                    SpaceMover.switchToSpace(index: startIndex)
                }
                let withoutShortcut = (1...min(spaceCount, 9)).filter { !shortcuts.contains($0) }
                if !withoutShortcut.isEmpty {
                    notes.append(
                        "Desktop \(withoutShortcut.map(String.init).joined(separator: ", ")) could not be visited because there is no keyboard shortcut for it, so any window there was not recorded."
                    )
                }
                // macOS only offers switching shortcuts for the first nine
                // desktops, so anything past that cannot be reached at all.
                // Saying so matters: otherwise a recording quietly covers part
                // of the machine and the gap only shows up as a restore that
                // misses half your apps.
                if spaceCount > 9 {
                    notes.append(
                        "Desktop 10 to \(spaceCount) were skipped. macOS only provides switching shortcuts for the first nine desktops, so there is no way to reach the rest, and any window on them was not recorded. Consider moving what matters onto desktops 1 to 9."
                    )
                }
            }
        }

        let snapshot = Capturer.makeSnapshot(
            from: Array(merged.values),
            displays: displays,
            name: name,
            sweptAllSpaces: visited >= spaceCount,
            appVersion: appVersion
        )
        try store.save(snapshot)
        store.appendLog([
            "event": "record",
            "profile": snapshot.profileKey,
            "placements": snapshot.placements.count,
            "sweptAllSpaces": snapshot.provenance.sweptAllSpaces,
        ] as [String: Any])

        return Result(
            snapshot: snapshot,
            url: store.url(forProfile: snapshot.profileKey),
            sweptSpaces: visited,
            notes: notes
        )
    }
}
