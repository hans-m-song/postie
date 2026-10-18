import XCTest
import PostieCore
@testable import PostieApp

final class NavigationHistoryTests: XCTestCase {
    func testDuplicateVisitsAreIgnoredAndNewVisitClearsForwardHistory() {
        var history = NavigationHistory()
        let first = requestLocation()
        let second = requestLocation()
        let third = requestLocation()
        let fourth = requestLocation()

        history.visit(first)
        history.visit(first)
        history.visit(second)
        history.visit(third)

        XCTAssertEqual(history.locations.count, 3)
        XCTAssertEqual(history.goBack(to: Set(history.locations)), second)
        history.visit(fourth)

        XCTAssertFalse(history.canGoForward(to: Set(history.locations)))
        XCTAssertEqual(history.goBack(to: Set(history.locations)), second)
    }

    func testHistoryKeepsOnlyTheMostRecentHundredLocations() {
        var history = NavigationHistory()
        var visited: [NavigationLocation] = []

        for _ in 0..<105 {
            let location = requestLocation()
            visited.append(location)
            history.visit(location)
        }

        XCTAssertEqual(history.locations.count, 100)
        XCTAssertEqual(history.locations.first, visited[5])
        XCTAssertEqual(history.locations.last, visited[104])
    }

    func testBackAndForwardSkipUnavailableLocations() {
        var history = NavigationHistory()
        let first = requestLocation()
        let deleted = requestLocation()
        let stale = requestLocation()
        let current = requestLocation()
        for location in [first, deleted, stale, current] {
            history.visit(location)
        }
        let available = Set([first, current])

        XCTAssertTrue(history.canGoBack(to: available))
        XCTAssertEqual(history.goBack(to: available), first)
        XCTAssertTrue(history.canGoForward(to: available))
        XCTAssertEqual(history.goForward(to: available), current)
    }

    private func requestLocation() -> NavigationLocation {
        let collectionID = UUID()
        let requestID = UUID()
        return .request(RequestIdentity(collectionID: collectionID, requestID: requestID), section: .request)
    }
}
