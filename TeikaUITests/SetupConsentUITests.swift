import XCTest

final class SetupConsentUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-taskExportApp", "off"]
        app.launch()
    }

    func testDownloadRequiresExplicitConfirmationAndCanBeDeclined() throws {
        let setupButton = app.buttons["Set Up Transcription"]
        XCTAssertTrue(setupButton.waitForExistence(timeout: 5))

        setupButton.tap()

        XCTAssertTrue(app.staticTexts["Download speech model?"].waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(
                    format: "label CONTAINS %@ AND label CONTAINS %@ AND label CONTAINS %@",
                    "0.5 GB",
                    "standard connection information",
                    "transcription happens locally on your iPhone"
                )
            ).firstMatch.exists
        )
        XCTAssertTrue(app.buttons["Not Now"].exists)
        XCTAssertTrue(app.buttons["Download 0.5 GB"].exists)
        keepScreenshot(named: "Download consent")

        app.buttons["Not Now"].tap()

        XCTAssertTrue(setupButton.waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Download speech model?"].exists)
        XCTAssertFalse(app.progressIndicators.firstMatch.exists)
    }

    func testSettingsAndAboutLinksAreAvailableFromNotesList() throws {
        let notesButton = app.buttons["Notes"]
        XCTAssertTrue(notesButton.waitForExistence(timeout: 5))
        notesButton.tap()

        let linksButton = app.buttons["Settings"]
        XCTAssertTrue(linksButton.waitForExistence(timeout: 2))
        linksButton.tap()

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 2))
        let appPicker = app.buttons["taskExportApp"]
        XCTAssertTrue(appPicker.waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["Destination"].exists)
        XCTAssertFalse(app.buttons["reminderExportList"].exists)
        appPicker.tap()
        XCTAssertTrue(app.buttons["Apple Reminders"].waitForExistence(timeout: 2))
        app.buttons["Things"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Destination")).firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["Get Things"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["Privacy Policy"].firstMatch.waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["Support"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["View Source"].firstMatch.exists)
        keepScreenshot(named: "Settings")
        appPicker.tap()
        app.buttons["Off"].tap()
        app.navigationBars["Settings"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Notes"].waitForExistence(timeout: 2))
    }

    func testAffirmativeActionStartsModelDownload() throws {
        let liveDownloadEnabled =
            Bundle(for: Self.self).object(forInfoDictionaryKey: "RUN_MODEL_DOWNLOAD_TEST") as? Bool
            ?? false
        guard liveDownloadEnabled else {
            throw XCTSkip("Pass RUN_MODEL_DOWNLOAD_TEST=YES to exercise the live 0.5 GB download.")
        }
        defer { app.terminate() }

        let setupButton = app.buttons["Set Up Transcription"]
        XCTAssertTrue(setupButton.waitForExistence(timeout: 5))
        setupButton.tap()

        let downloadButton = app.buttons["Download 0.5 GB"]
        XCTAssertTrue(downloadButton.waitForExistence(timeout: 2))
        downloadButton.tap()

        let downloadStatus = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Downloading model")
        ).firstMatch
        XCTAssertTrue(downloadStatus.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Start recording"].isEnabled)
    }

    private func keepScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
