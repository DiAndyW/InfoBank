import Foundation
import NoteBankKit
import Observation

struct ComposeRequest: Equatable {
    let id = UUID()
    let place: Destination
}

@MainActor @Observable
final class ComposeRequests {
    static let shared = ComposeRequests()

    private(set) var latest: ComposeRequest?

    func open(_ place: Destination) {
        latest = ComposeRequest(place: place)
    }
}
