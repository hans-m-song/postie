import Foundation
import XCTest
@testable import PostieApp

@MainActor
final class ResponseBodyResourceTests: XCTestCase {
    func testInvalidationClearsConsumersBeforeReleasingAndReleasesOnce() async {
        var events: [String] = []
        let resource = ResponseBodyResource(
            url: URL(fileURLWithPath: "/synthetic/body"),
            origin: .snapshot(UUID()),
            release: { events.append("release") }
        )
        _ = resource.registerInvalidation { events.append("clear") }

        await resource.invalidate()
        await resource.invalidate()

        XCTAssertFalse(resource.isValid)
        XCTAssertEqual(events, ["clear", "release"])
    }

    func testRemovedConsumerIsNotCalledAndLateConsumerClearsImmediately() async {
        var removedWasCalled = false
        var lateWasCalled = false
        let resource = ResponseBodyResource(
            url: URL(fileURLWithPath: "/synthetic/body"),
            origin: .live(UUID())
        )
        let registration = resource.registerInvalidation { removedWasCalled = true }
        resource.removeInvalidationHandler(registration)
        await resource.invalidate()
        _ = resource.registerInvalidation { lateWasCalled = true }

        XCTAssertFalse(removedWasCalled)
        XCTAssertTrue(lateWasCalled)
    }
}
