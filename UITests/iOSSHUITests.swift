import XCTest

final class iOSSHUITests: XCTestCase {
    @MainActor func testTerminalConnectionCanBeCanceled() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.buttons["addFirstHost"].tap()
        app.textFields["hostName"].tap()
        app.textFields["hostName"].typeText("Terminal test")
        app.textFields["hostAddress"].tap()
        app.textFields["hostAddress"].typeText("192.0.2.1")
        app.textFields["hostUsername"].tap()
        app.textFields["hostUsername"].typeText("tester")
        app.buttons["saveHost"].tap()
        app.buttons["host-Terminal test"].tap()
        XCTAssertTrue(app.secureTextFields["Password"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Reconnect"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "terminal").firstMatch.exists)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "rendering could not start")).count, 0)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Terminal after canceled connection"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["host-Terminal test"].waitForExistence(timeout: 5))
    }

    @MainActor func testHostCreationEditingAndDeletion() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["addFirstHost"].waitForExistence(timeout: 10))
        app.buttons["addFirstHost"].tap()
        XCTAssertFalse(app.buttons["saveHost"].isEnabled)
        app.textFields["hostName"].tap()
        app.textFields["hostName"].typeText("Development")
        app.textFields["hostAddress"].tap()
        app.textFields["hostAddress"].typeText("192.0.2.1")
        app.textFields["hostUsername"].tap()
        app.textFields["hostUsername"].typeText("developer")
        app.buttons["saveHost"].tap()
        let host = app.buttons["host-Development"]
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        host.swipeRight()
        app.buttons["Edit"].tap()
        XCTAssertEqual(app.textFields["hostAddress"].value as? String, "192.0.2.1")
        XCTAssertEqual(app.textFields["hostUsername"].value as? String, "developer")
        app.buttons["Cancel"].tap()
        host.swipeLeft()
        app.buttons["Delete"].tap()
        XCTAssertTrue(app.buttons["addFirstHost"].waitForExistence(timeout: 5))
    }

    @MainActor func testSettingsAndHostValidation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Terminal font preview"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.buttons["addFirstHost"].tap()
        app.textFields["hostName"].tap()
        app.textFields["hostName"].typeText("Bad host")
        app.textFields["hostAddress"].tap()
        app.textFields["hostAddress"].typeText("bad host")
        app.textFields["hostUsername"].tap()
        app.textFields["hostUsername"].typeText("root")
        XCTAssertFalse(app.buttons["saveHost"].isEnabled)
    }
}
