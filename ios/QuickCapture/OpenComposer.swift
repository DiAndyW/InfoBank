import AppIntents
import NoteBankKit

struct OpenComposer: AppIntent {
    static let title: LocalizedStringResource = "New Note"
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Place") var place: CapturePlace?

    init() {}

    init(place: CapturePlace?) {
        self.place = place
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        ComposeRequests.shared.open(place.flatMap { Destination(placeID: $0.id) } ?? .inbox)
        return .result()
    }
}
