import AppIntents
import Foundation
import NoteBankKit

struct CapturePlace: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Place"
    static let defaultQuery = CapturePlaceQuery()

    let id: String
    let name: String
    let used: String?

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", subtitle: used.map { "\($0)" }) }
}

struct CapturePlaceQuery: EntityQuery {
    // iOS refuses a saved shortcut whose Place doesn't resolve, so a closed Topic must still come back.
    func entities(for identifiers: [String]) async throws -> [CapturePlace] {
        let store = try Store(at: Store.appGroupFile(), observesSuspension: false)
        var places: [CapturePlace] = []
        for id in identifiers {
            guard let destination = Destination(placeID: id) else { continue }
            places.append(CapturePlace(id: destination.placeID, name: try store.placeName(destination), used: nil))
        }
        return places
    }

    func suggestedEntities() async throws -> [CapturePlace] {
        let nowUs = Time.nowUs()
        return try Store(at: Store.appGroupFile(), observesSuspension: false).quickPlaces().map {
            CapturePlace(id: $0.destination.placeID, name: $0.name, used: usedLabel(lastUsedUs: $0.lastUsedUs, nowUs: nowUs, calendar: .current))
        }
    }
}
