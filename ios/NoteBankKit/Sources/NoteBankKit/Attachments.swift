import Foundation
import GRDB
import UniformTypeIdentifiers

public enum AttachmentPresentation: String, Sendable {
    case image, video, file
    public var opensInViewer: Bool { self != .file }
    public var needsLocalVideoFrame: Bool { self == .video }
    public func previewLabel(filename: String) -> String { self == .video ? "Play \(filename)" : filename }
    public init(mimeType: String) {
        self = mimeType.hasPrefix("image/") ? .image : mimeType.hasPrefix("video/") ? .video : .file
    }
}

public struct StagedAttachment: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let filename: String
    public let mimeType: String
    public let sizeBytes: Int64
}

public struct FeedAttachment: Hashable, Identifiable, Sendable {
    public static let pendingLabel = "Not uploaded yet"
    public var opensInApp: Bool { AttachmentPresentation(mimeType: mimeType).opensInViewer || mimeType == "application/pdf" }
    public var unsupportedMessage: String { "NoteBank can't show \(Notice.filename(filename))'s contents." }
    public let id: String
    public let filename: String
    public let mimeType: String
    public let sizeBytes: Int64
    public let uploaded: Bool
    public let hasThumbnail: Bool
    public let uploadError: String?
}

extension Store {
    public static let maxAttachmentBytes: Int64 = 100 << 20

    static func safeAttachmentName(_ raw: String) -> String {
        let cleaned = raw.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) || "/\\:".unicodeScalars.contains($0) ? "_" : String($0) }.joined().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard cleaned.utf8.count > 255 else { return cleaned.isEmpty ? "file" : cleaned }
        let ext = (cleaned as NSString).pathExtension
        let suffix = !ext.isEmpty && ext.utf8.count <= 16 ? "." + ext : ""
        let head = suffix.isEmpty ? cleaned : String(cleaned.dropLast(suffix.count))
        var result = ""
        for character in head {
            if result.utf8.count + String(character).utf8.count > 255 - suffix.utf8.count { break }
            result.append(character)
        }
        return (result.isEmpty ? "file" : result) + suffix
    }

    private static func overLimit(_ name: String) -> AttachmentError {
        let isVideo = UTType(filenameExtension: (name as NSString).pathExtension)?.conforms(to: .movie) == true
        return AttachmentError("\(name) is over 100 MB" + (isVideo ? ". Trim the video and try again." : ""))
    }

    func recoverAttachmentFiles(_ db: Database) throws {
        // A second live Store may be importing files; startup recovery runs only without one.
        try db.execute(sql: "DELETE FROM cached_files WHERE attachment_id IN (SELECT id FROM staged_files WHERE id NOT IN (SELECT attachment_id FROM draft_attachments))")
        try db.execute(sql: "DELETE FROM staged_files WHERE id NOT IN (SELECT attachment_id FROM draft_attachments)")
        let kept = Set(try String.fetchAll(db, sql: "SELECT path FROM cached_files"))
        let files = directory.appending(path: "files")
        for folder in (try? FileManager.default.contentsOfDirectory(at: files, includingPropertiesForKeys: nil)) ?? [] {
            if !kept.contains(where: { $0.hasPrefix("files/" + folder.lastPathComponent + "/") }) { try? FileManager.default.removeItem(at: folder) }
        }
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        while let file = enumerator?.nextObject() as? URL {
            if file.lastPathComponent.hasPrefix(".dl-") { try? FileManager.default.removeItem(at: file) }
        }
    }

    public func stageFile(at source: URL, filename: String? = nil) throws -> StagedAttachment {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw AttachmentError("Choose a file") }
        let name = Self.safeAttachmentName(filename ?? source.lastPathComponent)
        guard Int64(values.fileSize ?? 0) <= Self.maxAttachmentBytes else { throw Self.overLimit(name) }
        let id = UUID().uuidString.lowercased()
        let relative = "files/\(id)/\(name)"
        let target = directory.appending(path: relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw AttachmentError("Couldn't save \(name)") }
            let input = try FileHandle(forReadingFrom: source)
            let output = try FileHandle(forWritingTo: target)
            defer { try? input.close(); try? output.close() }
            var size: Int64 = 0
            while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                size += Int64(chunk.count)
                guard size <= Self.maxAttachmentBytes else { throw Self.overLimit(name) }
                try output.write(contentsOf: chunk)
            }
            try output.synchronize()
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
            #endif
            let mime = UTType(filenameExtension: target.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let staged = StagedAttachment(id: id, filename: name, mimeType: mime, sizeBytes: size)
            try pool.write { db in
                try db.execute(sql: "INSERT INTO staged_files VALUES (?, ?, ?, ?, ?)", arguments: [id, name, mime, size, Time.nowUs()])
                try db.execute(sql: "INSERT INTO cached_files VALUES (?, 'file', ?, ?, ?)", arguments: [id, relative, size, Time.nowUs()])
            }
            return staged
        } catch {
            try? FileManager.default.removeItem(at: target.deletingLastPathComponent())
            throw error
        }
    }

    static func requireUnowned(_ db: Database, id: String, source: String?) throws {
        guard UUID(uuidString: id)?.uuidString.lowercased() == id else { throw AttachmentError("Unknown attachment") }
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM draft_attachments WHERE attachment_id = ? AND (? IS NULL OR place <> ?))", arguments: [id, source, source]) == true {
            throw AttachmentError("Attachment belongs to another saved Item or draft")
        }
    }

    public func discardStaged(_ id: String) throws {
        let path = try pool.write { db -> String? in
            try Self.discardStaged(db, id: id)
        }
        if let path { try? FileManager.default.removeItem(at: directory.appending(path: path).deletingLastPathComponent()) }
    }

    static func discardStaged(_ db: Database, id: String) throws -> String? {
        try Self.requireUnowned(db, id: id, source: nil)
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM staged_files WHERE id = ?)", arguments: [id]) == true else { return nil }
        let path = try String.fetchOne(db, sql: "SELECT path FROM cached_files WHERE attachment_id = ? AND kind = 'file'", arguments: [id])
        try db.execute(sql: "DELETE FROM staged_files WHERE id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM cached_files WHERE attachment_id = ?", arguments: [id])
        return path
    }

    public func localFile(_ id: String, kind: String = "file") throws -> URL? {
        try pool.write { db in
            guard let path = try String.fetchOne(db, sql: "SELECT path FROM cached_files WHERE attachment_id = ? AND kind = ?", arguments: [id, kind]) else { return nil }
            let url = directory.appending(path: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                try db.execute(sql: "DELETE FROM cached_files WHERE attachment_id = ? AND kind = ?", arguments: [id, kind])
                return nil
            }
            return url
        }
    }

    public func attachment(_ id: String) throws -> FeedAttachment? {
        try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT a.*, NULLIF(u.error, '') AS upload_error FROM attachments a LEFT JOIN attachment_uploads u ON u.attachment_id = a.id WHERE a.id = ?", arguments: [id]).map(Self.feedAttachment)
        }
    }

    static func feedAttachment(_ row: Row) -> FeedAttachment {
        FeedAttachment(id: row["id"], filename: row["filename"], mimeType: row["mime_type"], sizeBytes: row["size_bytes"], uploaded: row["uploaded"], hasThumbnail: row["has_thumbnail"], uploadError: row.columnNames.contains("upload_error") ? row["upload_error"] : nil)
    }
}
