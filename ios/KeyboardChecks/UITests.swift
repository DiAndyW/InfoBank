import XCTest

@MainActor final class KeyboardUITests: XCTestCase {
    func testReturnDoesNotLeaveSuspensionError() {
        let app = XCUIApplication(bundleIdentifier: "app.notebank.ios")
        app.launch()
        let input = app.textViews.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText(" draft")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 15)
        app.activate()
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Database is suspended")).firstMatch.waitForExistence(timeout: 3))
    }

    func testFeedEmptyTapDragAndTunnelCopy() {
        let app = XCUIApplication(bundleIdentifier: "app.notebank.ios")
        app.launch()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Inbox,")).firstMatch.tap()
        let input = app.textViews.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        app.scrollViews.allElementsBoundByIndex.max(by: { $0.frame.height < $1.frame.height })!.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        input.tap()
        let feed = app.scrollViews.allElementsBoundByIndex.max(by: { $0.frame.height < $1.frame.height })!
        feed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).press(forDuration: 0.05, thenDragTo: feed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        let textInInbox = "Keyboard dismiss " + UUID().uuidString
        input.tap()
        input.typeText(textInInbox)
        app.buttons["Send"].tap()
        let inboxRow = app.staticTexts[textInInbox]
        XCTAssertTrue(inboxRow.waitForExistence(timeout: 5))
        input.tap()
        inboxRow.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Tunnel,")).firstMatch.tap()
        input.tap()
        let text = "Keyboard copy " + UUID().uuidString
        input.typeText(text)
        app.buttons["Send"].tap()
        let row = app.staticTexts[text]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        input.tap()
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Copied")).firstMatch.waitForExistence(timeout: 3))
    }
}
