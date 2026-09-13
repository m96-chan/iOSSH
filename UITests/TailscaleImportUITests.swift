import XCTest

final class TailscaleImportUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testOnlySelectedDevicesAreSavedWithTheEnteredTailscaleSSHAccount() throws {
        let app = launchImport()
        defer { XCUIDevice.shared.orientation = .portrait }
        let save = app.buttons["saveTailscaleHosts"]
        XCTAssertFalse(save.isEnabled)

        let atlas = app.buttons["tailscaleDevice-atlas.tail-example.ts.net"]
        let zephyr = app.buttons["tailscaleDevice-zephyr.tail-example.ts.net"]
        let address = app.buttons["tailscaleDevice-100.64.0.23"]
        for candidate in [atlas, zephyr, address] {
            XCTAssertTrue(candidate.waitForExistence(timeout: 5))
            XCTAssertEqual(candidate.value as? String, "Not selected")
        }
        atlas.tap()
        zephyr.tap()
        XCTAssertEqual(atlas.value as? String, "Selected")
        XCTAssertEqual(zephyr.value as? String, "Selected")
        XCTAssertEqual(address.value as? String, "Not selected")
        XCTAssertEqual(save.label, "Add 2")
        XCTAssertFalse(save.isEnabled, "Selecting devices must not save hosts without an SSH username")

        let username = app.textFields["tailscaleImportUsername"]
        username.tap()
        username.typeText("tester")
        XCTAssertTrue(save.isEnabled)
        save.tap()
        let imported = app.alerts["Hosts Imported"]
        XCTAssertTrue(imported.waitForExistence(timeout: 5))
        XCTAssertTrue(imported.staticTexts["Added 2. Skipped 0 already registered."].exists)
        imported.buttons["Done"].tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 5))
        showCatalog(in: app)

        XCTAssertTrue(app.buttons["host-atlas"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["host-zephyr"].exists)
        XCTAssertFalse(app.buttons["host-100.64.0.23"].exists)
        XCTAssertEqual(savedHostButtons(in: app).count, 2)

        // Inspect saved values through the existing editor without opening SSH
        // sessions. Both devices must retain the explicitly chosen account.
        for name in ["atlas", "zephyr"] {
            app.buttons["host-\(name)"].swipeRight()
            // A full swipe invokes Edit immediately in the narrower iPad sidebar.
            if !app.textFields["hostAddress"].waitForExistence(timeout: 1) {
                app.buttons["Edit"].tap()
            }
            XCTAssertTrue(app.textFields["hostAddress"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.textFields["hostName"].value as? String, name)
            XCTAssertEqual(app.textFields["hostAddress"].value as? String, "\(name).tail-example.ts.net")
            XCTAssertEqual(app.textFields["hostUsername"].value as? String, "tester")
            XCTAssertEqual(app.textFields["hostPort"].value as? String, "22")
            let authentication = app.descendants(matching: .any)
                .matching(identifier: "hostAuthentication").firstMatch
            XCTAssertTrue(authentication.exists)
            XCTAssertTrue(authentication.value as? String == "Tailscale SSH"
                          || authentication.label.contains("Tailscale SSH"),
                          "Imported hosts must select Tailscale SSH authentication")
            app.navigationBars["Edit Host"].buttons["Cancel"].tap()
            XCTAssertTrue(app.textFields["hostAddress"].waitForNonExistence(timeout: 5))
        }
    }

    @MainActor
    func testCancelDiscardsTheImportAndShortcutSetupLeavesSettingsUsable() throws {
        let app = launchImport()
        defer { XCUIDevice.shared.orientation = .portrait }
        let username = app.textFields["tailscaleImportUsername"]
        username.tap()
        username.typeText("tester")
        let save = app.buttons["saveTailscaleHosts"]
        XCTAssertFalse(save.isEnabled, "An account alone must not select or register devices")
        app.buttons["tailscaleDevice-atlas.tail-example.ts.net"].tap()
        XCTAssertTrue(save.isEnabled)
        app.navigationBars["Import from Tailscale"].buttons["Cancel"].tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 5))
        showCatalog(in: app)
        XCTAssertTrue(app.buttons["addFirstHost"].exists)
        XCTAssertEqual(savedHostButtons(in: app).count, 0)

        app.buttons["importTailscaleHosts"].tap()
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled)
        XCTAssertFalse(app.textFields["tailscaleImportUsername"].exists,
                       "Cancel must discard the received list when import is reopened")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tailscaleDevice-")).count, 0)
        app.buttons["setupTailscaleShortcut"].tap()
        let setup = app.navigationBars["Set Up Shortcut"]
        XCTAssertTrue(setup.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["shareTailscaleShortcut"].exists)
        app.buttons["Create Manually"].tap()
        XCTAssertTrue(app.staticTexts["Tailscale → Find Devices"].exists)
        XCTAssertTrue(app.staticTexts["iOSSH → Review Tailscale Hosts"].exists)
        setup.buttons["Done"].tap()
        XCTAssertTrue(setup.waitForNonExistence(timeout: 5))
        app.navigationBars["Import from Tailscale"].buttons["Cancel"].tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 5))
        showCatalog(in: app)

        let settings = UIDevice.current.userInterfaceIdiom == .pad
            ? app.buttons["workspaceSettings"] : app.buttons["Settings"]
        settings.tap()
        XCTAssertTrue(app.staticTexts["Terminal font preview"].waitForExistence(timeout: 5))
        app.navigationBars["Settings"].buttons["Done"].tap()
        XCTAssertTrue(app.buttons["importTailscaleHosts"].waitForExistence(timeout: 5))
        XCTAssertEqual(savedHostButtons(in: app).count, 0)
    }

    @MainActor
    private func launchImport() -> XCUIApplication {
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-tailscale-import"]
        app.launch()
        XCTAssertTrue(app.buttons["saveTailscaleHosts"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["tailscaleImportUsername"].exists)
        return app
    }

    @MainActor
    private func showCatalog(in app: XCUIApplication) {
        let importButton = app.buttons["importTailscaleHosts"]
        if UIDevice.current.userInterfaceIdiom == .pad && !importButton.isHittable {
            let sidebar = app.buttons["workspaceSidebarToggle"]
            if sidebar.exists && sidebar.label == "Show Sidebar" { sidebar.tap() }
        }
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
    }

    @MainActor
    private func savedHostButtons(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "host-"))
    }
}
