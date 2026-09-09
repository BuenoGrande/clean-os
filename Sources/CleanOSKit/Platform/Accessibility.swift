import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Reading and writing other apps' windows through the Accessibility API.
///
/// This is the only supported way to move and resize another app's windows, and
/// unlike anything to do with desktops it is not gated: it works on windows that
/// are on other desktops and in apps that are not frontmost. It needs the
/// Accessibility permission, and that permission is tied to the app's code
/// signature, so an unsigned rebuild will be asked for it again.
public enum Accessibility {

    // MARK: Permission

    public static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Check, and optionally show the system prompt that points at the right
    /// pane of System Settings. Returns immediately either way; granting the
    /// permission usually requires the process to be restarted afterwards.
    @discardableResult
    public static func requestTrust(prompt: Bool = true) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: Reading

    /// The windows of one process.
    ///
    /// Filtered to real, standard windows. Without that filter this returns
    /// palettes, sheets and popovers, which should never be repositioned.
    public static func windows(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        guard let raw = copyAttribute(app, kAXWindowsAttribute),
              CFGetTypeID(raw) == CFArrayGetTypeID()
        else { return [] }
        let elements = raw as! [AXUIElement]
        return elements.filter(isStandardWindow)
    }

    public static func isStandardWindow(_ element: AXUIElement) -> Bool {
        guard let role = string(element, kAXRoleAttribute), role == kAXWindowRole else {
            return false
        }
        // A window with no subrole, or a subrole other than the standard one,
        // is a panel or a dialog. Leave those alone.
        guard let subrole = string(element, kAXSubroleAttribute) else { return false }
        return subrole == kAXStandardWindowSubrole
    }

    public static func title(of element: AXUIElement) -> String {
        string(element, kAXTitleAttribute) ?? ""
    }

    public static func isMinimized(_ element: AXUIElement) -> Bool {
        guard let raw = copyAttribute(element, kAXMinimizedAttribute) else { return false }
        return (raw as? Bool) ?? false
    }

    /// Frame in the top-left-origin global space that the Accessibility API and
    /// Core Graphics both use. Note this is not the bottom-left-origin space
    /// that AppKit's NSScreen reports, so the two must never be mixed.
    public static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = point(element, kAXPositionAttribute),
              let size = size(element, kAXSizeAttribute)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    // MARK: Writing

    /// Move and resize a window.
    ///
    /// Position is written, then size, then position again. This looks
    /// superstitious and is not: setting the size while the window is still at
    /// its old origin lets macOS clamp it against the edge of that display, so
    /// the window ends up the wrong size. Writing the origin again afterwards
    /// corrects for apps that nudge themselves during the resize.
    @discardableResult
    public static func setFrame(_ frame: CGRect, on element: AXUIElement) -> Bool {
        let movedFirst = setPoint(frame.origin, element, kAXPositionAttribute)
        let resized = setSize(frame.size, element, kAXSizeAttribute)
        let movedAgain = setPoint(frame.origin, element, kAXPositionAttribute)
        return (movedFirst || movedAgain) && resized
    }

    /// Bring a window to the front within its own app.
    ///
    /// Needed before simulating a drag on it: macOS treats a press on a
    /// background window as a click that activates it, not as the start of a
    /// drag, so without this the first gesture is always consumed.
    @discardableResult
    public static func raise(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success
    }

    public static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
        else { return false }
        return settable.boolValue
    }

    /// True when a window can be moved at all. Windows in native full screen
    /// and windows macOS has tiled refuse position writes until that state is
    /// cleared, and some apps expose no settable geometry whatsoever.
    public static func isMovable(_ element: AXUIElement) -> Bool {
        isSettable(element, kAXPositionAttribute) && isSettable(element, kAXSizeAttribute)
    }

    // MARK: Primitives

    static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copyAttribute(element, attribute) as? String
    }

    static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let raw = copyAttribute(element, attribute),
              CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }
        var result = CGPoint.zero
        guard AXValueGetValue(raw as! AXValue, .cgPoint, &result) else { return nil }
        return result
    }

    static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let raw = copyAttribute(element, attribute),
              CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }
        var result = CGSize.zero
        guard AXValueGetValue(raw as! AXValue, .cgSize, &result) else { return nil }
        return result
    }

    @discardableResult
    static func setPoint(_ value: CGPoint, _ element: AXUIElement, _ attribute: String) -> Bool {
        var mutable = value
        guard let boxed = AXValueCreate(.cgPoint, &mutable) else { return false }
        return AXUIElementSetAttributeValue(element, attribute as CFString, boxed) == .success
    }

    @discardableResult
    static func setSize(_ value: CGSize, _ element: AXUIElement, _ attribute: String) -> Bool {
        var mutable = value
        guard let boxed = AXValueCreate(.cgSize, &mutable) else { return false }
        return AXUIElementSetAttributeValue(element, attribute as CFString, boxed) == .success
    }
}
