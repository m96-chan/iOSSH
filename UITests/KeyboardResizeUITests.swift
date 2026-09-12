import XCTest

final class KeyboardResizeUITests: XCTestCase {
    @MainActor func testRepeatedKeyboardDismissalRestoresTheFullTerminalHeight() async throws {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["addHost"].waitForExistence(timeout: 5))
        app.buttons["addHost"].tap()
        app.textFields["hostName"].tap()
        app.textFields["hostName"].typeText("Keyboard resize")
        app.textFields["hostAddress"].tap()
        app.textFields["hostAddress"].typeText("192.0.2.1")
        app.textFields["hostUsername"].tap()
        app.textFields["hostUsername"].typeText("tester")
        app.buttons["saveHost"].tap()
        app.buttons["host-Keyboard resize"].tap()
        XCTAssertTrue(app.secureTextFields["Password"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Reconnect"].waitForExistence(timeout: 5))
        let terminal = app.descendants(matching: .any).matching(identifier: "terminal").firstMatch
        let control = app.buttons["terminalAccessoryControl"]
        var expandedHeight: CGFloat?

        for cycle in 0..<3 {
            terminal.tap()
            XCTAssertTrue(control.waitForExistence(timeout: 5))
            try await waitUntil("The terminal should stop above the accessory") {
                terminal.frame.height > 20 && terminal.frame.maxY <= control.frame.minY - 3
            }
            try await waitUntil("Enable the simulator software keyboard before running this test") {
                control.frame.minY < app.windows.firstMatch.frame.maxY - 150
            }
            let keyboardHeight = terminal.frame.height
            let terminalTop = terminal.frame.minY
            // iPad can hide its keyboard with either the app accessory or the
            // system keyboard's own button; exercise both dismissal paths.
            if isPad && cycle == 2 {
                let dismiss = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@",
                                                               "Hide keyboard", "terminalDismissKeyboard")).firstMatch
                XCTAssertTrue(dismiss.exists)
                dismiss.tap()
            } else {
                try await dismissAccessoryKeyboard(in: app)
            }
            if isPad && cycle == 2 {
                // UIKit may leave the accessory visible when its own button
                // collapses the software keyboard. Fill up to that live bar,
                // then dismiss the accessory too to recover the full height.
                try await waitUntil("Collapsing the iPad keyboard should reveal more terminal rows") {
                    terminal.frame.height > keyboardHeight + 100
                }
                if control.exists {
                    try await waitUntil("The terminal must fill up to the remaining accessory") {
                        let gap = control.frame.minY - terminal.frame.maxY
                        return gap >= 3 && gap <= 20
                    }
                    try await dismissAccessoryKeyboard(in: app)
                }
            }
            XCTAssertTrue(control.waitForNonExistence(timeout: 5))
            try await waitUntil("The terminal must fill the available height after dismissal: \(terminal.frame), window=\(app.windows.firstMatch.frame)") {
                let gap = app.windows.firstMatch.frame.maxY - terminal.frame.maxY
                return terminal.frame.height > keyboardHeight + 100 && gap <= (isPad ? 40 : 50)
            }
            XCTAssertEqual(terminal.frame.minY, terminalTop, accuracy: 1)
            if let expandedHeight {
                XCTAssertEqual(terminal.frame.height, expandedHeight, accuracy: 1,
                               "Repeated toggles must not accumulate padding")
            } else {
                expandedHeight = terminal.frame.height
            }
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "Keyboard hidden \(isPad ? "iPad" : "iPhone") cycle \(cycle + 1)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }

    @MainActor private func dismissAccessoryKeyboard(in app: XCUIApplication) async throws {
        let dismiss = app.buttons["terminalDismissKeyboard"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        // On narrow phones the last accessory key needs a horizontal scroll.
        // XCTest's implicit scroll-to-tap can leave it without a hit point, so
        // perform the same swipe a user would before tapping the visible key.
        let scroll = app.scrollViews.containing(.button, identifier: "terminalDismissKeyboard").firstMatch
        for _ in 0..<2 where !dismiss.isHittable {
            XCTAssertTrue(scroll.exists)
            scroll.swipeLeft()
        }
        try await waitUntil("The accessory's Hide keyboard button must be tappable after scrolling") {
            dismiss.isHittable
        }
        dismiss.tap()
    }

    @MainActor private func waitUntil(_ message: @autoclosure () -> String, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            if ContinuousClock.now >= deadline {
                let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                screenshot.name = "Keyboard resize failure"
                screenshot.lifetime = .keepAlways
                add(screenshot)
                XCTFail(message())
                throw WaitError.timedOut
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private enum WaitError: Error { case timedOut }
}
