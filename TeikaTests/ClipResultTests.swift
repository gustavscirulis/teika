import XCTest
@testable import Teika

final class ClipResultTests: XCTestCase {
    func testDeferredOutcomeRoundTrips() {
        let result = ClipResult(
            clipID: "clip-1", outcome: .deferred, characters: 0,
            message: "Queued on iPhone")
        XCTAssertEqual(result.encoded().flatMap(ClipResult.decode), result)
    }
}
