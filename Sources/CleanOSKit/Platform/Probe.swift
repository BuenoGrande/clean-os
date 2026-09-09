import AppKit
import ApplicationServices
import Foundation

/// Finds out what actually works on this Mac.
///
/// Everything to do with desktops is undocumented and Apple changes it without
/// notice, so which techniques function is a question about your machine and
/// your macOS version rather than something to be assumed. This runs each one
/// and reports, and its output is what decides whether desktop support is worth
/// keeping.
///
/// Nothing here moves a window unless you ask for the move test explicitly.
public enum Probe {

    public struct Line: Sendable {
        public var label: String
        public var value: String
        public var ok: Bool?

        public init(label: String, value: String, ok: Bool? = nil) {
            self.label = label
            self.value = value
            self.ok = ok
        }
    }

    public struct Section: Sendable {
        public var title: String
        public var lines: [Line]

        public init(title: String, lines: [Line]) {
            self.title = title
            self.lines = lines
        }
    }

    /// Why a window is or is not a fair subject for the move test.
    static func verdict(for window: Capturer.CapturedWindow) -> String {
        let observed = window.observed
        let place = observed.spaceIndex.map { "desktop \($0)" } ?? "desktop unknown"
        if observed.isMinimized { return "\(place), minimised" }
        if SpaceMover.tabStripApps.contains(observed.bundleID) {
            return "\(place), skipped because its title bar is a tab strip"
        }
        if !Accessibility.isMovable(window.element) {
            return "\(place), cannot be moved or resized, probably full screen or tiled"
        }
        if knownStandardTitleBar.contains(observed.bundleID) {
            return "\(place), usable and has an ordinary title bar"
        }
        return "\(place), usable but may draw its own title bar"
    }

    /// Apple apps whose title bar is a plain title bar, used to pick a fair
    /// subject for the move test.
    static let knownStandardTitleBar: Set<String> = [
        "com.apple.finder",
        "com.apple.TextEdit",
        "com.apple.Notes",
        "com.apple.Preview",
        "com.apple.ActivityMonitor",
        "com.apple.systempreferences",
        "com.apple.iCal",
        "com.apple.AddressBook",
    ]

    public static func run(includeMoveTest: Bool) -> [Section] {
        var sections: [Section] = []

        sections.append(Section(title: "Permission", lines: [
            Line(
                label: "Accessibility",
                value: Accessibility.isTrusted
                    ? "granted"
                    : "not granted. Everything below that touches a window will fail. Grant it in System Settings, Privacy and Security, Accessibility.",
                ok: Accessibility.isTrusted
            ),
        ]))

        sections.append(Section(
            title: "System settings",
            lines: SystemSettings.all().map {
                Line(label: $0.name, value: $0.remedy, ok: $0.isSatisfied)
            }
        ))

        sections.append(Section(
            title: "Private window server symbols",
            lines: SkyLight.availability
                .sorted { $0.key < $1.key }
                .map { Line(label: $0.key, value: $0.value ? "found" : "missing", ok: $0.value) }
        ))

        let displays = Displays.current()
        sections.append(Section(title: "Monitors", lines: displays.displays.map { display in
            Line(
                label: display.name,
                value: "\(display.uuid) size \(Int(display.frame.width)) by \(Int(display.frame.height))\(display.isMain ? ", main" : "")",
                ok: true
            )
        } + [Line(label: "Profile key", value: displays.key)]))

        let groups = SkyLight.displaySpaces()
        var desktopLines: [Line] = groups.isEmpty
            ? [Line(label: "Enumeration", value: "returned nothing, so desktops cannot be read on this machine", ok: false)]
            : groups.map { group in
                let user = group.spaces.filter(\.isUserSpace)
                let name = Displays.resolve(skyLightIdentifier: group.displayIdentifier, in: displays)?.name
                    ?? group.displayIdentifier
                return Line(
                    label: name,
                    value: "\(user.count) desktop(s), currently on \(group.currentIndex.map(String.init) ?? "unknown")",
                    ok: !user.isEmpty
                )
            }

        // Everything here addresses desktops through the Mission Control
        // keystrokes, and macOS only provides those for the first nine. More
        // than nine desktops is therefore a hard limit rather than a warning,
        // and it is much better learned now than after a recording quietly
        // covers two thirds of the machine.
        let mostDesktops = groups.map { $0.spaces.filter(\.isUserSpace).count }.max() ?? 0
        if mostDesktops > 9 {
            desktopLines.append(Line(
                label: "Reachable",
                value: "only desktops 1 to 9. You have \(mostDesktops), so \(mostDesktops - 9) of them cannot be recorded or restored at all, because macOS provides no switching shortcut past the ninth. Move what matters onto the first nine.",
                ok: false
            ))
        }
        sections.append(Section(title: "Desktops", lines: desktopLines))

        let windows = Accessibility.isTrusted ? Capturer.capture(displays: displays) : []
        let located = windows.filter { $0.observed.spaceIndex != nil }.count
        var windowLines: [Line] = [
            Line(label: "Readable windows", value: "\(windows.count)", ok: !windows.isEmpty),
            Line(
                label: "Located on a desktop",
                value: "\(located) of \(windows.count)",
                ok: windows.isEmpty ? nil : located > 0
            ),
        ]
        // Naming each window and why it is or is not a usable test subject.
        // Without this, a move test that keeps choosing the wrong window looks
        // like the technique failing rather than the choice being wrong.
        for window in windows.sorted(by: { $0.observed.bundleID < $1.observed.bundleID }) {
            windowLines.append(Line(
                label: window.observed.bundleID,
                value: verdict(for: window),
                ok: nil
            ))
        }
        sections.append(Section(title: "Windows", lines: windowLines))

        if includeMoveTest {
            sections.append(moveTest(displays: displays, windows: windows))
        } else {
            sections.append(Section(title: "Moving between desktops", lines: [
                Line(
                    label: "Not tested",
                    value: "Run again with --try-move to test it. That test moves a real window to another desktop and back."
                ),
            ]))
        }

        return sections
    }

    /// Move one window to another desktop and put it back.
    ///
    /// Choosing the subject is most of the work. A window whose app draws its
    /// own title bar will fail for reasons that have nothing to do with
    /// whether the technique works, so this looks for an ordinary title bar
    /// first, and will visit another desktop to find one rather than testing
    /// whatever happens to be in front of you. It always puts the window back
    /// and returns you to the desktop you started on.
    static func moveTest(displays: DisplaySet, windows: [Capturer.CapturedWindow]) -> Section {
        guard let group = SkyLight.displaySpaces().first(where: { $0.spaces.filter(\.isUserSpace).count > 1 }),
              let startedOn = group.currentIndex
        else {
            return Section(title: "Moving between desktops", lines: [
                Line(
                    label: "Skipped",
                    value: "There is only one desktop, so there is nowhere to move a window to. Add a second desktop in Mission Control and run this again.",
                    ok: nil
                ),
            ])
        }

        // Only desktops with a switching shortcut can be reached, so only
        // windows living on those can be tested or moved.
        let reachable = 1...9
        let usable = windows.filter { window in
            guard let index = window.observed.spaceIndex else { return false }
            return reachable.contains(index)
                && !SpaceMover.tabStripApps.contains(window.observed.bundleID)
                && !window.observed.isMinimized
                && Accessibility.isMovable(window.element)
        }

        let requested = ProcessInfo.processInfo.environment["CLEANOS_TEST_APP"]
        if let requested {
            if usable.first(where: { $0.observed.bundleID == requested }) == nil {
                let elsewhere = windows.first { $0.observed.bundleID == requested }
                let detail = elsewhere.flatMap(\.observed.spaceIndex).map { index in
                    index > 9
                        ? "Its window is on desktop \(index), which has no switching shortcut and cannot be reached. Move that window onto desktops 1 to 9 first."
                        : "Its window is on desktop \(index) but is minimised, tiled, or refuses to be moved."
                } ?? "It has no readable window at all. Open one and run this again."
                return Section(title: "Moving between desktops", lines: [
                    Line(label: "Requested app not usable", value: "\(requested). \(detail)", ok: false),
                ])
            }
        }

        // Prefer an explicit choice, then an ordinary title bar anywhere
        // reachable, then whatever is on the desktop in front of you.
        let candidate = requested.flatMap { id in usable.first { $0.observed.bundleID == id } }
            ?? usable.first { knownStandardTitleBar.contains($0.observed.bundleID) && $0.observed.spaceIndex == startedOn }
            ?? usable.first { knownStandardTitleBar.contains($0.observed.bundleID) }
            ?? usable.first { $0.observed.spaceIndex == startedOn }
            ?? usable.first

        guard let candidate, let home = candidate.observed.spaceIndex else {
            return Section(title: "Moving between desktops", lines: [
                Line(
                    label: "Skipped",
                    value: "No window with an ordinary title bar on desktops 1 to 9. Open TextEdit or a Finder window on one of them and run this again.",
                    ok: nil
                ),
            ])
        }

        let userSpaces = group.spaces.filter(\.isUserSpace)
        guard let target = userSpaces.first(where: { $0.index != home && reachable.contains($0.index) }) else {
            return Section(title: "Moving between desktops", lines: [
                Line(label: "Skipped", value: "Could not find a second reachable desktop to aim at.", ok: nil),
            ])
        }

        var lines: [Line] = [
            Line(
                label: "Test window",
                value: "\(candidate.observed.bundleID) on desktop \(home), aiming at desktop \(target.index)"
            ),
        ]
        if !knownStandardTitleBar.contains(candidate.observed.bundleID) {
            lines.append(Line(
                label: "Caution",
                value: "this app may draw its own title bar, so a failure below might be the grab point rather than the technique. Open TextEdit on a reachable desktop and run again to be sure.",
                ok: nil
            ))
        }

        // Go to the window before touching it: the gesture only works on the
        // desktop being displayed.
        if home != startedOn {
            SpaceMover.switchToSpace(index: home)
            lines.append(Line(label: "Visited desktop \(home)", value: "to reach the test window", ok: nil))
        }

        let outcome = SpaceMover.move(
            element: candidate.element,
            windowID: candidate.observed.windowID,
            bundleID: candidate.observed.bundleID,
            toSpaceIndex: target.index,
            targetSpaceID: target.id
        )

        switch outcome {
        case .movedDirectly:
            lines.append(Line(
                label: "Direct window server move",
                value: "worked, which is unexpected on macOS 14.5 and later and is good news: moves will be instant",
                ok: true
            ))
        case .movedByDrag:
            lines.append(Line(
                label: "Direct window server move",
                value: "did nothing, as expected on current macOS",
                ok: nil
            ))
            lines.append(Line(label: "Simulated drag", value: "worked", ok: true))
        case .alreadyThere:
            lines.append(Line(label: "Move", value: "the window was already there", ok: nil))
        case .refusedTabStrip(let id):
            lines.append(Line(label: "Move", value: "refused for \(id), tab strip title bar", ok: nil))
        case .refusedNoTitleBar:
            lines.append(Line(label: "Move", value: "refused, no usable title bar", ok: false))
        case .failed(let reason):
            lines.append(Line(label: "Move", value: "failed: \(reason)", ok: false))
        }

        // Put the window back, whatever happened.
        switch outcome {
        case .movedDirectly, .movedByDrag:
            let back = SpaceMover.move(
                element: candidate.element,
                windowID: candidate.observed.windowID,
                bundleID: candidate.observed.bundleID,
                toSpaceIndex: home,
                targetSpaceID: userSpaces.first { $0.index == home }?.id
            )
            let returned: Bool
            switch back {
            case .movedDirectly, .movedByDrag, .alreadyThere: returned = true
            default: returned = false
            }
            lines.append(Line(
                label: "Returned to desktop \(home)",
                value: returned ? "yes" : "no, please move it back by hand",
                ok: returned
            ))
        default:
            lines.append(Line(
                label: "Clean up",
                value: "nothing to undo, the window never left desktop \(home)",
                ok: nil
            ))
        }

        // And put you back where you were.
        if let nowOn = SkyLight.displaySpaces().first?.currentIndex, nowOn != startedOn {
            SpaceMover.switchToSpace(index: startedOn)
        }

        return Section(title: "Moving between desktops", lines: lines)
    }
}
