import Foundation
import Synchronization
@testable import NoteBankKit

func tempStore() throws -> (store: Store, file: URL) {
    let file = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        .appending(path: "notebank.db")
    return (try Store(at: file), file)
}

extension SecretStore {
    static func memory() -> SecretStore {
        let box = Mutex<String?>(nil)
        return SecretStore(read: { box.withLock { $0 } }, write: { secret in box.withLock { $0 = secret } })
    }
}

@MainActor
func waitUntil(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    return condition()
}
