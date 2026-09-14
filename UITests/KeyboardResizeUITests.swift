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
        // `waitForExistence` returns while the sheet is still animating in, and on an iPad the
        // credential prompt is a form sheet that travels further and settles later than the
        // iPhone's. A tap delivered mid-animation is dropped: the sheet stays up, the connection
        // stays in `.connecting`, and the button waited for below — which `TerminalScreen` only
        // draws once the phase leaves `.connecting` — never appears at all (#35). The same
        // settling wait guards every other button this test taps.
        let cancel = app.buttons["Cancel"]
        try await waitUntil("The credential sheet's Cancel must settle before it is tapped") { cancel.isHittable }
        cancel.tap()
        // Through `waitUntil` rather than `waitForExistence` so a failure here keeps a
        // screenshot. Cancelling resumes the credential continuation with nil and the connection
        // reports `.disconnected`, so the button is the visible end of that path; a screenshot is
        // what would say whether a future failure is the sheet still being up or the phase not
        // having moved.
        try await waitUntil("Cancelling the credential prompt must offer Reconnect") {
            app.buttons["Reconnect"].exists
        }
        let terminal = app.descendants(matching: .any).matching(identifier: "terminal").firstMatch
        let control = app.buttons["terminalAccessoryControl"]
        var expandedHeight: CGFloat?

        for cycle in 0..<3 {
            terminal.tap()
            XCTAssertTrue(control.waitForExistence(timeout: 5))
            if cycle == 0 { try await dismissKeyboardIntroduction(in: app) }
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

    @MainActor private func dismissKeyboardIntroduction(in app: XCUIApplication) async throws {
        // A fresh English keyboard shows the QuickPath tutorial over the keys
        // and accessory. Its hidden buttons still exist in the AX hierarchy.
        let introduction = app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Speed up your typing by sliding your finger"
        )).firstMatch
        guard introduction.waitForExistence(timeout: 2) else { return }
        let proceed = app.buttons["Continue"]
        try await waitUntil("The keyboard introduction must offer Continue") { proceed.isHittable }
        proceed.tap()
        XCTAssertTrue(introduction.waitForNonExistence(timeout: 5))
    }

    @MainActor private func dismissAccessoryKeyboard(in app: XCUIApplication) async throws {
        let dismiss = app.buttons["terminalDismissKeyboard"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        // Reveal the last accessory key on narrow phones with the same
        // horizontal swipe a user would perform before tapping it.
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
        // Twenty seconds, not five. This is how long the test waits before giving up, not a
        // claim about how fast anything has to be, and five is short on a runner that has been
        // building for half an hour and is on its second simulator.
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
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
