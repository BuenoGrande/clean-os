import CoreGraphics
import Foundation

/// Works out which window on screen each recorded placement refers to.
public enum WindowResolver {

    public struct Assignment: Equatable, Sendable {
        public var placement: Placement
        /// Nil when nothing on screen matches, which means the app is not
        /// running or has no window yet.
        public var window: ObservedWindow?

        public init(placement: Placement, window: ObservedWindow?) {
            self.placement = placement
            self.window = window
        }
    }

    /// Assign windows to placements, never using the same window twice.
    ///
    /// Placements that name a title pattern are resolved first. They are more
    /// specific, so letting a bare bundle-identifier placement claim their
    /// window first would strand them.
    public static func resolve(
        placements: [Placement],
        windows: [ObservedWindow]
    ) -> [Assignment] {
        var claimed: Set<UInt32> = []
        var results: [Int: ObservedWindow] = [:]

        let order = placements.indices.sorted { lhs, rhs in
            let l = placements[lhs], r = placements[rhs]
            let lSpecific = l.match.titleRegex != nil
            let rSpecific = r.match.titleRegex != nil
            if lSpecific != rSpecific { return lSpecific && !rSpecific }
            return l.match.ordinal < r.match.ordinal
        }

        for index in order {
            let match = placements[index].match
            let candidates = candidates(for: match, in: windows)
                .filter { !claimed.contains($0.windowID) }
            guard !candidates.isEmpty else { continue }
            // Prefer the recorded ordinal, but take whatever is left rather
            // than giving up: one window of three having been closed should
            // not strand the other two.
            let chosen = candidates.indices.contains(match.ordinal)
                ? candidates[match.ordinal]
                : candidates[0]
            claimed.insert(chosen.windowID)
            results[index] = chosen
        }

        return placements.indices.map {
            Assignment(placement: placements[$0], window: results[$0])
        }
    }

    /// Windows matching a bundle identifier and optional title pattern, in a
    /// stable order.
    ///
    /// Ordered by position on screen rather than by whatever order the
    /// accessibility API returned, so that the recorded ordinal still means the
    /// same window on the next run.
    static func candidates(for match: WindowMatch, in windows: [ObservedWindow]) -> [ObservedWindow] {
        var matching = windows.filter { $0.bundleID == match.bundleID && !$0.isMinimized }

        if let pattern = match.titleRegex, let regex = try? NSRegularExpression(pattern: pattern) {
            matching = matching.filter { window in
                let range = NSRange(window.title.startIndex..., in: window.title)
                return regex.firstMatch(in: window.title, range: range) != nil
            }
        }

        return matching.sorted { lhs, rhs in
            if lhs.frame.minY != rhs.frame.minY { return lhs.frame.minY < rhs.frame.minY }
            if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
            return lhs.windowID < rhs.windowID
        }
    }
}
