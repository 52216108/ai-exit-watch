import Foundation

public struct SavedState: Codable {
    public var settings = WatchSettings()
    public var baseline: Snapshot?
    public var samples: [Snapshot] = []
    public var events: [AlertEvent] = []
    public init() {}
}

public struct Store {
    public let directory: URL
    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NetworkWatch")) { self.directory = directory }
    public func read() throws -> SavedState {
        let file = directory.appendingPathComponent("state.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return SavedState() }
        return try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: file))
    }
    public func write(_ state: SavedState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("state.json")
        let data = try JSONEncoder().encode(state)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
