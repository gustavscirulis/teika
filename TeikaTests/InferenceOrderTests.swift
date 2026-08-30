import XCTest
@testable import Teika

final class InferenceOrderTests: XCTestCase {
    func testLocalTakesNextSlotWithoutReorderingWatchFIFO() {
        var order = InferenceOrder<String>()
        order.enqueueWatch("watch-1")
        order.enqueueWatch("watch-2")

        XCTAssertEqual(order.startNext(), "watch-1")
        order.enqueueLocal("phone")
        order.finish("watch-1")
        XCTAssertEqual(order.startNext(), "phone")
        order.finish("phone")
        XCTAssertEqual(order.startNext(), "watch-2")
    }

    func testCancellingQueuedLocalDoesNotAffectWatchWork() {
        var order = InferenceOrder<String>()
        order.enqueueWatch("watch-1")
        order.enqueueWatch("watch-2")
        XCTAssertEqual(order.startNext(), "watch-1")

        order.enqueueLocal("phone")
        order.cancelQueuedLocal("phone")
        order.finish("watch-1")
        XCTAssertEqual(order.startNext(), "watch-2")
    }

    func testOnlyOneJobCanOwnTheSlot() {
        var order = InferenceOrder<String>()
        order.enqueueWatch("watch-1")
        order.enqueueWatch("watch-2")
        XCTAssertEqual(order.startNext(), "watch-1")
        XCTAssertNil(order.startNext())
    }
}
