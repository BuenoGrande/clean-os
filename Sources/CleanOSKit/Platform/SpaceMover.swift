import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Moving windows between desktops, and switching desktops.
///
/// The window server will not move another app's window between desktops on
/// request, so this works the way a person does: it puts the pointer on the
/// window's title bar, presses, picks the window up, presses the Mission
/// Control shortcut for the target desktop while still holding, and lets go.
/// macOS performs its own move, so nothing is bypassed and no system
/// protection is weakened.
///
/// Being a simulation of a physical gesture, it is fussy in ways a normal API
/// is not. Four things all have to be true or macOS quietly declines to treat
/// the events as a window drag: the real pointer has to be where the events
/// claim it is, the window has to be frontmost, the pointer has to travel far
/// enough to pass the pick-up threshold, and events have to keep arriving for
/// the whole gesture. Getting any of them wrong looks identical from the
/// outside, which is why failures here report which stage broke.
public enum SpaceMover {

    public enum Outcome: Equatable, Sendable {
        case alreadyThere
        case movedDirectly
        case movedByDrag
        /// Refused on purpose. The title bar of this app is a tab strip, and
        /// dragging it would tear out a tab rather than move the window.
        case refusedTabStrip(bundleID: String)
        case refusedNoTitleBar
        case failed(String)
    }

    /// Apps whose title bar is a row of tabs.
    ///
    /// Grabbing the title bar of one of these does not move the window, it
    /// tears out a tab, which loses whatever was in it. Since not losing
    /// anything is the whole promise of this tool, these are refused rather
    /// than attempted, and reported so you can place them another way.
    public static let tabStripApps: Set<String> = [
        "com.brave.Browser",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "com.apple.Safari",
        "company.thebrowser.Browser",
        "company.thebrowser.dia",
        "org.mozilla.firefox",
        "com.googlecode.iterm2",
        "com.apple.Terminal",
    ]

    // MARK: Tuning
    //
    // Every number here was guessed and has to survive contact with a real
    // machine, so each is overridable from the environment. That way a timing
    // problem can be diagnosed by trying values rather than by rebuilding.

    /// Where along the title bar to press, as a fraction of window width.
    /// The middle is usually empty; the left end holds the window buttons.
    public static var grabFraction: CGFloat { CGFloat(number("CLEANOS_GRAB", 0.5)) }
    /// How far below the top of the window the title bar sits.
    public static var titleBarInset: CGFloat { CGFloat(number("CLEANOS_INSET", 8)) }
    /// How long to keep the gesture alive after asking for the desktop switch.
    static var holdSeconds: Double { number("CLEANOS_HOLD", 1.1) }
    /// How long a plain desktop switch takes to settle.
    static var settleSeconds: Double { number("CLEANOS_SETTLE", 0.45) }

    static func number(_ name: String, _ fallback: Double) -> Double {
        guard let raw = ProcessInfo.processInfo.environment[name], let value = Double(raw)
        else { return fallback }
        return value
    }

    private static let eventSource = CGEventSource(stateID: .hidSystemState)
    private static let controlKey: CGKeyCode = 0x3B

    // MARK: Switching

    /// Go to a desktop by its number, using the same keystroke you would press.
    ///
    /// Only desktops one to nine can be addressed this way, and only when those
    /// shortcuts are enabled in System Settings, which they are not by default.
    @discardableResult
    public static func switchToSpace(index: Int, settleFor seconds: Double? = nil) -> Bool {
        guard let key = digitKeyCode(index) else { return false }
        tapKey(key)
        Thread.sleep(forTimeInterval: seconds ?? settleSeconds)
        return true
    }

    /// Which desktop each monitor is currently showing.
    ///
    /// Used to tell "the keystroke was ignored" apart from "the desktop
    /// switched but the window did not come along", which need opposite fixes.
    public static func activeSpaceIDs() -> [UInt64] {
        SkyLight.displaySpaces().compactMap(\.currentSpaceID)
    }

    // MARK: Moving

    /// Move one window to a desktop, verifying the result.
    ///
    /// The window must be on the desktop currently being displayed, because the
    /// gesture operates on what is on screen.
    public static func move(
        element: AXUIElement,
        windowID: UInt32,
        bundleID: String,
        toSpaceIndex index: Int,
        targetSpaceID: UInt64?
    ) -> Outcome {
        if let targetSpaceID, SkyLight.spaceIDs(forWindow: windowID).contains(targetSpaceID) {
            return .alreadyThere
        }

        // Ask the window server directly first. It is instant when it works,
        // and it reports success whether or not it did anything, which is why
        // the result is checked rather than believed.
        if let targetSpaceID {
            SkyLight.attemptMove(windowIDs: [windowID], toSpace: targetSpaceID)
            Thread.sleep(forTimeInterval: 0.12)
            if SkyLight.spaceIDs(forWindow: windowID).contains(targetSpaceID) {
                return .movedDirectly
            }
        }

        if tabStripApps.contains(bundleID) {
            return .refusedTabStrip(bundleID: bundleID)
        }
        guard let frame = Accessibility.frame(of: element), frame.height > 30, frame.width > 60 else {
            return .refusedNoTitleBar
        }
        guard let key = digitKeyCode(index) else {
            return .failed("desktop \(index) has no keyboard shortcut; only 1 to 9 can be addressed")
        }

        let before = activeSpaceIDs()
        drag(frame: frame, digitKey: key, element: element, bundleID: bundleID)
        let switched = activeSpaceIDs() != before

        guard let targetSpaceID else { return .movedByDrag }
        if SkyLight.spaceIDs(forWindow: windowID).contains(targetSpaceID) {
            return .movedByDrag
        }
        if !switched {
            return .failed(
                "the desktop never switched, so the keystroke was swallowed while the mouse was held. Check that the shortcut for desktop \(index) is enabled and that nothing else claims Control plus a number."
            )
        }
        return .failed(
            "the desktop switched but the window stayed behind, so macOS did not accept the press as a window drag. This app's title bar may not be draggable where we pressed. Try CLEANOS_GRAB=0.25 or CLEANOS_INSET=14, or a longer CLEANOS_HOLD."
        )
    }

    /// Pick the window up, switch desktop while holding it, put it down.
    private static func drag(
        frame: CGRect,
        digitKey: CGKeyCode,
        element: AXUIElement,
        bundleID: String
    ) {
        let grab = CGPoint(
            x: frame.minX + frame.width * grabFraction,
            y: frame.minY + titleBarInset
        )
        let cursorBefore = CGEvent(source: nil)?.location

        // Bring the window forward. A background window does not respond to a
        // title bar drag the way the frontmost one does.
        let owner = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first
        if #available(macOS 14.0, *) {
            owner?.activate()
        } else {
            owner?.activate(options: [])
        }
        Accessibility.raise(element)
        Thread.sleep(forTimeInterval: 0.2)

        // Put the real pointer on the title bar. macOS tracks the physical
        // cursor as well as the coordinates carried by each event, and a drag
        // whose events disagree with where the pointer actually is does not
        // engage at all.
        CGWarpMouseCursorPosition(grab)
        postMouse(.mouseMoved, at: grab)
        Thread.sleep(forTimeInterval: 0.06)

        postMouse(.leftMouseDown, at: grab)
        Thread.sleep(forTimeInterval: 0.14)

        // Actually pick the window up. A dozen pixels is below the distance at
        // which macOS decides a window is being dragged rather than clicked,
        // and the steps are small because one large jump reads as a teleport.
        var point = grab
        for _ in 0..<12 {
            point.x += 4
            point.y += 3
            postMouse(.leftMouseDragged, at: point)
            Thread.sleep(forTimeInterval: 0.015)
        }

        // Hold Control down as a key in its own right rather than only
        // stamping the flag onto the digit, because the handoff to Mission
        // Control watches the modifier being held.
        postKey(controlKey, down: true, flags: .maskControl)
        Thread.sleep(forTimeInterval: 0.06)
        postKey(digitKey, down: true, flags: .maskControl)
        Thread.sleep(forTimeInterval: 0.06)
        postKey(digitKey, down: false, flags: .maskControl)

        // Keep the gesture alive across the switch animation. If no events
        // arrive macOS considers the drag over and leaves the window behind,
        // which is the single most likely reason for a silent failure.
        let deadline = Date().addingTimeInterval(holdSeconds)
        while Date() < deadline {
            postMouse(.leftMouseDragged, at: point)
            Thread.sleep(forTimeInterval: 0.04)
        }

        postKey(controlKey, down: false, flags: [])
        Thread.sleep(forTimeInterval: 0.06)
        postMouse(.leftMouseUp, at: point)
        Thread.sleep(forTimeInterval: 0.3)

        if let cursorBefore {
            CGWarpMouseCursorPosition(cursorBefore)
        }
    }

    // MARK: Event plumbing

    private static func tapKey(_ keyCode: CGKeyCode) {
        postKey(controlKey, down: true, flags: .maskControl)
        Thread.sleep(forTimeInterval: 0.03)
        postKey(keyCode, down: true, flags: .maskControl)
        Thread.sleep(forTimeInterval: 0.03)
        postKey(keyCode, down: false, flags: .maskControl)
        postKey(controlKey, down: false, flags: [])
    }

    private static func postKey(_ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: down)
        else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private static func postMouse(_ type: CGEventType, at point: CGPoint) {
        CGEvent(
            mouseEventSource: eventSource,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
    }

    /// Virtual key codes for the number row. Deliberately a lookup rather than
    /// arithmetic: the codes are not in numeric order, five and six are
    /// swapped, and so are seven and eight.
    static func digitKeyCode(_ digit: Int) -> CGKeyCode? {
        switch digit {
        case 1: return 0x12
        case 2: return 0x13
        case 3: return 0x14
        case 4: return 0x15
        case 5: return 0x17
        case 6: return 0x16
        case 7: return 0x1A
        case 8: return 0x1C
        case 9: return 0x19
        default: return nil
        }
    }
}
