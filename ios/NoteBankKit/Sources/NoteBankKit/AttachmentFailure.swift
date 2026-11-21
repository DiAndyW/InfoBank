import Foundation

public struct AttachmentError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

public func attachmentPreviewFailureMessage(_ error: Error) -> String {
    let headline = "Attachment failed to open."
    guard let error = error as? AttachmentError else { return headline }
    return headline + " " + error.message
}
