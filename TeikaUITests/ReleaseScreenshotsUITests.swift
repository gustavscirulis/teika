import XCTest

final class ReleaseScreenshotsUITests: XCTestCase {
    func testAutomatedNotesUseSampleContent() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-teika-release-screenshot", "notes"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Notes"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Groceries, olive oil, rice, two lemons, coffee beans."].exists)
        XCTAssertFalse(app.buttons["Set Up Transcription"].exists)
    }

    func testAutomatedSettingsShowRemindersWithoutPermissions() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-teika-release-screenshot", "settings"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["taskExportApp"].exists)
        XCTAssertTrue(app.buttons["taskExportApp"].label.contains("Apple Reminders"))
        XCTAssertTrue(app.buttons["reminderExportList"].exists)
        XCTAssertTrue(app.buttons["reminderExportList"].label.contains("Reminders"))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Schedule")).firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["Get Things"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }
}
