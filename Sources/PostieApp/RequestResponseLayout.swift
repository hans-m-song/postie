import SwiftUI

enum RequestResponseLayout: String, CaseIterable, Identifiable {
    case sideBySide
    case stacked

    static let preferenceKey = "requestResponseLayout"

    var id: Self { self }

    var title: String {
        switch self {
        case .sideBySide: "Side by Side"
        case .stacked: "Stacked"
        }
    }

    var symbolName: String {
        switch self {
        case .sideBySide: "rectangle.split.2x1"
        case .stacked: "rectangle.split.1x2"
        }
    }

    var isVertical: Bool { self == .sideBySide }

    var requestMinimumThickness: CGFloat {
        switch self {
        case .sideBySide: 320
        case .stacked: 220
        }
    }

    var responseMinimumThickness: CGFloat {
        switch self {
        case .sideBySide: 300
        case .stacked: 180
        }
    }
}
