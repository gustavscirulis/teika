import XCTest
@testable import TeikaWatch

@MainActor
final class WatchGateTests: XCTestCase {
    func testPriorSetupPermitsRecordingWithoutAnyReachabilityInput() {
        XCTAssertTrue(
            WatchLink.recordingGateIsOpen(
                permissionDenied: false, sessionActivated: true,
                companionInstalled: true, modelReady: true))
    }

    func testNeverConfiguredPhoneRemainsBlocked() {
        XCTAssertFalse(
            WatchLink.recordingGateIsOpen(
                permissionDenied: false, sessionActivated: true,
                companionInstalled: true, modelReady: false))
    }

    func testLocalPrerequisitesRemainRequired() {
        XCTAssertFalse(
            WatchLink.recordingGateIsOpen(
                permissionDenied: true, sessionActivated: true,
                companionInstalled: true, modelReady: true))
        XCTAssertFalse(
            WatchLink.recordingGateIsOpen(
                permissionDenied: false, sessionActivated: false,
                companionInstalled: true, modelReady: true))
        XCTAssertFalse(
            WatchLink.recordingGateIsOpen(
                permissionDenied: false, sessionActivated: true,
                companionInstalled: false, modelReady: true))
    }
}
