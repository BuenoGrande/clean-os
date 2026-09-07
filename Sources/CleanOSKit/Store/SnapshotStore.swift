import Foundation

/// Where recordings live on disk.
///
/// Plain JSON files in a folder you can open, not a database and not the
/// preferences system. A recording is something you should be able to read,
/// hand-edit, diff and keep in version control, because it is a description of
/// how you work rather than an internal detail of the app.
public struct SnapshotStore {

    public let root: URL

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/clean-os", isDirectory: true)
    }

    public var snapshotsDirectory: URL { root.appendingPathComponent("snapshots", isDirectory: true) }
    public var undoDirectory: URL { root.appendingPathComponent("undo", isDirectory: true) }
    public var logURL: URL { root.appendingPathComponent("log.jsonl") }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Sorted and indented so that two recordings of the same setup produce
        // the same bytes, which makes the files diffable.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: Recordings

    public func save(_ snapshot: Snapshot) throws {
        try FileManager.default.createDirectory(at: snapshotsDirectory, withIntermediateDirectories: true)
        let url = snapshotsDirectory.appendingPathComponent("\(snapshot.profileKey).json")
        try Self.encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    public func loadAll() throws -> [Snapshot] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: snapshotsDirectory.path) else { return [] }
        let urls = try manager.contentsOfDirectory(at: snapshotsDirectory, includingPropertiesForKeys: nil)
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? Self.decoder.decode(Snapshot.self, from: data)
            }
    }

    public func url(forProfile key: String) -> URL {
        snapshotsDirectory.appendingPathComponent("\(key).json")
    }

    // MARK: Undo

    /// Keep the state from just before a restore, so the restore can be taken
    /// back. Written before anything moves, never after.
    public func saveUndo(_ snapshot: Snapshot) throws {
        try FileManager.default.createDirectory(at: undoDirectory, withIntermediateDirectories: true)
        let url = undoDirectory.appendingPathComponent("\(snapshot.profileKey).json")
        try Self.encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    public func loadUndo(profileKey: String) throws -> Snapshot? {
        let url = undoDirectory.appendingPathComponent("\(profileKey).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try Self.decoder.decode(Snapshot.self, from: data)
    }

    // MARK: Log

    /// Append a line to the record of everything the tool has seen.
    ///
    /// One JSON object per line, appended and flushed immediately. This is the
    /// backstop behind the promise that nothing gets lost: whatever else goes
    /// wrong, what was on screen was written down first.
    public func appendLog(_ entry: [String: Any]) {
        var payload = entry
        payload["at"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line.append("\n")

        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
        // Flushed rather than left to the system, because the point of this
        // file is to survive whatever happens next.
        try? handle.synchronize()
    }
}
