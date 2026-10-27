import Foundation
import Observation

@MainActor @Observable
public final class ComposerModel {
    public var text = ""
    public private(set) var error: String?
    public let placeholder: String
    public var destination: Destination

    private let store: Store
    private let onCaptured: @MainActor () -> Void

    public var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public init(store: Store, destination: Destination, placeholder: String, onCaptured: @escaping @MainActor () -> Void) {
        self.store = store
        self.onCaptured = onCaptured
        self.destination = destination
        self.placeholder = placeholder
    }

    public func dropMissingTopic(open: [TopicPlace]) {
        if case .topic(let id) = destination, !open.contains(where: { $0.id == id }) { destination = .inbox }
    }

    public func send() -> Bool {
        do {
            _ = try store.capture(text: text, to: destination, nowUs: Time.nowUs())
        } catch {
            self.error = error.localizedDescription
            return false
        }
        text = ""
        error = nil
        onCaptured()
        return true
    }
}
