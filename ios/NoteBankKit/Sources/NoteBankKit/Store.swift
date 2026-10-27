import Foundation
import GRDB

public enum StoreError: Error, Equatable, LocalizedError {
    case noAppGroup

    public var errorDescription: String? { "This app isn't set up to use its App Group container." }
}

public final class Store: Sendable {
    public let pool: DatabasePool

    public init(at file: URL) throws {
        var directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        try directory.setResourceValues(excluded)

        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.observesSuspensionNotifications = true
        configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
        pool = try DatabasePool(path: file.path, configuration: configuration)

        try DatabaseMigrator.noteBank.migrate(pool)
        try pool.write { db in
            try db.execute(
                sql: "INSERT INTO device (id, device_id) SELECT 1, ? WHERE NOT EXISTS (SELECT 1 FROM device)",
                arguments: [UUID().uuidString.lowercased()])
        }
    }

    public static func appGroupFile() throws -> URL {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.app.notebank") else {
            throw StoreError.noAppGroup
        }
        return container.appending(path: "Library/Application Support/NoteBank/notebank.db")
    }

    public func deviceID() throws -> String {
        try pool.read { try String.fetchOne($0, sql: "SELECT device_id FROM device")! }
    }
}
