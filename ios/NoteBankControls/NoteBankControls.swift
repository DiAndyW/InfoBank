import AppIntents
import NoteBankKit
import SwiftUI
import WidgetKit

struct CaptureControlConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Capture"

    @Parameter(title: "Place") var place:   CapturePlace?
}

struct CaptureControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "app.notebank.ios.capture", intent: CaptureControlConfiguration.self) { config in
            ControlWidgetButton(action: OpenComposer(place: config.place)) {
                switch config.place.flatMap({ Destination(placeID: $0.id) }) ?? .inbox {
                case .inbox: Label("Capture to Inbox", image: "capture.inbox")
                case .tunnel: Label("Capture to Tunnel", image: "capture.tunnel")
                case .topic: Label("Capture to \(config.place?.name ?? "")", image: "capture.topic")
                }
            }
        }
        .displayName("Capture")
        .description("Open the NoteBank composer to write a note.")
        .promptsForUserConfiguration()
    }
}

@main
struct NoteBankControlsBundle: WidgetBundle {
    var body: some Widget {
        CaptureControl()
    }
}
