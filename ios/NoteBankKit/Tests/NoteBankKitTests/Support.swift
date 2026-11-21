import Foundation
import Synchronization
@testable import NoteBankKit

let testDirectory: URL = {
    let url = FileManager.default.temporaryDirectory.appending(path: "NoteBankKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    atexit { try? FileManager.default.removeItem(at: testDirectory) }
    return url
}()

func tempStore() throws -> (store: Store, file: URL) {
    let file = testDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        .appending(path: "notebank.db")
    return (try Store(at: file, observesSuspension: false), file)
}

extension SecretStore {
    static func memory() -> SecretStore {
        let box = Mutex<String?>(nil)
        return SecretStore(read: { box.withLock { $0 } }, write: { secret in box.withLock { $0 = secret } })
    }
}

func eventually(timeout: Duration = .seconds(10), _ condition: () throws -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try condition() { return true }
        try await Task.sleep(for: .milliseconds(20))
    }
    return try condition()
}

@MainActor
func waitUntil(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    return condition()
}

extension ServerCheck {
    static let accepting = ServerCheck(run: { _, _ in })
}
