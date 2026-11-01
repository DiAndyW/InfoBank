import XCTest

final class ImageViewerUITests: XCTestCase {
    @MainActor
    func testOpenPageZoomShareAndClose() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Open images"].tap()
        XCTAssertTrue(app.buttons["Close image"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["first.jpg"].exists)
        XCTAssertTrue(app.images["first.jpg"].exists)
        XCTAssertTrue(app.staticTexts["1 of 3"].exists)
        let topShare = app.buttons["Share image"]
        let close = app.buttons["Close image"]
        XCTAssertLessThan(abs(topShare.frame.midY - close.frame.midY), 4)
        XCTAssertGreaterThan(topShare.frame.midX, app.frame.midX)
        XCTAssertFalse(app.staticTexts["Share image"].exists)
        app.swipeLeft()
        XCTAssertTrue(app.staticTexts["second.jpg"].waitForExistence(timeout: 5))
        app.swipeLeft()
        XCTAssertTrue(app.staticTexts["third.jpg"].waitForExistence(timeout: 5))
        app.swipeRight()
        XCTAssertTrue(app.staticTexts["second.jpg"].waitForExistence(timeout: 5))
        let zoom = app.scrollViews.firstMatch
        XCTAssertTrue(zoom.exists)
        let beforeZoom = zoom.screenshot().pngRepresentation
        zoom.pinch(withScale: 2, velocity: 1)
        XCTAssertNotEqual(beforeZoom, zoom.screenshot().pngRepresentation)
        zoom.swipeUp()
        zoom.pinch(withScale: 0.5, velocity: -1)
        let share = app.buttons["Share image"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: share)
        waitForExpectations(timeout: 5)
        share.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["Close"].tap()
        app.buttons["Close image"].tap()
        XCTAssertTrue(app.buttons["Open images"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSwipeDownClosesOnlyWhenNotZoomed() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Open images"].tap()
        XCTAssertTrue(app.buttons["Close image"].waitForExistence(timeout: 5))
        let zoom = app.scrollViews.firstMatch
        zoom.pinch(withScale: 2, velocity: 1)
        zoom.swipeDown()
        XCTAssertTrue(app.buttons["Close image"].exists)
        zoom.doubleTap()
        zoom.swipeDown()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["Close image"])
        waitForExpectations(timeout: 5)
    }

    @MainActor
    func testFailureAndRetry() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--failure"]
        app.launch()
        app.buttons["Open images"].tap()
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Share image"].isEnabled)
        XCTAssertTrue(app.staticTexts["first.jpg"].exists)
        XCTAssertTrue(app.images["first.jpg"].exists)
        app.buttons["Retry"].tap()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["Share image"])
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.buttons["Retry"].exists)
        app.buttons["Close image"].tap()
        XCTAssertTrue(app.buttons["Open images"].waitForExistence(timeout: 5))
    }
}
