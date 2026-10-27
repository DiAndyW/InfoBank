import Foundation
import Observation

@MainActor @Observable
public final class ComposerModel {
    public var text = ""
    public private(set) var error: String?
    public let placeholder: String

    private let store: Store
    private let topicID: String?
    private let onCaptured: @MainActor () -> Void

    public var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public init(store: Store, place: Place, topicName: String?, onCaptured: @escaping @MainActor () -> Void) {
        self.store = store
        self.onCaptured = onCaptured
        if case .topic(let id) = place { topicID = id } else { topicID = nil }
        placeholder = topicName.map { "Capture to \($0)" } ?? "Capture to the Inbox"
    }

    public func send() -> Bool {
        do {
            _ = try store.capture(text: text, topicID: topicID, nowUs: Time.nowUs())
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
