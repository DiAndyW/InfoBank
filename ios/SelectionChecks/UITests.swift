import XCTest

@MainActor final class SelectionUITests: XCTestCase {
    func testToolbarKeepsCountAndCompactTunnelButtonsInOneRow() {
        let app = XCUIApplication()
        app.launch()
        let first = app.buttons["Item 1"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        app.buttons["Select"].tap()
        app.buttons["Item 1"].tap()
        let copy = app.buttons["Copy & Trash"]
        XCTAssertTrue(copy.waitForExistence(timeout: 3))
        let trash = app.buttons["Trash"].frame
        let count = app.staticTexts["1 selected"].frame
        XCTAssertLessThan(copy.frame.height, 50)
        XCTAssertLessThan(copy.frame.width, app.frame.width / 2)
        XCTAssertLessThanOrEqual(count.maxX, copy.frame.minX)
        XCTAssertLessThanOrEqual(copy.frame.maxX, trash.minX)
        XCTAssertEqual(copy.frame.midY, trash.midY, accuracy: 2)
        XCTAssertEqual(count.midY, copy.frame.midY, accuracy: 2)
    }

    func testHoldOpensActionsAndDoesNotSelect() {
        let app = XCUIApplication()
        app.launch()
        let first = app.buttons["Item 1"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.press(forDuration: 0.8)
        XCTAssertTrue(app.staticTexts["Commands: 1"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Copies: 0"].exists)
        XCTAssertFalse(app.buttons["Item 1"].value as? String == "Selected")
        XCTAssertFalse(app.buttons["Item 1"].value as? String == "Not selected")
        XCTAssertFalse(app.staticTexts["0 selected"].exists)
        XCTAssertFalse(app.staticTexts["1 selected"].exists)
        XCTAssertFalse(app.buttons["Item actions"].exists)
    }

    func testSelectButtonEntersAndLastDeselectionExits() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Item 1"].waitForExistence(timeout: 5))
        let select = app.buttons["Select"]
        XCTAssertTrue(select.waitForExistence(timeout: 3))
        guard select.exists else { return }
        select.tap()
        XCTAssertTrue(app.staticTexts["0 selected"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["Item 1"].value as? String, "Not selected")
        XCTAssertFalse(app.buttons["Copy & Trash"].isEnabled)
        XCTAssertFalse(app.buttons["Trash"].isEnabled)
        app.buttons["Item 1"].tap()
        XCTAssertTrue(app.staticTexts["1 selected"].exists)
        XCTAssertEqual(app.buttons["Item 1"].value as? String, "Selected")
        XCTAssertTrue(app.buttons["Copy & Trash"].isEnabled)
        XCTAssertTrue(app.buttons["Trash"].isEnabled)
        app.buttons["Item 1"].tap()
        XCTAssertFalse(app.staticTexts["0 selected"].exists)
        XCTAssertFalse(app.buttons["Item 1"].value as? String == "Not selected")
        XCTAssertTrue(app.staticTexts["Copies: 0"].exists)
        app.buttons["Item 1"].tap()
        XCTAssertTrue(app.staticTexts["Copies: 1"].exists)
    }

    func testOrdinaryTapsAndScrollingDoNotEnterSelection() {
        let app = XCUIApplication()
        app.launch()
        let first = app.buttons["Item 1"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.tap()
        XCTAssertTrue(app.staticTexts["Copies: 1"].exists)
        XCTAssertTrue(app.staticTexts["Selected: 0"].exists)
        XCTAssertFalse(app.buttons["Item 1"].value as? String == "Not selected")
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(app.staticTexts["Selected: 0"].exists)
        XCTAssertFalse(app.staticTexts["0 selected"].exists)
    }
}
