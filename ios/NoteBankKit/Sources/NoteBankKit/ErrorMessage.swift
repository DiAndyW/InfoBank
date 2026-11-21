import Foundation
import GRDB
import os

private let errorLogger = Logger(subsystem: "app.notebank.ios", category: "errors")

let genericFailure = "Something went wrong. Try again."

public func failureMessage(_ headline: String, _ error: Error) -> String {
    let reason = errorMessage(error)
    return reason == genericFailure ? headline : headline + " " + reason
}

func attachmentFailureMessage(_ name: String, _ error: Error) -> String {
    let reason = errorMessage(error)
    if reason != genericFailure && reason.contains(name) { return reason }
    let headline = "\(name) failed to attach."
    return reason == genericFailure ? headline : headline + " " + reason
}

public func errorMessage(_ error: Error) -> String {
    let nsError = error as NSError
    // Log codes rather than descriptions, which may contain URLs or bound database values.
    errorLogger.error("Failure type: \(String(reflecting: type(of: error)), privacy: .private), code: \(nsError.code, privacy: .private)")
    switch error {
    case is CaptureError, is ItemActionError, is AttachmentError, is SettingsError,
         is KeychainError, is SearchError, is StoreError:
        return error.localizedDescription
    case is DatabaseError:
        return "NoteBank couldn't read or save its data. Try again."
    case is URLError:
        return "Couldn't reach the Server."
    case let error as CocoaError where error.code.rawValue >= 0 && error.code.rawValue < 1024:
        return "NoteBank couldn't access that file."
    default:
        return genericFailure
    }
}

public func storageOpenFailureMessage(_ error: Error) -> String {
    failureMessage("NoteBank failed to open its storage.", error)
}
