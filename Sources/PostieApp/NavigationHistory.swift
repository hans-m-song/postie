import Foundation
import PostieCore

enum NavigationLocation: Hashable {
    case request(RequestIdentity, section: RequestEditorSection)
    case requestVariableDefinition(RequestIdentity, name: String)
    case collection(UUID, section: CollectionEditorSection)
    case globalVariables
    case ongoingRequests
}

struct NavigationHistory {
    static let defaultLimit = 100

    private let limit: Int
    private(set) var locations: [NavigationLocation] = []
    private(set) var currentIndex: Int?

    init(limit: Int = Self.defaultLimit) {
        self.limit = max(1, limit)
    }

    func canGoBack(to availableLocations: Set<NavigationLocation>) -> Bool {
        guard let currentIndex, currentIndex > 0 else { return false }
        return (0..<currentIndex).contains { availableLocations.contains(locations[$0]) }
    }

    func canGoForward(to availableLocations: Set<NavigationLocation>) -> Bool {
        guard let currentIndex, currentIndex + 1 < locations.count else { return false }
        return ((currentIndex + 1)..<locations.count).contains { availableLocations.contains(locations[$0]) }
    }

    mutating func visit(_ location: NavigationLocation) {
        if let currentIndex, locations[currentIndex] == location { return }

        if let currentIndex {
            locations.removeSubrange((currentIndex + 1)..<locations.count)
        }

        locations.append(location)
        let lastIndex = locations.count - 1
        currentIndex = lastIndex

        let overflow = locations.count - limit
        guard overflow > 0 else { return }
        locations.removeFirst(overflow)
        currentIndex = lastIndex - overflow
    }

    mutating func goBack(to availableLocations: Set<NavigationLocation>) -> NavigationLocation? {
        guard let currentIndex, currentIndex > 0 else { return nil }
        for index in (0..<currentIndex).reversed() where availableLocations.contains(locations[index]) {
            self.currentIndex = index
            return locations[index]
        }
        return nil
    }

    mutating func goForward(to availableLocations: Set<NavigationLocation>) -> NavigationLocation? {
        guard let currentIndex, currentIndex + 1 < locations.count else { return nil }
        for index in (currentIndex + 1)..<locations.count where availableLocations.contains(locations[index]) {
            self.currentIndex = index
            return locations[index]
        }
        return nil
    }
}
