import GRDB
import NoteBankKit
import SwiftUI
import UIKit

private enum ServicesError: LocalizedError {
    case missingKeychainPrefix

    var errorDescription: String? { "The app's Info.plist has no valid AppIdentifierPrefix, so the keychain access group can't be built." }
}

@MainActor
struct Services {
    let store: Store
    let secrets: SecretStore
    let engine: SyncEngine
    let transfers: AttachmentTransfers
    let notices = NoticeCenter()

    init() throws {
        store = try Store(at: Store.appGroupFile())
        guard let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String, prefix.hasSuffix(".") else {
            throw ServicesError.missingKeychainPrefix
        }
        secrets = .keychain(accessGroup: prefix + "app.notebank.shared")
        transfers = AttachmentTransfers(store: store, secrets: secrets)
        engine = SyncEngine(store: store, secrets: secrets, transfers: transfers)
    }

    func wake() { Task { [engine] in await engine.wake() } }

    func settingsModel() -> SettingsModel {
        SettingsModel(store: store, secrets: secrets) { [engine] in Task { await engine.settingsSaved() } }
    }
}

@main
struct NoteBankApp: App {
    @UIApplicationDelegateAdaptor(BackgroundTransferDelegate.self) private var appDelegate
    private let services = ApplicationServices.result

    var body: some Scene {
        WindowGroup {
            switch services {
            case .success(let services): RootView(services: services).environment(\.attachmentTransfers, services.transfers)
            case .failure(let error): StorageFailureView(error: error)
            }
        }
    }
}

struct RootView: View {
    let services: Services

    @AppStorage("theme", store: Theme.store) private var theme = Theme.paper
    @SceneStorage("place") private var savedPlace = ""
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [Place] = []
    @State private var places: PlacesModel
    @State private var home: ComposerModel
    @State private var setup: SettingsModel
    @State private var status = SyncStatus.notConfigured
    @State private var showingSettings = false
    @State private var target: ShowTarget?
    @State private var foregrounds = 0
    @State private var backgroundEpisode = 0

    init(services: Services) {
        self.services = services
        _places = State(wrappedValue: PlacesModel(store: services.store))
        _setup = State(wrappedValue: services.settingsModel())
        _home = State(wrappedValue: ComposerModel(store: services.store, destination: .inbox, placeholder: "Capture something…", onCaptured: services.wake))
    }

    private func show(_ itemID: String) {
        services.notices.dismiss()
        let place: Place = (try? services.store.pool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT topic_id, in_tunnel FROM items WHERE id = ? AND deleted_at IS NULL", arguments: [itemID]) else { return Place.inbox }
            if row["in_tunnel"] as Bool { return .tunnel }
            return (row["topic_id"] as String?).map(Place.topic) ?? .inbox
        }) ?? .inbox
        path = [place]
        target = ShowTarget(place: place, itemID: itemID)
    }

    private func suspendAfterSync() {
        backgroundEpisode += 1
        let episode = backgroundEpisode
        var task = UIBackgroundTaskIdentifier.invalid
        var finished = false
        let engine = services.engine
        // Suspending a database the app has since resumed would fail every read and write.
        func finish() {
            guard !finished else { return }
            finished = true
            if episode == backgroundEpisode {
                services.store.suspendFileDatabaseAccess()
            }
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
        task = UIApplication.shared.beginBackgroundTask(withName: "sync") {
            Task { await engine.cancelInFlight() }
            finish()
        }
        Task {
            await engine.enterBackground()
            finish()
        }
    }

    var body: some View {
        Group {
            if setup.needsSetup {
                SetupView(model: setup)
            } else {
                NavigationStack(path: $path) {
                    PlacesView(store: services.store, wake: services.wake, archived: places.archived, places: places.places, composer: home, status: status, notices: services.notices, onShow: show) { showingSettings = true }
                        .toolbar(.hidden, for: .navigationBar)
                        .navigationDestination(for: Place.self) { place in
                            FeedView(
                                place: place,
                                topicName: (places.places.topics + places.archived).first { .topic($0.id) == place }?.name,
                                services: services,
                                status: status,
                                openSettings: { showingSettings = true },
                                onShow: show,
                                foregrounds: foregrounds,
                                target: $target)
                        }
                }
                .sheet(isPresented: $showingSettings) { SettingsView(services: services, theme: $theme) }
            }
        }
        .environment(\.palette, theme.palette)
        .preferredColorScheme(theme.colorScheme)
        .tint(theme.palette.accent)
        .task {
            await services.engine.start()
            for await status in services.engine.status { self.status = status }
        }
        .task {
            for await notices in services.engine.notices { services.notices.post(notices) }
        }
        .task {
            var restored: [Place] = switch savedPlace {
            case "all": [.all]
            case "trash": [.trash]
            case "inbox": [.inbox]
            case "tunnel": [.tunnel]
            case let saved where saved.hasPrefix("topic:"): [.topic(String(saved.dropFirst("topic:".count)))]
            default: []
            }
            restored.removeAll { if case .topic(let id) = $0 { !(places.places.topics + places.archived).contains { $0.id == id } } else { false } }
            path = restored
        }
        .onChange(of: path) { _, path in
            savedPlace = switch path.last {
            case .all?: "all"
            case .trash?: "trash"
            case .inbox?: "inbox"
            case .tunnel?: "tunnel"
            case .topic(let id)?: "topic:" + id
            case nil: ""
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                backgroundEpisode += 1
                services.store.resumeFileDatabaseAccess()
                places.refresh()
                foregrounds += 1
                Task { await services.engine.enterForeground() }
            case .background: suspendAfterSync()
            default: break
            }
        }
    }
}

@MainActor
private enum ApplicationServices {
    static let result = Result { try Services() }
}

@MainActor
private final class BackgroundTransferDelegate: NSObject, UIApplicationDelegate {
    private var shareTransfers: AttachmentTransfers?
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard case .success(let services) = ApplicationServices.result else { completionHandler(); return }
        let transfers: AttachmentTransfers
        switch identifier {
        case AttachmentTransfers.sessionIdentifier:
            transfers = services.transfers
        case AttachmentTransfers.shareSessionIdentifier:
            if let shareTransfers { transfers = shareTransfers }
            else {
                transfers = AttachmentTransfers(store: services.store, secrets: services.secrets, sessionIdentifier: identifier)
                shareTransfers = transfers
            }
        default: completionHandler(); return
        }
        let completion = BackgroundCompletion(completionHandler)
        Task {
            await transfers.setWakeHandler { [engine = services.engine] in Task { await engine.wake() } }
            await transfers.backgroundEvents { [weak self] in
                if identifier == AttachmentTransfers.shareSessionIdentifier { self?.shareTransfers = nil }
                completion.finish()
            }
        }
    }
}

@MainActor
private final class BackgroundCompletion {
    private let completion: () -> Void
    init(_ completion: @escaping () -> Void) { self.completion = completion }
    func finish() { completion() }
}
