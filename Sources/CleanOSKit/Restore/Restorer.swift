import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Puts the windows back.
public struct Restorer {

    public struct Report: Sendable {
        public var profileName: String
        public var matchedMonitors: String
        public var applied: [String] = []
        public var problems: [String] = []
        public var dryRun: Bool = false

        public init(profileName: String, matchedMonitors: String) {
            self.profileName = profileName
            self.matchedMonitors = matchedMonitors
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case notTrusted
        case noRecording
        case noMatchingRecording(profileKey: String)

        public var description: String {
            switch self {
            case .notTrusted:
                return "Accessibility permission has not been granted, so no window can be moved."
            case .noRecording:
                return "There is no recording yet. Arrange your windows and record one first."
            case .noMatchingRecording(let key):
                return "No recording shares a monitor with the current setup (\(key))."
            }
        }
    }

    public var store: SnapshotStore
    public var appVersion: String
    /// How long to wait for a launched app to put a window on screen.
    public var launchTimeout: TimeInterval = 8

    public init(store: SnapshotStore, appVersion: String) {
        self.store = store
        self.appVersion = appVersion
    }

    /// Restore, or with `dryRun` just say what would happen.
    public func restore(dryRun: Bool = false) throws -> Report {
        guard Accessibility.isTrusted else { throw Failure.notTrusted }

        let displays = Displays.current()
        let snapshots = try store.loadAll()
        guard !snapshots.isEmpty else { throw Failure.noRecording }
        guard let resolution = ProfileResolver.resolve(snapshots: snapshots, current: displays) else {
            throw Failure.noMatchingRecording(profileKey: displays.key)
        }

        var report = Report(
            profileName: resolution.snapshot.name,
            matchedMonitors: describe(resolution: resolution, displays: displays)
        )
        report.dryRun = dryRun

        var captured = Capturer.capture(displays: displays)

        // Everything that follows can move windows, so the way back is written
        // down first, and the record of what was on screen is flushed to disk
        // before anything is touched.
        if !dryRun {
            let before = Capturer.makeSnapshot(
                from: captured,
                displays: displays,
                name: "before restore",
                sweptAllSpaces: false,
                appVersion: appVersion
            )
            try? store.saveUndo(before)
            store.appendLog([
                "event": "restore.before",
                "profile": resolution.snapshot.profileKey,
                "windows": captured.map { window in
                    [
                        "bundleID": window.observed.bundleID,
                        "title": window.observed.title,
                        "display": window.observed.displayUUID ?? "",
                        "space": window.observed.spaceIndex ?? -1,
                    ] as [String: Any]
                },
            ] as [String: Any])
        }

        // Launch first, so their windows exist before anything is placed.
        let firstPass = WindowResolver.resolve(
            placements: resolution.snapshot.placements,
            windows: captured.map(\.observed)
        )
        let toLaunch = Set(
            firstPass
                .filter { $0.window == nil && $0.placement.launchIfMissing }
                .map(\.placement.match.bundleID)
        )

        for bundleID in toLaunch.sorted() {
            if dryRun {
                report.applied.append("would launch \(bundleID)")
                continue
            }
            if launch(bundleID: bundleID) {
                report.applied.append("launched \(bundleID)")
            } else {
                report.problems.append("could not launch \(bundleID); it may not be installed")
            }
        }

        if !dryRun, !toLaunch.isEmpty {
            waitForWindows(of: toLaunch, timeout: launchTimeout)
            captured = Capturer.capture(displays: displays)
        }

        let assignments = WindowResolver.resolve(
            placements: resolution.snapshot.placements,
            windows: captured.map(\.observed)
        )
        let plan = Planner.plan(resolution: resolution, assignments: assignments, current: displays)

        for placement in plan.unmatched {
            report.problems.append("\(placement.match.bundleID) is not running and was left alone")
        }

        let elements = Dictionary(
            captured.map { ($0.observed.windowID, $0.element) },
            uniquingKeysWith: { first, _ in first }
        )
        let spaceIDs = spaceIDLookup(displays: displays)

        for action in plan.actions {
            switch action {
            case .launch:
                continue  // handled above

            case .switchToSpace(_, let index):
                if dryRun {
                    report.applied.append("would switch to desktop \(index)")
                } else {
                    SpaceMover.switchToSpace(index: index)
                }

            case .moveWindowToSpace(let windowID, let bundleID, let displayUUID, let index):
                if dryRun {
                    report.applied.append("would move \(bundleID) to desktop \(index)")
                    continue
                }
                guard let element = elements[windowID] else {
                    report.problems.append("\(bundleID) disappeared before it could be moved")
                    continue
                }
                let outcome = SpaceMover.move(
                    element: element,
                    windowID: windowID,
                    bundleID: bundleID,
                    toSpaceIndex: index,
                    targetSpaceID: spaceIDs[SpaceKey(displayUUID: displayUUID, index: index)]
                )
                switch outcome {
                case .alreadyThere:
                    break
                case .movedByBridgedOperation, .movedDirectly, .movedByDrag:
                    report.applied.append("moved \(bundleID) to desktop \(index)")
                case .refusedTabStrip(let id):
                    report.problems.append(
                        "\(id) was not moved to desktop \(index) on purpose: its title bar is a row of tabs, and dragging it would tear a tab out. Move it by hand, or assign the app to that desktop by right-clicking its Dock icon."
                    )
                case .refusedNoTitleBar:
                    report.problems.append("\(bundleID) has no title bar to drag, so it stayed where it was")
                case .failed(let reason):
                    report.problems.append("\(bundleID) did not reach desktop \(index): \(reason)")
                }

            case .setFrame(let windowID, let bundleID, let frame):
                if dryRun {
                    report.applied.append(
                        "would place \(bundleID) at \(Int(frame.origin.x)), \(Int(frame.origin.y)) size \(Int(frame.width)) by \(Int(frame.height))"
                    )
                    continue
                }
                guard let element = elements[windowID] else { continue }
                guard Accessibility.isMovable(element) else {
                    report.problems.append(
                        "\(bundleID) refused to be moved. It is probably in full screen or tiled by macOS."
                    )
                    continue
                }
                if Accessibility.setFrame(frame, on: element) {
                    report.applied.append("placed \(bundleID)")
                } else {
                    report.problems.append("\(bundleID) did not accept its new position")
                }
            }
        }

        if !dryRun {
            store.appendLog([
                "event": "restore.after",
                "profile": resolution.snapshot.profileKey,
                "applied": report.applied,
                "problems": report.problems,
            ] as [String: Any])
        }

        return report
    }

    /// Put back whatever the last restore changed.
    public func undo() throws -> Report {
        let displays = Displays.current()
        guard let previous = try store.loadUndo(profileKey: displays.key) else {
            throw Failure.noRecording
        }
        let resolution = ProfileResolver.Resolution(
            snapshot: previous,
            bindings: ProfileResolver.bind(
                recorded: previous.displays,
                current: displays,
                fallback: displays.main?.uuid ?? ""
            ),
            matchedCount: previous.displays.count,
            isExact: true
        )
        var report = Report(profileName: "undo", matchedMonitors: displays.key)
        let captured = Capturer.capture(displays: displays)
        let assignments = WindowResolver.resolve(
            placements: previous.placements,
            windows: captured.map(\.observed)
        )
        let plan = Planner.plan(resolution: resolution, assignments: assignments, current: displays)
        let elements = Dictionary(
            captured.map { ($0.observed.windowID, $0.element) },
            uniquingKeysWith: { first, _ in first }
        )
        for action in plan.actions {
            if case .setFrame(let windowID, let bundleID, let frame) = action,
               let element = elements[windowID] {
                if Accessibility.setFrame(frame, on: element) {
                    report.applied.append("put \(bundleID) back")
                }
            }
        }
        return report
    }

    // MARK: Helpers

    struct SpaceKey: Hashable {
        var displayUUID: String
        var index: Int
    }

    func spaceIDLookup(displays: DisplaySet) -> [SpaceKey: UInt64] {
        var lookup: [SpaceKey: UInt64] = [:]
        for group in SkyLight.displaySpaces() {
            guard let display = Displays.resolve(skyLightIdentifier: group.displayIdentifier, in: displays)
            else { continue }
            for space in group.spaces where space.isUserSpace {
                lookup[SpaceKey(displayUUID: display.uuid, index: space.index)] = space.id
            }
        }
        return lookup
    }

    func launch(bundleID: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let done = DispatchSemaphore(value: 0)
        var succeeded = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, _ in
            succeeded = app != nil
            done.signal()
        }
        _ = done.wait(timeout: .now() + 10)
        return succeeded
    }

    /// Wait until the launched apps have windows, or give up.
    ///
    /// Giving up rather than hanging is deliberate: an app that takes too long
    /// should cost you the rest of the restore, not the whole of it.
    func waitForWindows(of bundleIDs: Set<String>, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let pending = bundleIDs.filter { bundleID in
                let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                guard let app = apps.first else { return true }
                return Accessibility.windows(pid: app.processIdentifier).isEmpty
            }
            if pending.isEmpty { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    func describe(resolution: ProfileResolver.Resolution, displays: DisplaySet) -> String {
        if resolution.isExact {
            return "\(displays.displays.count) monitor(s), exact match"
        }
        let absent = resolution.bindings.values.filter {
            if case .absent = $0 { return true }
            return false
        }.count
        if absent > 0 {
            return "\(resolution.matchedCount) of \(resolution.snapshot.displays.count) recorded monitors present; \(absent) folded onto the main one"
        }
        return "\(resolution.matchedCount) monitor(s) matched by hardware"
    }
}
