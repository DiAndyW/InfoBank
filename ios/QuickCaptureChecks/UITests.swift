import XCTest

@MainActor
final class QuickCaptureUITests: XCTestCase {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    let noteBank = XCUIApplication(bundleIdentifier: "app.notebank.ios")

    func completeSetup() {
        noteBank.launch()
        let url = noteBank.textFields["Server URL"]
        guard url.waitForExistence(timeout: 5) else { return }
        url.tap()
        url.typeText("http://127.0.0.1:9")
        let secret = noteBank.secureTextFields["Shared secret"]
        secret.tap()
        secret.typeText("check-secret")
        noteBank.staticTexts["Set up NoteBank"].tap()
        noteBank.buttons["Save"].tap()
        XCTAssertTrue(noteBank.textViews["Capture"].waitForExistence(timeout: 10), "Setup did not finish")
    }

    func assertComposerFocused() {
        XCTAssertTrue(noteBank.keyboards.firstMatch.waitForExistence(timeout: 5), "The keyboard did not come up")
        let composer = noteBank.textViews.firstMatch
        XCTAssertTrue(composer.exists, "The composer is missing")
        XCTAssertEqual(composer.value(forKey: "hasKeyboardFocus") as? Bool, true, "The composer is not focused")
    }

    func openFromQuickAction() {
        let icon = springboard.icons["NoteBank"]
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: icon)], timeout: 10), .completed, "The NoteBank icon is not on the Home Screen: \(springboard.icons.allElementsBoundByIndex.map(\.label))")
        icon.press(forDuration: 1.5)
        let action = springboard.buttons["New Note"]
        XCTAssertTrue(action.waitForExistence(timeout: 5), "The New Note quick action is missing")
        action.tap()
        assertComposerFocused()
    }

    func testQuickActionOpensFocusedComposerOnInbox() throws {
        completeSetup()
        let tunnel = noteBank.switches["Tunnel"]
        if tunnel.value as? String != "1" { tunnel.tap() }
        XCTAssertEqual(tunnel.value as? String, "1")
        XCUIDevice.shared.press(.home)
        sleep(2)
        openFromQuickAction()
        XCTAssertEqual(tunnel.value as? String, "0", "The quick action left the Tunnel switch on")
        noteBank.terminate()
        sleep(2)
        openFromQuickAction()
    }

    func addCaptureControl(place: String?) -> XCUIElement {
        XCUIDevice.shared.press(.home)
        sleep(2)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.0)).press(forDuration: 0.05, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.6)))
        let edit = springboard.buttons["Add Controls"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "Control Center did not open")
        edit.tap()
        let remove = springboard.buttons["DeleteButton"]
        while remove.waitForExistence(timeout: 2) {
            remove.firstMatch.tap()
            sleep(1)
        }
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.916)).tap()
        let search = springboard.searchFields["Search Controls"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), "The control gallery did not open")
        search.tap()
        search.typeText("NoteBank")
        let capture = springboard.buttons["app.notebank.ios.capture"]
        XCTAssertTrue(capture.waitForExistence(timeout: 10), "The Capture control is not in the gallery")
        capture.tap()
        if let place {
            springboard.buttons["Place"].firstMatch.tap()
            springboard.buttons[place].tap()
        }
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        sleep(2)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        let control = springboard.buttons["Capture to \(place ?? "Inbox")"]
        XCTAssertTrue(control.waitForExistence(timeout: 5), "The Capture control was not added")
        return control
    }

    func testControlOpensComposer() throws {
        completeSetup()
        let control = addCaptureControl(place: "Tunnel")
        control.tap()
        XCTAssertTrue(noteBank.wait(for: .runningForeground, timeout: 10), "The Control did not open NoteBank")
        assertComposerFocused()
        let tunnel = noteBank.switches["Tunnel"]
        XCTAssertEqual(tunnel.value as? String, "1", "The Tunnel switch is not on")

        tunnel.tap()
        XCTAssertEqual(tunnel.value as? String, "0")
        let allItems = noteBank.buttons.matching(NSPredicate(format: "label BEGINSWITH 'All Items'")).firstMatch
        for _ in 0..<3 where !allItems.isHittable { noteBank.swipeUp() }
        allItems.tap()
        noteBank.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(tunnel.waitForExistence(timeout: 5))
        XCTAssertEqual(tunnel.value as? String, "0", "Coming back to Home applied the Control's request again")
        XCTAssertFalse(noteBank.keyboards.firstMatch.waitForExistence(timeout: 3), "Coming back to Home focused the composer again")
    }

    func testControlWithoutPlaceOpensComposerOnInbox() throws {
        completeSetup()
        let tunnel = noteBank.switches["Tunnel"]
        if tunnel.value as? String != "1" { tunnel.tap() }
        XCTAssertEqual(tunnel.value as? String, "1")
        let control = addCaptureControl(place: nil)
        control.tap()
        XCTAssertTrue(noteBank.wait(for: .runningForeground, timeout: 10), "The Control did not open NoteBank")
        assertComposerFocused()
        XCTAssertEqual(tunnel.value as? String, "0", "The Control without a Place left the Tunnel switch on")
    }
}
