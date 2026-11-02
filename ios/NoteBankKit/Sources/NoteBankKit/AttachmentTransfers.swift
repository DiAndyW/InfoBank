import AVFoundation
import Foundation
import GRDB
import ImageIO
import Synchronization
import UniformTypeIdentifiers

private struct UploadIdentity: Codable, Sendable {
    let attachmentID: String
    let serverURL: String
    let generation: Int64
}

private final class UploadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let store: Store
    let sessionIdentifier: String
    let wake = Mutex<(@Sendable () -> Void)?>(nil)
    struct Events: Sendable {
        var completion: (@MainActor @Sendable () -> Void)?
        var finished = false
    }
    let events = Mutex(Events())
    init(store: Store, sessionIdentifier: String) { self.store = store; self.sessionIdentifier = sessionIdentifier }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let text = task.taskDescription, let identity = try? JSONDecoder().decode(UploadIdentity.self, from: Data(text.utf8)) else { return }
        do {
            let expected = URL(string: identity.serverURL + "/attachments/" + identity.attachmentID)
            let redirected = task.response?.url != expected
            try store.withFileDatabaseAccess {
                try store.completeUpload(identity.attachmentID, serverURL: identity.serverURL, taskID: task.taskIdentifier, status: (task.response as? HTTPURLResponse)?.statusCode ?? 0, failed: error != nil || redirected, generation: identity.generation, sessionIdentifier: sessionIdentifier)
            }
            wake.withLock { $0 }?()
        } catch {
            // The task is reconciled from Server metadata on the next foreground sync.
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let done = events.withLock { state in
            let done = state.completion; state.completion = nil; state.finished = done == nil; return done
        }
        Task { @MainActor in done?() }
    }
}

public actor AttachmentTransfers {
    public static let sessionIdentifier = "app.notebank.ios.attachment-uploads"
    public static let shareSessionIdentifier = "app.notebank.ios.share.attachment-uploads"
    private let identifier: String
    private let store: Store
    private let secrets: SecretStore
    private let session: URLSession
    private let delegate: UploadDelegate
    private var scheduling = false
    private var prefetching = false
    private var pins: [String: Int] = [:]
    private let now: @Sendable () -> ContinuousClock.Instant
    private struct ThumbnailRequest: Hashable {
        let id: String
        let generation: Int64
    }
    private struct ThumbnailRetry {
        let attempts: Int
        let after: ContinuousClock.Instant
    }
    private var thumbnailRetries: [ThumbnailRequest: ThumbnailRetry] = [:]
    private var thumbnailRequests: [ThumbnailRequest: Task<URL, Error>] = [:]
    private var thumbnailUploadRetries: [ThumbnailRequest: ThumbnailRetry] = [:]

    public init(store: Store, secrets: SecretStore, background: Bool = true, sessionIdentifier: String = AttachmentTransfers.sessionIdentifier, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.identifier = sessionIdentifier
        self.store = store
        self.secrets = secrets
        self.now = now
        delegate = UploadDelegate(store: store, sessionIdentifier: sessionIdentifier)
        let config: URLSessionConfiguration
        if background {
            config = .background(withIdentifier: sessionIdentifier)
            #if os(iOS)
            config.sharedContainerIdentifier = "group.app.notebank"
            config.sessionSendsLaunchEvents = true
            #endif
            config.isDiscretionary = false
        } else { config = .ephemeral }
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7 * 24 * 3600
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    public func setWakeHandler(_ wake: @escaping @Sendable () -> Void) { delegate.wake.withLock { $0 = wake } }

    public func backgroundEvents(completion: @escaping @MainActor @Sendable () -> Void) {
        let finished = delegate.events.withLock { state in
            if state.finished { state.finished = false; return true }
            state.completion = completion
            return false
        }
        if finished { Task { @MainActor in completion() } }
        session.getAllTasks { _ in }
    }

    public func synchronize(itemID: String? = nil) async throws {
        guard !scheduling else { return }
        scheduling = true
        defer { scheduling = false }
        guard let serverURL = try store.serverURL(), let secret = try secrets.read() else { return }
        let generation = try store.transferGeneration()
        let candidates = try store.pendingUploads()
        let wanted = Set(candidates.map(\.id))
        var active = Set<String>()
        for task in await session.allTasks {
            guard let text = task.taskDescription,
                  let identity = try? JSONDecoder().decode(UploadIdentity.self, from: Data(text.utf8)),
                  identity.serverURL == serverURL, identity.generation == generation, wanted.contains(identity.attachmentID), task.state != .completed, task.state != .canceling else { task.cancel(); continue }
            active.insert(identity.attachmentID)
            try store.registerUpload(identity.attachmentID, serverURL: serverURL, taskID: task.taskIdentifier, sessionIdentifier: identifier)
            if task.state == .suspended { task.resume() }
        }
        var waitingForRetry = false
        for attachment in candidates where !active.contains(attachment.id) {
            if let itemID, try store.attachmentItemID(attachment.id) != itemID { continue }
            guard try store.canScheduleUpload(attachment.id, sessionIdentifier: identifier) else { continue }
            if try store.uploadRetryAt(attachment.id) > Time.nowUs() { waitingForRetry = true; continue }
            if itemID == nil && active.count >= 4 { break }
            guard let file = try store.localFile(attachment.id) else {
                try store.recordUploadError(attachment.id, serverURL: serverURL, message: "The local file is missing; it hasn't been uploaded")
                waitingForRetry = true
                continue
            }
            if attachment.mimeType.hasPrefix("image/") || attachment.mimeType.hasPrefix("video/") { _ = try? await thumbnail(attachment.id) }
            let data = try await SyncHTTP.live.send(serverURL, path: "/attachments/\(attachment.id)/upload-token", secret: secret, body: Data("{}".utf8))
            struct Capability: Decodable { let token: String }
            guard let token = try? JSONDecoder().decode(Capability.self, from: data).token, !token.isEmpty else { throw AttachmentError("Couldn't authorize the upload") }
            guard try store.serverURL() == serverURL, try store.transferGeneration() == generation, try store.attachment(attachment.id)?.uploaded == false else { return }
            var request = URLRequest(url: URL(string: serverURL + "/attachments/\(attachment.id)")!)
            request.httpMethod = "PUT"
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue(attachment.mimeType, forHTTPHeaderField: "Content-Type")
            let task = session.uploadTask(with: request, fromFile: file)
            let identity = UploadIdentity(attachmentID: attachment.id, serverURL: serverURL, generation: generation)
            task.taskDescription = String(decoding: try JSONEncoder().encode(identity), as: UTF8.self)
            do { try store.registerUpload(attachment.id, serverURL: serverURL, taskID: task.taskIdentifier, sessionIdentifier: identifier) }
            catch { task.cancel(); throw error }
            task.resume()
            active.insert(attachment.id)
        }
        await uploadThumbnails(serverURL: serverURL, secret: secret, generation: generation)
        try store.evictCache(nowUs: Time.nowUs(), pinned: Set(pins.keys).union(wanted))
        if waitingForRetry { throw AttachmentError("An upload is waiting to retry") }
    }

    private func uploadThumbnails(serverURL: String, secret: String, generation: Int64) async {
        thumbnailUploadRetries = thumbnailUploadRetries.filter { $0.key.generation == generation }
        let candidates = try? await store.pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT a.id FROM attachments a JOIN items i ON i.id = a.item_id
                WHERE a.uploaded = 1 AND a.has_thumbnail = 0 AND (a.mime_type LIKE 'image/%' OR a.mime_type LIKE 'video/%')
                  AND i.deleted_at IS NULL AND i.sync_error IS NULL
                  AND EXISTS(SELECT 1 FROM cached_files c WHERE c.attachment_id = a.id)
                ORDER BY a.rowid
                """)
        }
        var attempted = 0
        for id in candidates ?? [] {
            let key = ThumbnailRequest(id: id, generation: generation)
            if thumbnailUploadRetries[key].map({ now() < $0.after }) == true { continue }
            guard attempted < 4 else { break }
            attempted += 1
            do {
                guard try store.serverURL() == serverURL, try store.transferGeneration() == generation else { return }
                guard let file = try await thumbnail(id) else { throw AttachmentError("No image preview is available") }
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 1 << 20 else { throw AttachmentError("The image preview is too large") }
                let bytes = try Data(contentsOf: file)
                let data = try await SyncHTTP.live.send(serverURL, path: "/attachments/\(id)/thumbnail-upload-token", secret: secret, body: Data("{}".utf8))
                struct Capability: Decodable { let token: String }
                let token = try JSONDecoder().decode(Capability.self, from: data).token
                guard !token.isEmpty, try store.serverURL() == serverURL, try store.transferGeneration() == generation else { return }
                var request = URLRequest(url: URL(string: serverURL + "/attachments/\(id)/thumbnail")!)
                request.httpMethod = "PUT"
                request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
                request.httpBody = bytes
                let (_, response) = try await SyncHTTP.live.session.data(for: request, delegate: SyncHTTP.live)
                guard (response as? HTTPURLResponse)?.statusCode == 204 else { throw AttachmentError("Couldn't upload the image preview") }
                try await store.pool.write { db in
                    try db.execute(sql: "UPDATE attachments SET has_thumbnail = 1 WHERE id = ? AND EXISTS(SELECT 1 FROM device WHERE server_url = ? AND transfer_generation = ?)", arguments: [id, serverURL, generation])
                }
                thumbnailUploadRetries.removeValue(forKey: key)
                delegate.wake.withLock { $0 }?()
            } catch {
                let attempts = min((thumbnailUploadRetries[key]?.attempts ?? 0) + 1, 5)
                thumbnailUploadRetries[key] = ThumbnailRetry(attempts: attempts, after: now() + .seconds(min(30 * (1 << (attempts - 1)), 300)))
            }
        }
    }

    public func open(_ id: String) async throws -> URL {
        pins[id, default: 0] += 1
        do {
            let file = try await fetch(id, thumbnail: false)
            try store.markOpened(id, nowUs: Time.nowUs())
            return file
        } catch { release(id); throw error }
    }

    public func clipboardFiles(_ ids: [String]) async throws -> [URL] {
        let root = store.directory.appending(path: "clipboard", directoryHint: .isDirectory)
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        // Keep clipboard preparation independent of cache eviction and Trash.
        for entry in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
            if let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               modified < Date().addingTimeInterval(-7 * 24 * 3600) { try? manager.removeItem(at: entry) }
        }
        let folder = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        var completed = false
        defer { if !completed { try? manager.removeItem(at: folder) } }
        var exported: [URL] = []
        for id in ids {
            try Task.checkCancellation()
            let source = try await open(id)
            do {
                let target = folder.appending(path: id, directoryHint: .isDirectory).appending(path: source.lastPathComponent)
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.copyItem(at: source, to: target)
                exported.append(target)
                release(id)
            } catch { release(id); throw error }
        }
        try Task.checkCancellation()
        completed = true
        return exported
    }

    public func release(_ id: String) {
        if let count = pins[id], count > 1 { pins[id] = count - 1 } else { pins.removeValue(forKey: id) }
        try? store.evictCache(nowUs: Time.nowUs(), pinned: Set(pins.keys))
    }

    public func thumbnail(_ id: String) async throws -> URL? {
        guard UUID(uuidString: id) != nil else { throw AttachmentError("Unknown attachment") }
        if let cached = try store.localFile(id, kind: "thumbnail") { return cached }
        guard let attachment = try store.attachment(id) else { return nil }
        if let local = try store.localFile(id) {
            var preview: CGImage?
            if attachment.mimeType.hasPrefix("image/") {
                preview = CGImageSourceCreateWithURL(local as CFURL, nil).flatMap {
                    CGImageSourceCreateThumbnailAtIndex($0, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 400, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
                }
            } else if attachment.mimeType.hasPrefix("video/") {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: local))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 400, height: 400)
                preview = try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
            }
            let target = store.directory.appending(path: "thumbnails/\(id).jpg")
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let preview, let output = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(output, preview, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
                if CGImageDestinationFinalize(output) {
                    try saveCache(id: id, kind: "thumbnail", relative: "thumbnails/\(id).jpg", size: Int64(target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
                    return target
                }
            }
        }
        guard attachment.hasThumbnail else { return nil }
        let generation = try store.transferGeneration()
        thumbnailRetries = thumbnailRetries.filter { $0.key.generation == generation }
        let request = ThumbnailRequest(id: id, generation: generation)
        if let active = thumbnailRequests[request] { return try await active.value }
        guard thumbnailRetries[request].map({ now() >= $0.after }) ?? true else { return nil }
        let download = Task { try await self.fetch(id, thumbnail: true) }
        thumbnailRequests[request] = download
        defer { thumbnailRequests.removeValue(forKey: request) }
        do {
            let file = try await download.value
            thumbnailRetries.removeValue(forKey: request)
            return file
        } catch {
            if (try? store.transferGeneration()) == generation {
                let attempts = min((thumbnailRetries[request]?.attempts ?? 0) + 1, 5)
                let delay = min(30 * (1 << (attempts - 1)), 300)
                thumbnailRetries[request] = ThumbnailRetry(attempts: attempts, after: now() + .seconds(delay))
            }
            throw error
        }
    }

    public func prefetchThumbnails() async {
        guard !prefetching else { return }
        prefetching = true
        defer { prefetching = false }
        let ids = try? await store.pool.read { db in
            try String.fetchAll(db, sql: "SELECT a.id FROM attachments a JOIN items i ON i.id = a.item_id WHERE a.has_thumbnail = 1 AND i.deleted_at IS NULL AND max(i.capture_time, i.opened_at) >= ? AND NOT EXISTS(SELECT 1 FROM cached_files c WHERE c.attachment_id = a.id AND c.kind = 'thumbnail')", arguments: [Time.nowUs() - Store.thumbnailKeepUs])
        }
        for id in ids ?? [] {
            do { _ = try await thumbnail(id) } catch { continue }
        }
        try? store.evictCache(nowUs: Time.nowUs(), pinned: Set(pins.keys))
    }

    private func fetch(_ id: String, thumbnail: Bool) async throws -> URL {
        guard UUID(uuidString: id) != nil else { throw AttachmentError("Unknown attachment") }
        let kind = thumbnail ? "thumbnail" : "file"
        if let local = try store.localFile(id, kind: kind) { return local }
        guard let attachment = try store.attachment(id), attachment.uploaded else { throw AttachmentError("This file isn't on the Server yet") }
        guard let serverURL = try store.serverURL(), let secret = try secrets.read() else { throw AttachmentError("Set up sync to download this file") }
        guard attachment.sizeBytes <= Store.maxAttachmentBytes else { throw AttachmentError("This file is over 100 MB") }
        let generation = try store.transferGeneration()
        let relative = thumbnail ? "thumbnails/\(id).jpg" : "files/\(id)/\(Store.safeAttachmentName(attachment.filename))"
        let target = store.directory.appending(path: relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = target.deletingLastPathComponent().appending(path: ".dl-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let size = try await SyncHTTP.live.download(serverURL, path: "/attachments/\(id)" + (thumbnail ? "/thumbnail" : ""), secret: secret, to: temporary, maximumBytes: thumbnail ? 1 << 20 : attachment.sizeBytes, exact: !thumbnail)
        guard try store.serverURL() == serverURL, try store.transferGeneration() == generation, try store.attachment(id) != nil else { throw AttachmentError("This attachment is no longer available") }
        if let cached = try store.localFile(id, kind: kind) { return cached }
        try FileManager.default.moveItem(at: temporary, to: target)
        try saveCache(id: id, kind: kind, relative: relative, size: size)
        return target
    }

    private func saveCache(id: String, kind: String, relative: String, size: Int64) throws {
        try store.pool.write { db in
            try db.execute(sql: "INSERT INTO cached_files VALUES (?, ?, ?, ?, ?) ON CONFLICT(attachment_id, kind) DO UPDATE SET path = excluded.path, size_bytes = excluded.size_bytes, last_used_at = excluded.last_used_at", arguments: [id, kind, relative, size, Time.nowUs()])
        }
    }
}

extension SyncHTTP {
    func download(_ server: String, path: String, secret: String, to target: URL, maximumBytes: Int64, exact: Bool) async throws -> Int64 {
        var request = URLRequest(url: URL(string: server + path)!)
        request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: self)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else { throw AttachmentError("Couldn't download this file") }
            guard response.statusCode == 200 else { throw AttachmentError("Couldn't download this file (HTTP \(response.statusCode))") }
            guard response.expectedContentLength <= maximumBytes else { throw AttachmentError("The Server sent more than expected") }
            FileManager.default.createFile(atPath: target.path, contents: nil)
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            var chunk = Data(); var size: Int64 = 0
            for try await byte in bytes {
                size += 1
                guard size <= maximumBytes else { throw AttachmentError("The Server sent more than expected") }
                chunk.append(byte)
                if chunk.count == 65536 { try handle.write(contentsOf: chunk); chunk.removeAll(keepingCapacity: true) }
            }
            try handle.write(contentsOf: chunk)
            guard !exact || size == maximumBytes else { throw AttachmentError("The download was incomplete") }
            return size
        } catch let error as AttachmentError { throw error }
        catch { throw AttachmentError("Couldn't download this file; check your connection") }
    }
}
