import XCTest

final class OBDBridgeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testWebShellLoadsOfflineContract() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-demo"]
        app.launch()

        let shell = app.webViews["OBD Web Shell"]
        XCTAssertTrue(shell.waitForExistence(timeout: 10))
        XCTAssertTrue(shell.staticTexts["OBD Bridge"].waitForExistence(timeout: 5))
        XCTAssertTrue(shell.buttons["Connect MX+"].exists)
        XCTAssertTrue(shell.buttons["Full snapshot"].exists)
        attachScreenshot(named: "01-web-shell")
    }

    func testWebShellExposesScrollableDiagnosticsControls() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-demo"]
        app.launch()

        let shell = app.webViews["OBD Web Shell"]
        XCTAssertTrue(shell.waitForExistence(timeout: 10))
        let send = shell.buttons["Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertTrue(shell.textFields["Read-only command"].exists)
        attachScreenshot(named: "02-web-shell-terminal")
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
