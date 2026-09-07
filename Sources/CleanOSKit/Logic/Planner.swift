import CoreGraphics
import Foundation

/// One thing restore will do. Kept as data rather than executed directly so the
/// plan can be printed, tested, and reviewed before anything moves.
public enum RestoreAction: Equatable, Sendable {
    case launch(bundleID: String)
    case switchToSpace(displayUUID: String, spaceIndex: Int)
    case moveWindowToSpace(windowID: UInt32, bundleID: String, displayUUID: String, spaceIndex: Int)
    case setFrame(windowID: UInt32, bundleID: String, frame: CGRect)
}

/// Turns a matched recording into an ordered list of actions.
public enum Planner {

    public struct Plan: Equatable, Sendable {
        public var actions: [RestoreAction]
        /// Placements with no window on screen and no permission to launch.
        public var unmatched: [Placement]

        public init(actions: [RestoreAction], unmatched: [Placement]) {
            self.actions = actions
            self.unmatched = unmatched
        }
    }

    /// Build the plan.
    ///
    /// Order matters and is not arbitrary. Launches come first so their windows
    /// exist by the time anything is placed. Desktop moves come next, grouped by
    /// the desktop each window is currently on, because the drag that performs
    /// the move only works on the desktop you are looking at, so every group
    /// costs one switch and its animation. Sizing comes last, because moving a
    /// window between desktops can shift it.
    public static func plan(
        resolution: ProfileResolver.Resolution,
        assignments: [WindowResolver.Assignment],
        current: DisplaySet
    ) -> Plan {
        var actions: [RestoreAction] = []
        var unmatched: [Placement] = []

        for assignment in assignments where assignment.window == nil {
            if assignment.placement.launchIfMissing {
                actions.append(.launch(bundleID: assignment.placement.match.bundleID))
            } else {
                unmatched.append(assignment.placement)
            }
        }

        // Desktop moves, grouped by where the window is now.
        struct Move {
            var window: ObservedWindow
            var targetDisplay: String
            var targetSpace: Int
        }
        var moves: [Move] = []

        for assignment in assignments {
            guard let window = assignment.window,
                  let targetSpace = assignment.placement.target.spaceIndex,
                  let targetDisplay = resolution.currentUUID(for: assignment.placement.target.displayUUID)
            else { continue }
            // Already right, or we could not read where it is. Reading failure
            // is treated as already-right rather than moving blind, because a
            // wrong move is worse than a missed one.
            guard let currentSpace = window.spaceIndex else { continue }
            let sameDisplay = window.displayUUID == targetDisplay
            guard !(sameDisplay && currentSpace == targetSpace) else { continue }
            moves.append(Move(window: window, targetDisplay: targetDisplay, targetSpace: targetSpace))
        }

        let grouped = Dictionary(grouping: moves) { move in
            SourceSpace(
                displayUUID: move.window.displayUUID ?? "",
                spaceIndex: move.window.spaceIndex ?? 0
            )
        }

        for source in grouped.keys.sorted() {
            guard let group = grouped[source] else { continue }
            actions.append(.switchToSpace(displayUUID: source.displayUUID, spaceIndex: source.spaceIndex))
            for move in group.sorted(by: { $0.window.windowID < $1.window.windowID }) {
                actions.append(.moveWindowToSpace(
                    windowID: move.window.windowID,
                    bundleID: move.window.bundleID,
                    displayUUID: move.targetDisplay,
                    spaceIndex: move.targetSpace
                ))
            }
        }

        // Sizing.
        for assignment in assignments {
            guard let window = assignment.window,
                  let displayUUID = resolution.currentUUID(for: assignment.placement.target.displayUUID),
                  let display = current.display(uuid: displayUUID)
            else { continue }
            let target = assignment.placement.target.unitRect
            let currentRect = UnitRect(frame: window.frame, in: display.visibleFrame)
            // Skip windows already where they belong, so restoring twice in a
            // row is silent rather than shuffling everything again.
            if window.displayUUID == displayUUID, currentRect.isNearly(target) { continue }
            actions.append(.setFrame(
                windowID: window.windowID,
                bundleID: window.bundleID,
                frame: target.frame(in: display.visibleFrame)
            ))
        }

        return Plan(actions: actions, unmatched: unmatched)
    }

    struct SourceSpace: Hashable, Comparable {
        var displayUUID: String
        var spaceIndex: Int

        static func < (lhs: SourceSpace, rhs: SourceSpace) -> Bool {
            if lhs.displayUUID != rhs.displayUUID { return lhs.displayUUID < rhs.displayUUID }
            return lhs.spaceIndex < rhs.spaceIndex
        }
    }
}
