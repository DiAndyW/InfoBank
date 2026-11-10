import Foundation
import GRDB
import Testing
@testable import NoteBankKit

struct ErrorMessageTests {
    @Test func mapsTechnicalErrorsAndPreservesWordedErrors() {
        let database = DatabaseError(resultCode: .SQLITE_ABORT, message: "Database is suspended", sql: "BEGIN IMMEDIATE TRANSACTION")
        #expect(errorMessage(database) == "NoteBank couldn't read or save its data. Try again.")
        #expect(errorMessage(ItemActionError.topicUnavailable) == ItemActionError.topicUnavailable.localizedDescription)
        #expect(errorMessage(URLError(.timedOut)) == "Couldn't reach the Server.")
        #expect(errorMessage(CocoaError(.fileReadNoPermission)) == "NoteBank couldn't access that file.")
        #expect(errorMessage(NSError(domain: "unknown", code: 2)) == "Something went wrong. Try again.")
    }
}
