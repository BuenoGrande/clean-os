import CleanOSKit
import Foundation

let version = "0.1.0"

let usage = """
cleanos \(version) — record and replay a clean Mac window setup

  cleanos probe [--try-move]     check what works on this Mac
  cleanos record [name]          record the current arrangement
       [--no-sweep]              record only the visible desktop
  cleanos restore [--dry-run]    put the windows back
  cleanos undo                   take back the last restore
  cleanos list                   show recordings
  cleanos path                   print where recordings are kept

Start with probe. It changes nothing unless you pass --try-move.
"""

func symbol(_ ok: Bool?) -> String {
    switch ok {
    case .some(true): return "ok  "
    case .some(false): return "FAIL"
    case .none: return "  - "
    }
}

let store = SnapshotStore()
var arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "help"
arguments = Array(arguments.dropFirst())
let flags = Set(arguments.filter { $0.hasPrefix("--") })
let words = arguments.filter { !$0.hasPrefix("--") }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

switch command {

case "probe":
    if !Accessibility.isTrusted {
        // Ask once, so the first run points at the right settings pane rather
        // than just reporting a failure.
        Accessibility.requestTrust(prompt: true)
    }
    for section in Probe.run(includeMoveTest: flags.contains("--try-move")) {
        print("\n\(section.title)")
        print(String(repeating: "-", count: section.title.count))
        for line in section.lines {
            print("  \(symbol(line.ok)) \(line.label): \(line.value)")
        }
    }
    print("")

case "record":
    let recorder = Recorder(store: store, appVersion: version)
    do {
        let result = try recorder.record(
            name: words.first ?? "clean",
            sweep: !flags.contains("--no-sweep")
        )
        print("Recorded \(result.snapshot.placements.count) window(s) across \(result.snapshot.displays.count) monitor(s).")
        if result.sweptSpaces > 0 {
            print("Visited \(result.sweptSpaces) desktop(s).")
        }
        for note in result.notes {
            print("Note: \(note)")
        }
        print("Written to \(result.url.path)")
    } catch {
        fail("\(error)")
    }

case "restore":
    let restorer = Restorer(store: store, appVersion: version)
    do {
        let report = try restorer.restore(dryRun: flags.contains("--dry-run"))
        print("\(report.dryRun ? "Would restore" : "Restored") \(report.profileName) — \(report.matchedMonitors)")
        for line in report.applied {
            print("  \(line)")
        }
        if !report.problems.isEmpty {
            print("\nLeft alone:")
            for problem in report.problems {
                print("  \(problem)")
            }
        }
        if report.applied.isEmpty && report.problems.isEmpty {
            print("  everything was already in place")
        }
    } catch {
        fail("\(error)")
    }

case "undo":
    let restorer = Restorer(store: store, appVersion: version)
    do {
        let report = try restorer.undo()
        if report.applied.isEmpty {
            print("Nothing to undo.")
        } else {
            for line in report.applied {
                print("  \(line)")
            }
        }
    } catch {
        fail("\(error)")
    }

case "list":
    do {
        let snapshots = try store.loadAll()
        if snapshots.isEmpty {
            print("No recordings yet. Arrange your windows, then run: cleanos record")
        }
        let currentKey = Displays.current().key
        for snapshot in snapshots.sorted(by: { $0.createdAt > $1.createdAt }) {
            let marker = snapshot.profileKey == currentKey ? "*" : " "
            print("\(marker) \(snapshot.name) — \(snapshot.placements.count) window(s), \(snapshot.displays.count) monitor(s), recorded \(snapshot.createdAt)")
            for display in snapshot.displays {
                print("      \(display.name)")
            }
        }
        if !snapshots.isEmpty {
            print("\n* matches the monitors attached now")
        }
    } catch {
        fail("\(error)")
    }

case "path":
    print(store.root.path)

default:
    print(usage)
}
