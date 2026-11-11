import Foundation

public enum BuildStatus: Equatable, Sendable {
    case upToDate, notUpToDate, notOnGitHub, offline, failed

    public var message: String {
        switch self {
        case .upToDate: "Up to date"
        case .notUpToDate: "Not up to date"
        case .notOnGitHub: "Can't check, this build's commit isn't on GitHub"
        case .offline: "No connection, try again later"
        case .failed: "Couldn't check, try again later"
        }
    }
}

public enum BuildCheck {
    public static func run(commit: String) async -> BuildStatus {
        guard let url = URL(string: "https://api.github.com/repos/DiAndyW/InfoBank/compare/" + commit + "...main") else { return .failed }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            return status(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
        } catch {
            return status(error: error)
        }
    }

    static func status(statusCode: Int, data: Data) -> BuildStatus {
        if statusCode == 404 { return .notOnGitHub }
        guard statusCode == 200,
            let comparison = try? JSONDecoder().decode(Comparison.self, from: data)
        else { return .failed }
        return comparison.files.count >= 300 || comparison.files.contains { $0.filename.hasPrefix("ios/") }
            ? .notUpToDate : .upToDate
    }

    static func status(error: Error) -> BuildStatus {
        guard let error = error as? URLError else { return .failed }
        return switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .timedOut: .offline
        default: .failed
        }
    }

    private struct Comparison: Decodable {
        struct File: Decodable {
            let filename: String
        }
        let files: [File]
    }
}
