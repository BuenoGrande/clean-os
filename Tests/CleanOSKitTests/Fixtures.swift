import CoreGraphics
import Foundation
@testable import CleanOSKit

enum Fixtures {

    static func display(
        uuid: String,
        name: String = "Monitor",
        vendor: UInt32 = 1,
        model: UInt32 = 1,
        serial: UInt32 = 0,
        isMain: Bool = false,
        origin: CGPoint = .zero,
        size: CGSize = CGSize(width: 1920, height: 1080)
    ) -> DisplayInfo {
        let frame = CGRect(origin: origin, size: size)
        return DisplayInfo(
            uuid: uuid,
            name: name,
            vendor: vendor,
            model: model,
            serial: serial,
            isMain: isMain,
            frame: frame,
            visibleFrame: frame.insetBy(dx: 0, dy: 12)
        )
    }

    static func window(
        id: UInt32,
        bundleID: String,
        title: String = "",
        frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600),
        displayUUID: String? = "A",
        spaceIndex: Int? = 1,
        minimized: Bool = false
    ) -> ObservedWindow {
        ObservedWindow(
            windowID: id,
            pid: 1,
            bundleID: bundleID,
            title: title,
            frame: frame,
            displayUUID: displayUUID,
            spaceIndex: spaceIndex,
            isMinimized: minimized
        )
    }

    static func placement(
        bundleID: String,
        titleRegex: String? = nil,
        ordinal: Int = 0,
        displayUUID: String = "A",
        spaceIndex: Int? = 1,
        rect: UnitRect = .leftHalf,
        launchIfMissing: Bool = true
    ) -> Placement {
        Placement(
            match: WindowMatch(bundleID: bundleID, titleRegex: titleRegex, ordinal: ordinal),
            target: PlacementTarget(displayUUID: displayUUID, spaceIndex: spaceIndex, unitRect: rect),
            launchIfMissing: launchIfMissing
        )
    }

    static func snapshot(
        name: String = "clean",
        displays: [DisplayInfo],
        placements: [Placement] = [],
        createdAt: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> Snapshot {
        Snapshot(
            profileKey: DisplaySet(displays: displays).key,
            name: name,
            createdAt: createdAt,
            displays: displays,
            placements: placements,
            provenance: Snapshot.Provenance(
                osVersion: "test",
                appVersion: "test",
                sweptAllSpaces: true
            )
        )
    }
}
