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
