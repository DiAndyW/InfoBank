import Foundation
import Testing
@testable import NoteBankKit

struct BuildCheckTests {
    @Test func noChangedFilesIsCurrent() {
        #expect(BuildCheck.status(statusCode: 200, data: Data(#"{"files":[]}"#.utf8)) == .upToDate)
    }

    @Test func unrelatedPathsAreCurrent() {
        #expect(BuildCheck.status(statusCode: 200, data: Data(#"{"files":[{"filename":"iosx/App.swift"},{"filename":"docs/ios/App.swift"}]}"#.utf8)) == .upToDate)
    }

    @Test func iosChangeNeedsRebuild() {
        #expect(BuildCheck.status(statusCode: 200, data: Data(#"{"files":[{"filename":"ios/App.swift"}]}"#.utf8)) == .notUpToDate)
    }

    @Test func cappedListNeedsRebuild() throws {
        let data = try JSONSerialization.data(withJSONObject: ["files": Array(repeating: ["filename": "desktop/file"], count: 300)])
        #expect(BuildCheck.status(statusCode: 200, data: data) == .notUpToDate)
    }

    @Test func belowCapIsCurrent() throws {
        let data = try JSONSerialization.data(withJSONObject: ["files": Array(repeating: ["filename": "desktop/file"], count: 299)])
        #expect(BuildCheck.status(statusCode: 200, data: data) == .upToDate)
    }

    @Test func missingCommitIsExplained() {
        #expect(BuildCheck.status(statusCode: 404, data: Data()) == .notOnGitHub)
    }

    @Test func otherHTTPStatusesFail() {
        for code in [401, 403, 429, 500] {
            #expect(BuildCheck.status(statusCode: code, data: Data(#"{"files":[]}"#.utf8)) == .failed)
        }
    }

    @Test func malformedBodiesFail() {
        for body in ["", "{}", #"{"files":[{}]}"#, #"{"files":null}"#] {
            #expect(BuildCheck.status(statusCode: 200, data: Data(body.utf8)) == .failed)
        }
    }

    @Test func connectionErrorsAreOffline() {
        for code in [URLError.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .timedOut] {
            #expect(BuildCheck.status(error: URLError(code)) == .offline)
        }
    }

    @Test func otherErrorsFail() {
        #expect(BuildCheck.status(error: URLError(.badServerResponse)) == .failed)
        #expect(BuildCheck.status(error: CocoaError(.fileReadUnknown)) == .failed)
    }

    @Test func statusCopy() {
        #expect(BuildStatus.upToDate.message == "Up to date")
        #expect(BuildStatus.notUpToDate.message == "Not up to date")
        #expect(BuildStatus.notOnGitHub.message == "Can't check, this build's commit isn't on GitHub")
        #expect(BuildStatus.offline.message == "No connection, try again later")
        #expect(BuildStatus.failed.message == "Couldn't check, try again later")
    }
}
