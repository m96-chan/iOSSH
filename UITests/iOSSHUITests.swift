import XCTest

final class iOSSHUITests: XCTestCase {
    @MainActor func testJapaneseKanaKeyboardComposesAndConfirmsLocally() async throws {
        try skipUnlessPhone("The kana keyboard this drives is the iPhone layout")
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.buttons["addFirstHost"].tapWhenReady()
        app.textFields["hostName"].typeWhenReady("Japanese input")
        app.textFields["hostAddress"].typeWhenReady("192.0.2.1")
        app.textFields["hostUsername"].typeWhenReady("tester")
        app.buttons["saveHost"].tapWhenReady()
        app.buttons["host-Japanese input"].tapWhenReady()
        XCTAssertTrue(app.secureTextFields["Password"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tapWhenReady()
        XCTAssertTrue(app.buttons["Reconnect"].waitForExistence(timeout: 5))
        let terminal = app.descendants(matching: .any).matching(identifier: "terminal").firstMatch
        terminal.tap()
        XCTAssertTrue(app.buttons["terminalAccessoryControl"].waitForExistence(timeout: 5))

        for _ in 0..<5 where !app.keys["あ"].exists {
            let globe = app.buttons.matching(NSPredicate(format: "label IN %@", ["Next keyboard", "次のキーボード"])).firstMatch
            guard globe.exists else { break }
            globe.tap()
        }
        guard app.keys["あ"].exists else {
            throw XCTSkip("Enable the Japanese Kana keyboard on this simulator to exercise real conversion keys.")
        }
        app.keys["か"].tap()
        app.keys["な"].tap()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(terminal.value as? String ?? "").contains("かな"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue((terminal.value as? String ?? "").contains("かな"), "Kana must remain visible as local marked text.")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Japanese kana preedit and native candidate bar"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        // Kana Return is exposed as a Button with identifier Return and label 改行.
        // The parent accessibility element intentionally isn't the UITextInput proxy.
        let confirm = app.buttons["Return"]
        XCTAssertTrue(confirm.exists)
        let candidate = app.cells["仮名"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 5), "The native IME must offer a kanji conversion candidate.")
        candidate.tap()
        if !(terminal.value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { confirm.tap() }
        let confirmedDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(terminal.value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, ContinuousClock.now < confirmedDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        // This canceled connection has no remote echo. Confirmed text therefore leaves
        // the local editor; deterministic tests verify the exact outgoing UTF-8 bytes.
        XCTAssertTrue((terminal.value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        app.keys["か"].tap()
        app.keys["な"].tap()
        XCTAssertTrue((terminal.value as? String ?? "").contains("かな"))
        confirm.tap()
        let returnDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(terminal.value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, ContinuousClock.now < returnDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue((terminal.value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        try await assertTerminalIsAboveAccessory(app)
    }

    @MainActor func testTerminalViewportSurvivesKeyboardForegroundAndReconnect() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.buttons["addFirstHost"].tapWhenReady()
        app.textFields["hostName"].typeWhenReady("Viewport")
        app.textFields["hostAddress"].typeWhenReady("192.0.2.1")
        app.textFields["hostUsername"].typeWhenReady("tester")
        app.buttons["saveHost"].tapWhenReady()
        app.buttons["host-Viewport"].tap()
        XCTAssertTrue(app.secureTextFields["Password"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tapWhenReady()
        XCTAssertTrue(app.buttons["Reconnect"].waitForExistence(timeout: 5))
        let terminal = app.descendants(matching: .any).matching(identifier: "terminal").firstMatch
        terminal.tap()
        try await assertTerminalIsAboveAccessory(app)

        XCUIDevice.shared.press(.home)
        app.activate()
        if !app.buttons["terminalAccessoryControl"].waitForExistence(timeout: 2) { terminal.tap() }
        try await assertTerminalIsAboveAccessory(app)

        app.buttons["Reconnect"].tap()
        XCTAssertTrue(app.secureTextFields["Password"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tapWhenReady()
        terminal.tap()
        try await assertTerminalIsAboveAccessory(app)

        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        try await assertTerminalIsAboveAccessory(app)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Terminal viewport after foreground and reconnect"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// The iPad workspace reaches the same behaviour through its own chrome, and its tests
    /// guard the other way around. Without this, a full-suite run on an iPad fails on
    /// controls that only the iPhone screen has.
    @MainActor private func skipUnlessPhone(_ reason: String) throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip(reason) }
    }

    @MainActor private func assertTerminalIsAboveAccessory(_ app: XCUIApplication,
                                                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let control = app.buttons["terminalAccessoryControl"]
        XCTAssertTrue(control.waitForExistence(timeout: 5), file: file, line: line)
        let terminal = app.descendants(matching: .any).matching(identifier: "terminal").firstMatch
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            // Accessory buttons have a four-point top inset. The accessible terminal
            // rectangle is the same viewport used to calculate and publish PTY rows.
            if terminal.frame.height > 20 && terminal.frame.maxY <= control.frame.minY - 3 { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Terminal \(terminal.frame) overlaps keyboard accessory \(control.frame)", file: file, line: line)
    }

    @MainActor func testTerminalConnectionCanBeCanceled() throws {
        try skipUnlessPhone("Closing a session uses the iPhone screen's floating control")
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.buttons["addFirstHost"].tapWhenReady()
        app.textFields["hostName"].typeWhenReady("Terminal test")
        app.textFields["hostAddress"].typeWhenReady("192.0.2.1")
        app.textFields["hostUsername"].typeWhenReady("tester")
        app.buttons["saveHost"].tapWhenReady()
        app.buttons["host-Terminal test"].tap()
        XCTAssertTrue(app.secureTextFields["Password"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tapWhenReady()
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
        try skipUnlessPhone("Editing a host uses the iPhone host list, not the iPad sidebar")
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["addFirstHost"].waitForExistence(timeout: 10))
        app.buttons["addFirstHost"].tapWhenReady()
        XCTAssertFalse(app.buttons["saveHost"].isEnabled)
        app.textFields["hostName"].typeWhenReady("Development")
        app.textFields["hostAddress"].typeWhenReady("192.0.2.1")
        app.textFields["hostUsername"].typeWhenReady("developer")
        app.buttons["saveHost"].tapWhenReady()
        let host = app.buttons["host-Development"]
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        host.swipeRight()
        app.buttons["Edit"].tap()
        XCTAssertEqual(app.textFields["hostAddress"].value as? String, "192.0.2.1")
        XCTAssertEqual(app.textFields["hostUsername"].value as? String, "developer")
        app.buttons["Cancel"].tapWhenReady()
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
        let privacyPolicyLink = app.descendants(matching: .any)["privacyPolicyLink"]
        for _ in 0..<4 {
            if privacyPolicyLink.exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(privacyPolicyLink.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["supportLink"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.buttons["addFirstHost"].tapWhenReady()
        app.textFields["hostName"].typeWhenReady("Bad host")
        app.textFields["hostAddress"].typeWhenReady("bad host")
        app.textFields["hostUsername"].typeWhenReady("root")
        XCTAssertFalse(app.buttons["saveHost"].isEnabled)
    }
}
