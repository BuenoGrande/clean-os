import Foundation

/// Decides which recording applies to the monitors attached right now, and how
/// its recorded monitors map onto the present ones.
///
/// The point of this type is to degrade instead of refusing. Undock the laptop
/// and the recording made at the desk should still do something sensible, which
/// means folding the missing monitor's windows onto one that is present rather
/// than reporting no match. The tool this idea comes from keys layouts on the
/// exact monitor count and resolution and loses them whenever that changes,
/// which is the failure this ladder exists to avoid.
public enum ProfileResolver {

    /// One recorded monitor, matched or not, against the present ones.
    public enum DisplayBinding: Equatable, Sendable {
        /// The same monitor is present, found by UUID.
        case exact(currentUUID: String)
        /// A monitor with the same vendor, model and serial is present under a
        /// different UUID. Display UUIDs are reported to change across reboots
        /// on some machines, so this rung matters more than it looks.
        case byHardware(currentUUID: String)
        /// Not present. Its windows fold onto the fallback monitor.
        case absent(foldedOnto: String)
    }

    public struct Resolution: Equatable, Sendable {
        public var snapshot: Snapshot
        /// Recorded display UUID to how it was bound.
        public var bindings: [String: DisplayBinding]
        /// How many recorded monitors were actually found.
        public var matchedCount: Int
        /// True when every recorded monitor was found by UUID.
        public var isExact: Bool

        public init(
            snapshot: Snapshot,
            bindings: [String: DisplayBinding],
            matchedCount: Int,
            isExact: Bool
        ) {
            self.snapshot = snapshot
            self.bindings = bindings
            self.matchedCount = matchedCount
            self.isExact = isExact
        }

        /// Where a placement recorded against `recordedUUID` should actually go.
        public func currentUUID(for recordedUUID: String) -> String? {
            switch bindings[recordedUUID] {
            case .exact(let uuid), .byHardware(let uuid), .absent(let uuid):
                return uuid
            case nil:
                return nil
            }
        }
    }

    /// Pick the best recording for `current`, or nil when none shares a monitor.
    ///
    /// Refusing when nothing overlaps is deliberate. Applying a recording made
    /// on a completely different set of monitors would move windows somewhere
    /// arbitrary, which is worse than doing nothing.
    public static func resolve(
        snapshots: [Snapshot],
        current: DisplaySet
    ) -> Resolution? {
        guard let fallback = current.main?.uuid else { return nil }

        let candidates = snapshots.compactMap { snapshot -> Resolution? in
            let bindings = bind(recorded: snapshot.displays, current: current, fallback: fallback)
            let matched = bindings.values.filter { binding in
                if case .absent = binding { return false }
                return true
            }.count
            guard matched > 0 else { return nil }
            let exact = matched == snapshot.displays.count
                && bindings.values.allSatisfy { binding in
                    if case .exact = binding { return true }
                    return false
                }
            return Resolution(
                snapshot: snapshot,
                bindings: bindings,
                matchedCount: matched,
                isExact: exact
            )
        }

        // Most monitors matched wins. Exactness breaks a tie, then recency, so
        // that re-recording the same setup supersedes the older file.
        return candidates.max { a, b in
            if a.matchedCount != b.matchedCount { return a.matchedCount < b.matchedCount }
            if a.isExact != b.isExact { return !a.isExact && b.isExact }
            return a.snapshot.createdAt < b.snapshot.createdAt
        }
    }

    static func bind(
        recorded: [DisplayInfo],
        current: DisplaySet,
        fallback: String
    ) -> [String: DisplayBinding] {
        var bindings: [String: DisplayBinding] = [:]
        var claimed: Set<String> = []

        // UUID first, for every recorded monitor, before falling back to
        // hardware. Otherwise a hardware match could steal a monitor that a
        // later recorded entry would have matched exactly.
        for display in recorded {
            if current.display(uuid: display.uuid) != nil, !claimed.contains(display.uuid) {
                bindings[display.uuid] = .exact(currentUUID: display.uuid)
                claimed.insert(display.uuid)
            }
        }

        for display in recorded where bindings[display.uuid] == nil {
            let match = current.displays.first {
                $0.hardwareKey == display.hardwareKey && !claimed.contains($0.uuid)
            }
            if let match {
                bindings[display.uuid] = .byHardware(currentUUID: match.uuid)
                claimed.insert(match.uuid)
            } else {
                bindings[display.uuid] = .absent(foldedOnto: fallback)
            }
        }

        return bindings
    }
}
