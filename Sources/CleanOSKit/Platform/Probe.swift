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
        sections.append(Section(title: "Windows", lines: [
            Line(label: "Readable windows", value: "\(windows.count)", ok: !windows.isEmpty),
            Line(
                label: "Located on a desktop",
                value: "\(located) of \(windows.count)",
                ok: windows.isEmpty ? nil : located > 0
            ),
        ]))

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
    /// Uses a window belonging to this tool's own caller where possible and
    /// otherwise the frontmost ordinary window, and always attempts to return
    /// it. Apps whose title bar is a tab strip are skipped, because the drag
    /// would tear out a tab.
    static func moveTest(displays: DisplaySet, windows: [Capturer.CapturedWindow]) -> Section {
        guard let group = SkyLight.displaySpaces().first(where: { $0.spaces.filter(\.isUserSpace).count > 1 }),
              let currentIndex = group.currentIndex
        else {
            return Section(title: "Moving between desktops", lines: [
                Line(
                    label: "Skipped",
                    value: "There is only one desktop, so there is nowhere to move a window to. Add a second desktop in Mission Control and run this again.",
                    ok: nil
                ),
            ])
        }

        let userSpaces = group.spaces.filter(\.isUserSpace)
        guard let target = userSpaces.first(where: { $0.index != currentIndex }) else {
            return Section(title: "Moving between desktops", lines: [
                Line(label: "Skipped", value: "Could not find a second desktop to aim at.", ok: nil),
            ])
        }

        let candidate = windows.first { window in
            window.observed.spaceIndex == currentIndex
                && !SpaceMover.tabStripApps.contains(window.observed.bundleID)
                && !window.observed.isMinimized
                && Accessibility.isMovable(window.element)
        }

        guard let candidate else {
            return Section(title: "Moving between desktops", lines: [
                Line(
                    label: "Skipped",
                    value: "No suitable window on this desktop. Open something with an ordinary title bar, not a browser or a terminal, and run this again.",
                    ok: nil
                ),
            ])
        }

        var lines: [Line] = [
            Line(label: "Test window", value: "\(candidate.observed.bundleID) on desktop \(currentIndex)"),
        ]

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
            lines.append(Line(
                label: "Move",
                value: "failed: \(reason). Desktop support will not work on this machine as built.",
                ok: false
            ))
        }

        // Put it back, whatever happened.
        let back = SpaceMover.move(
            element: candidate.element,
            windowID: candidate.observed.windowID,
            bundleID: candidate.observed.bundleID,
            toSpaceIndex: currentIndex,
            targetSpaceID: group.spaces.first { $0.index == currentIndex }?.id
        )
        let returned: Bool
        switch back {
        case .movedDirectly, .movedByDrag, .alreadyThere: returned = true
        default: returned = false
        }
        lines.append(Line(
            label: "Returned to desktop \(currentIndex)",
            value: returned ? "yes" : "no, please move it back by hand",
            ok: returned
        ))

        return Section(title: "Moving between desktops", lines: lines)
    }
}
