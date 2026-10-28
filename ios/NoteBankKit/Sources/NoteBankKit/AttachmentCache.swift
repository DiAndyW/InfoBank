import Foundation
import GRDB

extension Store {
    public static let fileCacheBytes: Int64 = 250 << 20
    static let thumbnailKeepUs: Int64 = 60 * 86_400_000_000

    public func evictCache(nowUs: Int64, maxFileBytes: Int64 = Store.fileCacheBytes, pinned: Set<String> = []) throws {
        try pool.write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.*, a.uploaded, i.capture_time, i.opened_at,
                       EXISTS(SELECT 1 FROM staged_files s WHERE s.id = c.attachment_id) AS staged
                FROM cached_files c LEFT JOIN attachments a ON a.id = c.attachment_id
                LEFT JOIN items i ON i.id = a.item_id ORDER BY c.last_used_at DESC, c.attachment_id
                """)
            var kept = rows.filter { pinned.contains($0["attachment_id"] as String) && $0["kind"] as String == "file" && $0["uploaded"] as Bool? == true }.reduce(Int64(0)) { $0 + ($1["size_bytes"] as Int64) }
            for row in rows {
                let id: String = row["attachment_id"]
                if pinned.contains(id) { continue }
                let staged: Bool = row["staged"]
                let uploaded: Bool? = row["uploaded"]
                if staged || uploaded == false { continue }
                let kind: String = row["kind"]
                let remove: Bool
                if uploaded == nil { remove = true }
                else if kind == "thumbnail" {
                    remove = max(row["capture_time"] as Int64, row["opened_at"] as Int64) < nowUs - Self.thumbnailKeepUs
                } else {
                    kept += row["size_bytes"] as Int64
                    remove = kept > maxFileBytes
                }
                if remove {
                    try? FileManager.default.removeItem(at: directory.appending(path: row["path"] as String))
                    try db.execute(sql: "DELETE FROM cached_files WHERE attachment_id = ? AND kind = ?", arguments: [id, kind])
                }
            }
        }
    }

    public func markOpened(_ id: String, nowUs: Int64) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE cached_files SET last_used_at = ? WHERE attachment_id = ?", arguments: [nowUs, id])
            try db.execute(sql: "UPDATE items SET opened_at = ? WHERE id = (SELECT item_id FROM attachments WHERE id = ?)", arguments: [nowUs, id])
        }
    }
}
