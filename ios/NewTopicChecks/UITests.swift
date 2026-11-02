import XCTest

@MainActor
final class NewTopicUITests: XCTestCase {
    let app = XCUIApplication()

    var field: XCUIElement { app.textFields["Topic name"] }
    var create: XCUIElement { app.buttons["Create"] }

    func openDialog() {
        app.buttons["New Topic…"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5), "The New Topic dialog did not open")
    }

    func testCreateWaitsForAUsableNameAndSaysWhyWhileTyping() {
        app.launch()
        openDialog()
        XCTAssertFalse(create.isEnabled, "Create is enabled with no name")
        XCTAssertFalse(app.staticTexts["Enter a name"].exists, "An empty field already shows an error")
        field.typeText("old")
        XCTAssertTrue(app.staticTexts["An archived Topic has that name."].waitForExistence(timeout: 2), "The reason doesn't show while typing: \(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        XCTAssertFalse(create.isEnabled, "Create is enabled for an archived name")
        field.typeText("er")
        XCTAssertTrue(create.waitForEnabled(), "Create stays disabled for a usable name")
        XCTAssertFalse(app.staticTexts["An archived Topic has that name."].exists, "The old reason stays after the name changed")
        create.tap()
        XCTAssertTrue(app.staticTexts["Created: older"].waitForExistence(timeout: 5))
    }

    func testAFailedSaveStaysOpenAndTheDialogOpensAgainAfterCancel() {
        app.launch()
        openDialog()
        field.typeText("broken")
        create.tap()
        XCTAssertTrue(app.staticTexts["Couldn't save the Topic"].waitForExistence(timeout: 2), "The save error isn't shown in the dialog")
        XCTAssertEqual(field.value as? String, "broken", "The typed name was lost")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        openDialog()
        XCTAssertEqual(field.value as? String, "Topic name", "The cancelled name is still in the field")
        field.typeText("Fresh\n")
        XCTAssertTrue(app.staticTexts["Created: Fresh"].waitForExistence(timeout: 5), "Return didn't create the Topic")
        openDialog()
    }
}

extension XCUIElement {
    func waitForEnabled(timeout: TimeInterval = 2) -> Bool {
        XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: self)], timeout: timeout) == .completed
    }
}
