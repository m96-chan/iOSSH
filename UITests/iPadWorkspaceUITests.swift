import XCTest

final class iPadWorkspaceUITests: XCTestCase {
    @MainActor func testRetainedTabsDeferAuthenticationDuplicatesAndLimit() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad workspace") }
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        addHost("Development", in: app)
        addHost("Logs", in: app)
        app.buttons["host-Development"].tap()
        deferCredential(in: app)
        XCTAssertTrue(app.buttons["resumeAuthentication"].waitForExistence(timeout: 5))
        app.buttons["host-Logs"].tap()
        deferCredential(in: app)
        let development = app.buttons["sessionTab-Development"]
        XCTAssertTrue(development.exists)
        development.tap()
        XCTAssertTrue(app.buttons["resumeAuthentication"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.secureTextFields["Password"].exists)
        app.buttons["resumeAuthentication"].tap()
        XCTAssertTrue(app.secureTextFields["Password"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Reconnect"].waitForExistence(timeout: 5))
        app.buttons["sessionTab-Logs"].tap()
        XCTAssertTrue(app.buttons["resumeAuthentication"].waitForExistence(timeout: 5))

        for _ in 0..<2 {
            app.buttons["newSession"].tap()
            XCTAssertTrue(app.buttons["pickHost-Development"].waitForExistence(timeout: 5))
            app.buttons["pickHost-Development"].tap()
            deferCredential(in: app)
        }
        XCTAssertTrue(app.buttons["sessionTab-Development (1)"].exists)
        XCTAssertTrue(app.buttons["sessionTab-Development (2)"].exists)
        XCTAssertTrue(app.buttons["sessionTab-Development (3)"].exists)
        app.buttons["newSession"].tap()
        XCTAssertTrue(app.alerts["Four sessions are already open"].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(app.alerts["Four sessions are already open"].waitForNonExistence(timeout: 5))
        app.buttons["Close Development (2)"].tap()
        XCTAssertTrue(app.buttons["sessionTab-Development (3)"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["sessionTab-Logs"].exists)
        app.buttons["sessionTab-Logs"].tap()
        XCTAssertTrue(app.buttons["resumeAuthentication"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "iPad retained tabs and deferred authentication"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor func testRotationSidebarAndKeyboardKeepTheTerminalUsable() async throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad workspace") }
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        addHost("Viewport", in: app)
        app.buttons["host-Viewport"].tap()
        XCTAssertTrue(app.secureTextFields["Password"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Reconnect"].waitForExistence(timeout: 5))
        let terminal = app.descendants(matching: .any).matching(identifier: "terminal").firstMatch
        terminal.tap()
        try await assertTerminalAboveAccessory(app)
        let before = terminal.frame.width
        let sidebar = app.buttons["Hide Sidebar"]
        if sidebar.exists {
            sidebar.tap()
            try await Task.sleep(for: .milliseconds(700))
            XCTAssertGreaterThan(terminal.frame.width, before)
            try await assertTerminalAboveAccessory(app)
        }
        XCUIDevice.shared.orientation = .portrait
        try await assertTerminalAboveAccessory(app)
        XCTAssertTrue(app.buttons["sessionTab-Viewport"].exists)
        XCUIDevice.shared.press(.home)
        app.activate()
        if !app.buttons["terminalAccessoryControl"].waitForExistence(timeout: 2) { terminal.tap() }
        try await assertTerminalAboveAccessory(app)
        XCTAssertFalse(app.secureTextFields["Password"].exists)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "iPad terminal after sidebar, rotation, and foreground"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor private func addHost(_ name: String, in app: XCUIApplication) {
        let button = app.buttons["addHost"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        app.textFields["hostName"].tap()
        app.textFields["hostName"].typeText(name)
        app.textFields["hostAddress"].tap()
        app.textFields["hostAddress"].typeText("192.0.2.1")
        app.textFields["hostUsername"].tap()
        app.textFields["hostUsername"].typeText("tester")
        app.buttons["saveHost"].tap()
        XCTAssertTrue(app.buttons["host-\(name)"].waitForExistence(timeout: 5))
    }

    @MainActor private func deferCredential(in app: XCUIApplication) {
        XCTAssertTrue(app.secureTextFields["Password"].waitForExistence(timeout: 10))
        app.buttons["deferAuthentication"].tap()
        XCTAssertTrue(app.buttons["resumeAuthentication"].waitForExistence(timeout: 5))
    }

    @MainActor private func assertTerminalAboveAccessory(_ app: XCUIApplication) async throws {
        let control = app.buttons["terminalAccessoryControl"]
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        let terminal = app.descendants(matching: .any).matching(identifier: "terminal").firstMatch
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if terminal.frame.height > 20 && terminal.frame.maxY <= control.frame.minY - 3 { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Terminal \(terminal.frame) overlaps accessory \(control.frame)")
    }
}
