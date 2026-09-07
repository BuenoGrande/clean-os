import Foundation

/// Reads the handful of macOS settings the desktop mechanism depends on.
///
/// All three are non-default, and getting one wrong produces a confusing
/// failure rather than an obvious one: desktops that silently renumber
/// themselves, or a keystroke that does nothing. Checking them up front turns
/// three mysteries into three sentences.
public enum SystemSettings {

    public struct Check: Equatable, Sendable {
        public var name: String
        public var isSatisfied: Bool
        /// What to do about it, in the words the System Settings pane uses.
        public var remedy: String

        public init(name: String, isSatisfied: Bool, remedy: String) {
            self.name = name
            self.isSatisfied = isSatisfied
            self.remedy = remedy
        }
    }

    public static func all() -> [Check] {
        [desktopShortcuts(), spacesDoNotRearrange(), displaysHaveSeparateSpaces()]
    }

    /// Mission Control needs a keyboard shortcut per desktop, because those
    /// keystrokes are how both switching and moving are performed.
    public static func desktopShortcuts() -> Check {
        let enabled = enabledDesktopShortcuts()
        return Check(
            name: "Keyboard shortcuts for Desktop 1 to 9",
            isSatisfied: !enabled.isEmpty,
            remedy: enabled.isEmpty
                ? "Turn these on in System Settings, Keyboard, Keyboard Shortcuts, Mission Control. Without them no window can be moved between desktops."
                : "Enabled for desktop \(enabled.sorted().map(String.init).joined(separator: ", "))."
        )
    }

    /// Which desktop numbers currently have a shortcut.
    ///
    /// Stored as one entry per desktop in the symbolic hotkeys preferences,
    /// numbered from 118 for Desktop 1.
    public static func enabledDesktopShortcuts() -> Set<Int> {
        guard let defaults = UserDefaults(suiteName: "com.apple.symbolichotkeys"),
              let hotkeys = defaults.dictionary(forKey: "AppleSymbolicHotKeys")
        else { return [] }

        var result: Set<Int> = []
        for desktop in 1...9 {
            let identifier = String(117 + desktop)
            guard let entry = hotkeys[identifier] as? [String: Any],
                  let enabled = entry["enabled"] as? Bool, enabled
            else { continue }
            result.insert(desktop)
        }
        return result
    }

    /// Desktops must keep their numbers. With automatic rearranging on, macOS
    /// reorders them by how recently they were used, so a recorded desktop
    /// number stops meaning anything.
    public static func spacesDoNotRearrange() -> Check {
        let rearranges = UserDefaults(suiteName: "com.apple.dock")?
            .object(forKey: "mru-spaces") as? Bool ?? true
        return Check(
            name: "Desktops keep a fixed order",
            isSatisfied: !rearranges,
            remedy: rearranges
                ? "Turn off Automatically rearrange Spaces based on most recent use in System Settings, Desktop and Dock. Left on, your desktops renumber themselves and a recording cannot mean anything."
                : "Fixed."
        )
    }

    /// Each monitor should own its own desktops, which is the model a recording
    /// assumes when it stores a desktop number per monitor.
    public static func displaysHaveSeparateSpaces() -> Check {
        // Stored inverted: spanning displays is the opposite of giving each
        // display its own desktops.
        let spans = UserDefaults(suiteName: "com.apple.spaces")?
            .object(forKey: "spans-displays") as? Bool ?? false
        return Check(
            name: "Displays have separate Spaces",
            isSatisfied: !spans,
            remedy: spans
                ? "Turn on Displays have separate Spaces in System Settings, Desktop and Dock, then log out and back in. Otherwise desktops span all monitors and cannot be recorded per monitor."
                : "On."
        )
    }
}
