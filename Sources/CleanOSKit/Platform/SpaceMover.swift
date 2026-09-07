import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Moving windows between desktops, and switching desktops.
///
/// The window server will not move another app's window between desktops on
/// request, so this works the way a person does: it presses the mouse on the
/// window's title bar, holds it, presses the Mission Control shortcut for the
/// target desktop, and lets go. macOS performs its own move, so nothing is
/// bypassed and no system protection is weakened.
///
/// The cost is that this is a physical simulation and behaves like one. It takes
/// most of a second, it visibly borrows the cursor, and it can fail. Every move
/// is therefore verified by reading back where the window actually ended up.
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
    /// than attempted, and reported so you can place them by hand or assign
    /// them to a desktop in System Settings.
    ///
    /// Override per app in configuration once you have checked where that app's
    /// title bar is actually safe to grab.
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

    /// Where on the title bar to press, as a fraction across the window.
    /// The middle is usually empty. Away from the left, which is where the
    /// close, minimise and zoom buttons live.
    public static var grabFraction: CGFloat = 0.5
    public static var titleBarInset: CGFloat = 8

    // MARK: Switching

    /// Go to a desktop by its number, using the same keystroke you would press.
    ///
    /// Only desktops one to nine can be addressed this way, and only when those
    /// shortcuts are enabled in System Settings, which they are not by default.
    @discardableResult
    public static func switchToSpace(index: Int, settleFor seconds: Double = 0.45) -> Bool {
        guard let key = digitKeyCode(index) else { return false }
        postKey(key, flags: .maskControl)
        Thread.sleep(forTimeInterval: seconds)
        return true
    }

    // MARK: Moving

    /// Move one window to a desktop, verifying the result.
    ///
    /// The window must be on the desktop currently being displayed, because the
    /// drag operates on what is on screen.
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

        drag(frame: frame, digitKey: key)

        if let targetSpaceID {
            let landed = SkyLight.spaceIDs(forWindow: windowID).contains(targetSpaceID)
            return landed ? .movedByDrag : .failed("drag completed but the window did not arrive")
        }
        return .movedByDrag
    }

    /// Press the title bar, switch desktop while holding, let go.
    private static func drag(frame: CGRect, digitKey: CGKeyCode) {
        let grab = CGPoint(
            x: frame.minX + frame.width * grabFraction,
            y: frame.minY + titleBarInset
        )
        let cursorBefore = CGEvent(source: nil)?.location

        postMouse(.leftMouseDown, at: grab)
        Thread.sleep(forTimeInterval: 0.08)

        // A press alone is not a drag. Move a few pixels so macOS starts one,
        // in small steps because a single jump is sometimes not recognised.
        for offset in stride(from: CGFloat(4), through: 12, by: 4) {
            postMouse(.leftMouseDragged, at: CGPoint(x: grab.x + offset, y: grab.y))
            Thread.sleep(forTimeInterval: 0.02)
        }

        postKey(digitKey, flags: .maskControl)
        // Wait out the desktop switch animation before letting go, or the
        // window is dropped in mid-transition and stays where it was.
        Thread.sleep(forTimeInterval: 0.65)

        postMouse(.leftMouseDragged, at: CGPoint(x: grab.x + 12, y: grab.y))
        Thread.sleep(forTimeInterval: 0.05)
        postMouse(.leftMouseUp, at: CGPoint(x: grab.x + 12, y: grab.y))
        Thread.sleep(forTimeInterval: 0.25)

        if let cursorBefore {
            CGWarpMouseCursorPosition(cursorBefore)
        }
    }

    // MARK: Event plumbing

    private static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.03)
        if let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }

    private static func postMouse(_ type: CGEventType, at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(
            mouseEventSource: source,
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
