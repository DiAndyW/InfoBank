import Foundation
import GRDB
import os

private let errorLogger = Logger(subsystem: "app.notebank.ios", category: "errors")

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
        return "Something went wrong. Try again."
    }
}
