import Foundation
import GRDB
import Synchronization

public enum StoreError: Error, Equatable, LocalizedError {
    case noAppGroup

    public var errorDescription: String? { "This app isn't set up to use its App Group container." }
}

public final class Store: Sendable {
    public let pool: DatabasePool
    public let directory: URL
    private let fileAccess = Mutex(false)

    public init(at file: URL) throws {
        var directory = file.deletingLastPathComponent()
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        #endif
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
        try recoverAttachmentFiles()
    }

    public func suspendFileDatabaseAccess() {
        fileAccess.withLock { suspended in
            suspended = true
            NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
        }
    }

    public func resumeFileDatabaseAccess() {
        fileAccess.withLock { suspended in
            suspended = false
            NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
        }
    }

    func withFileDatabaseAccess<T>(_ body: () throws -> T) rethrows -> T {
        try fileAccess.withLock { suspended in
            if suspended { NotificationCenter.default.post(name: Database.resumeNotification, object: nil) }
            defer { if suspended { NotificationCenter.default.post(name: Database.suspendNotification, object: nil) } }
            return try body()
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
