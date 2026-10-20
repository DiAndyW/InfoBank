import Foundation
@testable import NoteBankKit

func tempStore() throws -> (store: Store, file: URL) {
    let file = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        .appending(path: "notebank.db")
    return (try Store(at: file), file)
}
