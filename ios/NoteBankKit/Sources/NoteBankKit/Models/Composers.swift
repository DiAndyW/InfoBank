import Observation

@MainActor @Observable
public final class Composers {
    public let home: ComposerModel
    private let store: Store
    private let onCaptured: @MainActor () -> Void
    private let initial: [DraftPlace: Draft]
    private var models: [DraftPlace: ComposerModel]

    public init(store: Store, onCaptured: @escaping @MainActor () -> Void) {
        self.store = store
        self.onCaptured = onCaptured
        do { initial = try store.drafts() }
        catch { initial = [:] }
        let draft = initial[.home]
        home = ComposerModel(store: store, destination: draft?.homeTopicID.map(Destination.topic) ?? .inbox, placeholder: "", draft: .home, initial: draft, onCaptured: onCaptured)
        models = [.home: home]
    }

    public func model(for place: DraftPlace, destination: Destination, placeholder: String) -> ComposerModel {
        if let model = models[place] {
            model.placeholder = placeholder
            return model
        }
        let model = ComposerModel(store: store, destination: destination, placeholder: placeholder, draft: place, initial: initial[place], onCaptured: onCaptured)
        models[place] = model
        return model
    }

    public func flush() {
        for model in models.values { model.flushDraft() }
    }
}
