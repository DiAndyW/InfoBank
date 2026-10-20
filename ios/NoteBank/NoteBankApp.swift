import NoteBankKit
import SwiftUI

@main
struct NoteBankApp: App {
    private let deviceID = Result { try Store(at: Store.appGroupFile()).deviceID() }

    var body: some Scene {
        WindowGroup {
            switch deviceID {
            case .success(let id):
                Text(id)
            case .failure(let error):
                StorageFailureView(error: error)
            }
        }
    }
}
