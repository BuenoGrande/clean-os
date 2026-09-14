import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import ObjectiveC

/// Bindings to the private window-server functions that expose desktops.
///
/// Apple ships no public API for desktops, so everything here is undocumented.
/// Two rules follow from that and are enforced by the design of this type.
///
/// Every symbol is looked up at runtime rather than linked, and every entry
/// point returns an optional or a failure rather than trapping, so that a macOS
/// release which removes or renames one of these degrades the app to
/// geometry-only instead of crashing it.
///
/// Reads and writes are not equally available. Reading which desktop a window
/// is on works from an ordinary app. Writing does not: since macOS 14.5 the
/// window server checks whether the caller owns the window before honouring a
/// desktop move, and for another app's window it silently does nothing while
/// still reporting success. So `moveWindows` here is offered as an attempt to
/// be verified, never as something to be trusted, and the real move lives in
/// `SpaceMover`.
public enum SkyLight {

    // MARK: Symbol resolution

    private static let skyLightHandle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        RTLD_LAZY
    )

    /// Search every loaded image, which is where the accessibility private
    /// symbol lives.
    private static let anyImage = UnsafeMutableRawPointer(bitPattern: -2)

    private static func symbol(_ name: String, in handle: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
        guard let handle else { return nil }
        return dlsym(handle, name)
    }

    private typealias MainConnectionIDFn = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias MoveWindowsToManagedSpaceFn = @convention(c) (Int32, CFArray, UInt64) -> Void
    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError

    private static let mainConnectionID: MainConnectionIDFn? = symbol("SLSMainConnectionID", in: skyLightHandle)
        .map { unsafeBitCast($0, to: MainConnectionIDFn.self) }

    private static let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn? =
        symbol("SLSCopyManagedDisplaySpaces", in: skyLightHandle)
            .map { unsafeBitCast($0, to: CopyManagedDisplaySpacesFn.self) }

    private static let copySpacesForWindows: CopySpacesForWindowsFn? =
        symbol("SLSCopySpacesForWindows", in: skyLightHandle)
            .map { unsafeBitCast($0, to: CopySpacesForWindowsFn.self) }

    private static let moveWindowsToManagedSpace: MoveWindowsToManagedSpaceFn? =
        symbol("SLSMoveWindowsToManagedSpace", in: skyLightHandle)
            .map { unsafeBitCast($0, to: MoveWindowsToManagedSpaceFn.self) }

    private static let getWindow: GetWindowFn? = symbol("_AXUIElementGetWindow", in: anyImage)
        .map { unsafeBitCast($0, to: GetWindowFn.self) }

    // MARK: The bridged move, which is the newer path
    //
    // The function above stopped working on another app's window in macOS 14.5,
    // when the window server began checking whether the caller owns the window.
    // Apple's own window management kept working, through a different shape:
    // instead of calling a function that mutates a window, you describe the
    // move as an operation object and ask the window server to perform it. That
    // path is not subject to the ownership check.
    //
    // Everything about it is discovered at runtime, because none of it is
    // declared anywhere we can see, and because the function has internal
    // linkage, which normally makes a symbol unreachable. Three spellings are
    // tried and the probe reports which, if any, resolved.

    private static let bridgedOperationClass: AnyClass? =
        NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation")

    private static let objcMsgSend: UnsafeMutableRawPointer? = dlsym(anyImage, "objc_msgSend")

    private static let bridgedSymbolCandidates = [
        "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation",
        "_ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation",
        "SLSPerformAsynchronousBridgedWindowManagementOperation",
    ]

    /// Which spelling of the perform function resolved, if any. Reported by the
    /// probe, because it is the first thing to check when this stops working.
    public static let bridgedSymbolSpelling: String? = bridgedSymbolCandidates.first {
        symbol($0, in: skyLightHandle) != nil || symbol($0, in: anyImage) != nil
    }

    private typealias PerformBridgedFn = @convention(c) (UnsafeMutableRawPointer) -> Int64

    private static let performBridged: PerformBridgedFn? = {
        guard let name = bridgedSymbolSpelling else { return nil }
        let pointer = symbol(name, in: skyLightHandle) ?? symbol(name, in: anyImage)
        return pointer.map { unsafeBitCast($0, to: PerformBridgedFn.self) }
    }()

    private static let bridgedInitSelector = sel_getUid("initWithWindows:spaceID:")

    public static var isBridgedMoveAvailable: Bool {
        guard let cls = bridgedOperationClass, performBridged != nil, objcMsgSend != nil
        else { return false }
        return class_getInstanceMethod(cls, bridgedInitSelector) != nil
    }

    /// Ask the window server to move windows to a desktop, the way its own
    /// window management does.
    ///
    /// Returns whether the operation was submitted, which is not the same as
    /// done: the operation is asynchronous, so the caller must confirm by
    /// re-reading where the window actually ended up.
    ///
    /// The operation is built through the Objective-C runtime with raw pointers
    /// and is deliberately never released. Swift cannot type a dynamic call
    /// mixing an object and a sixty-four bit integer, and handing an object it
    /// knows nothing about to automatic memory management risks freeing it
    /// while the window server is still working on it. One small leak per move
    /// is the better trade.
    @discardableResult
    public static func attemptBridgedMove(windowIDs: [UInt32], toSpace spaceID: UInt64) -> Bool {
        guard isBridgedMoveAvailable,
              let cls = bridgedOperationClass,
              let perform = performBridged,
              let msgSend = objcMsgSend
        else { return false }

        let allocate = unsafeBitCast(
            msgSend,
            to: (@convention(c) (AnyClass, Selector) -> UnsafeMutableRawPointer?).self
        )
        guard let allocated = allocate(cls, sel_getUid("alloc")) else { return false }

        let initialise = unsafeBitCast(
            msgSend,
            to: (@convention(c) (UnsafeMutableRawPointer, Selector, NSArray, UInt64) -> UnsafeMutableRawPointer?).self
        )
        let windows = windowIDs.map { NSNumber(value: $0) } as NSArray
        guard let operation = initialise(allocated, bridgedInitSelector, windows, spaceID)
        else { return false }

        _ = perform(operation)
        return true
    }

    /// Which of the private pieces are present on this machine. The probe
    /// command prints this, and it is the first thing to look at when desktop
    /// support stops working after a macOS update.
    public static var availability: [String: Bool] {
        [
            "SkyLight.framework": skyLightHandle != nil,
            "SLSMainConnectionID": mainConnectionID != nil,
            "SLSCopyManagedDisplaySpaces": copyManagedDisplaySpaces != nil,
            "SLSCopySpacesForWindows": copySpacesForWindows != nil,
            "SLSMoveWindowsToManagedSpace": moveWindowsToManagedSpace != nil,
            "_AXUIElementGetWindow": getWindow != nil,
            "SLSBridgedMoveWindowsToManagedSpaceOperation": bridgedOperationClass != nil,
            "SLSPerformAsynchronousBridgedWindowManagementOperation": performBridged != nil,
            "bridged move usable": isBridgedMoveAvailable,
        ]
    }

    public static var isAvailable: Bool {
        mainConnectionID != nil && copyManagedDisplaySpaces != nil && copySpacesForWindows != nil
    }

    public static var connectionID: Int32? {
        mainConnectionID?()
    }

    // MARK: Window identity

    /// The window server's identifier for an accessibility window element.
    ///
    /// This is the only bridge between the two worlds, and it is needed because
    /// everything to do with desktops is expressed in window-server identifiers
    /// while everything to do with geometry is expressed in accessibility
    /// elements.
    public static func windowID(of element: AXUIElement) -> UInt32? {
        guard let getWindow else { return nil }
        var identifier: UInt32 = 0
        guard getWindow(element, &identifier) == .success else { return nil }
        return identifier
    }

    // MARK: Desktops

    public struct Space: Equatable, Sendable {
        /// The window server's identifier for this desktop. Stable while the
        /// machine is up; not across reboots.
        public var id: UInt64
        /// Position within its display, one-based. This is what a recording
        /// stores, because it is what the Mission Control keystrokes address.
        public var index: Int
        /// 0 is an ordinary desktop. 4 is the pseudo-desktop macOS creates for
        /// a full-screen or tiled window, which is not somewhere windows can be
        /// placed.
        public var type: Int

        public var isUserSpace: Bool { type == 0 }

        public init(id: UInt64, index: Int, type: Int) {
            self.id = id
            self.index = index
            self.type = type
        }
    }

    public struct DisplaySpaces: Equatable, Sendable {
        /// The display UUID, or "Main" when macOS reports it that way, which it
        /// does when Displays have separate Spaces is switched off.
        public var displayIdentifier: String
        public var spaces: [Space]
        public var currentSpaceID: UInt64?

        public init(displayIdentifier: String, spaces: [Space], currentSpaceID: UInt64?) {
            self.displayIdentifier = displayIdentifier
            self.spaces = spaces
            self.currentSpaceID = currentSpaceID
        }

        public var currentIndex: Int? {
            guard let currentSpaceID else { return nil }
            return spaces.first { $0.id == currentSpaceID }?.index
        }
    }

    /// Every desktop, grouped by the display that owns it.
    public static func displaySpaces() -> [DisplaySpaces] {
        guard let connectionID = mainConnectionID?(),
              let copy = copyManagedDisplaySpaces,
              let raw = copy(connectionID)?.takeRetainedValue() as? [[String: Any]]
        else { return [] }

        return raw.compactMap { entry in
            guard let identifier = entry["Display Identifier"] as? String else { return nil }
            let spaceDicts = entry["Spaces"] as? [[String: Any]] ?? []

            var index = 0
            let spaces: [Space] = spaceDicts.compactMap { dict in
                guard let id = spaceID(from: dict) else { return nil }
                let type = (dict["type"] as? Int) ?? 0
                // Full-screen pseudo-desktops sit in this list but are not
                // numbered by the Mission Control shortcuts, so they must not
                // consume an index.
                guard type == 0 else { return Space(id: id, index: 0, type: type) }
                index += 1
                return Space(id: id, index: index, type: type)
            }

            let current = (entry["Current Space"] as? [String: Any]).flatMap(spaceID(from:))
            return DisplaySpaces(
                displayIdentifier: identifier,
                spaces: spaces,
                currentSpaceID: current
            )
        }
    }

    /// The key holding a desktop's identifier has been spelled both ways across
    /// macOS versions, so try both rather than depending on one.
    private static func spaceID(from dict: [String: Any]) -> UInt64? {
        if let value = dict["id64"] as? UInt64 { return value }
        if let value = dict["id64"] as? Int { return UInt64(value) }
        if let value = dict["ManagedSpaceID"] as? UInt64 { return value }
        if let value = dict["ManagedSpaceID"] as? Int { return UInt64(value) }
        return nil
    }

    /// Which desktops a window is on. Ordinarily one, but a window set to
    /// appear on every desktop reports many.
    public static func spaceIDs(forWindow windowID: UInt32) -> [UInt64] {
        guard let connectionID = mainConnectionID?(), let copy = copySpacesForWindows
        else { return [] }
        let windows = [NSNumber(value: windowID)] as CFArray
        // 0x7 asks about every desktop rather than just the visible one.
        guard let raw = copy(connectionID, 0x7, windows)?.takeRetainedValue() as? [NSNumber]
        else { return [] }
        return raw.map { $0.uint64Value }
    }

    /// Ask the window server directly to move windows to a desktop.
    ///
    /// Expected to do nothing for another app's window on macOS 14.5 and later,
    /// while reporting no error. It is attempted anyway because it costs
    /// nothing, it is instant when it does work, and the result is always
    /// verified by reading back where the window actually ended up.
    public static func attemptMove(windowIDs: [UInt32], toSpace spaceID: UInt64) {
        guard let connectionID = mainConnectionID?(), let move = moveWindowsToManagedSpace
        else { return }
        let windows = windowIDs.map { NSNumber(value: $0) } as CFArray
        move(connectionID, windows, spaceID)
    }
}
