import XCTest

final class ImageViewerUITests: XCTestCase {
    @MainActor
    private func waitUntilHittable(_ element: XCUIElement) -> XCTWaiter.Result {
        XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)], timeout: 3)
    }

    @MainActor
    func testFastSwipeOverTheImagePages() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Open images"].tap()
        XCTAssertTrue(app.buttons["Close image"].waitForExistence(timeout: 5))
        for velocity in [1500.0, 4000.0] {
            let title = app.staticTexts[velocity == 1500 ? "second.jpg" : "third.jpg"]
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).press(
                forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)),
                withVelocity: XCUIGestureVelocity(rawValue: velocity), thenHoldForDuration: 0)
            XCTAssertEqual(waitUntilHittable(title), .completed, "A \(Int(velocity)) pt/s swipe didn't page")
        }
    }

    @MainActor
    func testSwipeOnTheBarPages() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Open images"].tap()
        XCTAssertTrue(app.buttons["Close image"].waitForExistence(timeout: 5))
        let start = app.staticTexts["first.jpg"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -150, dy: 0)),
                    withVelocity: XCUIGestureVelocity(rawValue: 1000), thenHoldForDuration: 0)
        XCTAssertEqual(waitUntilHittable(app.staticTexts["second.jpg"]), .completed)
    }

    @MainActor
    func testTheBarStaysPutWhilePaging() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--mid-page"]
        app.launch()
        app.buttons["Open images"].tap()
        XCTAssertTrue(app.images["second.jpg"].waitForExistence(timeout: 5))
        let share = app.buttons.matching(NSPredicate(format: "label == 'Share image'"))
        let close = app.buttons.matching(NSPredicate(format: "label == 'Close image'"))
        XCTAssertEqual(share.count, 1)
        XCTAssertEqual(close.count, 1)
        XCTAssertLessThan(close.firstMatch.frame.maxX, app.frame.midX)
        XCTAssertGreaterThan(share.firstMatch.frame.minX, app.frame.midX)
    }

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
    func testVideoPlaysInTheViewerPagesToImagesAndSwipesDownToClose() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Open video"].tap()
        let share = app.buttons["Share video"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["clip.mp4"].exists)
        let loaded = NSPredicate(format: "isEnabled == true")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: loaded, object: share)], timeout: 10), .completed, "The video never loaded")
        app.swipeLeft()
        XCTAssertTrue(app.buttons["Close image"].waitForExistence(timeout: 5))
        app.swipeRight()
        XCTAssertTrue(app.buttons["Close video"].waitForExistence(timeout: 5))
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: loaded, object: share)], timeout: 10), .completed, "The video didn't reload after paging back")
        app.swipeDown()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["Close video"])
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
