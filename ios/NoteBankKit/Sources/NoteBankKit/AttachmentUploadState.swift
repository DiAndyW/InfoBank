import Foundation
import GRDB

extension Store {
    public func pendingUploads() throws -> [FeedAttachment] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT a.* FROM attachments a JOIN items i ON i.id = a.item_id
                WHERE a.uploaded = 0 AND i.sync_error IS NULL
                  AND NOT EXISTS(SELECT 1 FROM outbox WHERE json_extract(op, '$.type') = 'CaptureItem' AND json_extract(op, '$.item_id') = i.id)
                ORDER BY a.rowid
                """).map(Self.feedAttachment)
        }
    }

    func transferGeneration() throws -> Int64 { try pool.read { try Int64.fetchOne($0, sql: "SELECT transfer_generation FROM device")! } }

    public func registerUpload(_ id: String, serverURL: String, taskID: Int) throws {
        try pool.write { db in
            guard try String.fetchOne(db, sql: "SELECT server_url FROM device") == serverURL else { throw AttachmentError("Server changed; upload will retry") }
            try db.execute(sql: "INSERT INTO attachment_uploads(attachment_id, server_url, task_id, generation) SELECT ?, ?, ?, transfer_generation FROM device WHERE true ON CONFLICT(attachment_id) DO UPDATE SET server_url = excluded.server_url, task_id = excluded.task_id, generation = excluded.generation, error = ''", arguments: [id, serverURL, taskID])
        }
    }

    public func completeUpload(_ id: String, serverURL: String, taskID: Int, status: Int, failed: Bool, generation: Int64? = nil) throws {
        try pool.write { db in
            guard try String.fetchOne(db, sql: "SELECT server_url FROM device") == serverURL,
                  try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM attachment_uploads WHERE attachment_id = ? AND server_url = ? AND task_id = ? AND generation = (SELECT transfer_generation FROM device) AND (? IS NULL OR generation = ?))", arguments: [id, serverURL, taskID, generation, generation]) == true else { return }
            if !failed && ((200..<300).contains(status) || status == 410) {
                try db.execute(sql: "UPDATE attachments SET uploaded = 1 WHERE id = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM attachment_uploads WHERE attachment_id = ?", arguments: [id])
            } else {
                let message = status == 401 ? "Upload authorization expired; retrying" : status == 404 ? "Waiting for attachment metadata" : "Couldn't upload this file; retrying"
                try db.execute(sql: "UPDATE attachment_uploads SET error = ?, retry_at = ? + min(300, 1 << min(attempts, 9)) * 1000000, attempts = attempts + 1 WHERE attachment_id = ?", arguments: [message, Time.nowUs(), id])
            }
        }
    }

    func uploadRetryAt(_ id: String) throws -> Int64 {
        try pool.read { try Int64.fetchOne($0, sql: "SELECT retry_at FROM attachment_uploads WHERE attachment_id = ?", arguments: [id]) ?? 0 }
    }

    public func uploadError(_ id: String) throws -> String? {
        try pool.read { try String.fetchOne($0, sql: "SELECT NULLIF(error, '') FROM attachment_uploads WHERE attachment_id = ?", arguments: [id]) }
    }

    func recordUploadError(_ id: String, serverURL: String, message: String) throws {
        try pool.write { db in
            guard try String.fetchOne(db, sql: "SELECT server_url FROM device") == serverURL else { return }
            try db.execute(sql: "INSERT INTO attachment_uploads(attachment_id, server_url, task_id, error, generation) SELECT ?, ?, -1, ?, transfer_generation FROM device WHERE true ON CONFLICT(attachment_id) DO UPDATE SET error = excluded.error", arguments: [id, serverURL, message])
        }
    }
}
