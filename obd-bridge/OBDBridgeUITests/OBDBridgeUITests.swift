import XCTest

final class OBDBridgeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPrimaryDiagnosticNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-demo"]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Diagnose"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Start logging"].exists)
        XCTAssertTrue(app.staticTexts["P2188 / fuel trims"].exists)
        attachScreenshot(named: "01-diagnose")

        app.tabBars.buttons["Live Data"].tap()
        XCTAssertTrue(app.staticTexts["Latest decoded values"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Engine RPM"].exists)
        attachScreenshot(named: "02-live-data")

        app.tabBars.buttons["Files"].tap()
        XCTAssertTrue(app.staticTexts["Saved session"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Read-only safety"].exists)
        attachScreenshot(named: "03-files")
    }

    func testAdvancedToolsAreCollapsedByDefault() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-demo"]
        app.launch()
        app.tabBars.buttons["Live Data"].tap()

        XCTAssertFalse(app.textFields["Read-only command"].exists)
        app.buttons["Advanced tools"].tap()
        XCTAssertTrue(app.textFields["Read-only command"].waitForExistence(timeout: 3))
        attachScreenshot(named: "04-advanced-tools")
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
