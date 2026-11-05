import XCTest

@MainActor final class SelectionUITests: XCTestCase {
    func testToolbarKeepsCountAndCompactTunnelButtonsInOneRow() {
        let app = XCUIApplication()
        app.launch()
        let first = app.buttons["Item 1"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.press(forDuration: 0.8)
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

    func testSelectionExchangesActionSlotWithoutChangingContentWidth() {
        let app = XCUIApplication()
        app.launch()
        let first = app.buttons["Item 1"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let origin = Double(app.staticTexts["content-origin"].label)!
        let width = Double(app.staticTexts["content-width"].label)!
        let height = app.staticTexts["content-height"].label
        first.press(forDuration: 0.8)
        XCTAssertTrue(app.staticTexts["Selected: 1"].waitForExistence(timeout: 3))
        XCTAssertEqual(Double(app.staticTexts["content-origin"].label)!, origin + 36, accuracy: 1)
        XCTAssertEqual(Double(app.staticTexts["content-width"].label)!, width, accuracy: 1)
        XCTAssertEqual(height, app.staticTexts["content-height"].label)
        let contentRight = Double(app.staticTexts["content-origin"].label)! + Double(app.staticTexts["content-width"].label)!
        XCTAssertEqual(Double(app.staticTexts["row-right"].label)! - contentRight, 8, accuracy: 1)
        XCTAssertFalse(app.buttons["Item actions"].exists)
        app.buttons["Item 1"].tap()
        XCTAssertTrue(app.staticTexts["Selected: 0"].exists)
        XCTAssertEqual(Double(app.staticTexts["content-origin"].label)!, origin, accuracy: 1)
        XCTAssertEqual(Double(app.staticTexts["content-width"].label)!, width, accuracy: 1)
    }

    func testHoldSelectsWithoutCopyAndLastDeselectionRestoresNormalTaps() {
        let app = XCUIApplication()
        app.launch()
        let first = app.buttons["Item 1"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.press(forDuration: 0.8)
        XCTAssertTrue(app.staticTexts["Selected: 1"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Copies: 0"].exists)
        app.buttons["Item 2"].tap()
        XCTAssertTrue(app.staticTexts["Selected: 2"].exists)
        app.buttons["Item 1"].tap()
        app.buttons["Item 2"].tap()
        XCTAssertTrue(app.staticTexts["Selected: 0"].exists)
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
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(app.staticTexts["Selected: 0"].exists)
    }
}
