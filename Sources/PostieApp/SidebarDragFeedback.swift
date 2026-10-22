import SwiftUI
import PostieCore

enum SidebarDropEdge: Equatable {
    case before
    case after
}

enum SidebarDropTarget: Hashable {
    case collection(UUID)
    case request(RequestIdentity)
}

@MainActor
final class SidebarDragFeedback: ObservableObject {
    private struct Indicator: Equatable {
        let target: SidebarDropTarget
        let edge: SidebarDropEdge
    }

    @Published private var indicator: Indicator?

    func edge(for target: SidebarDropTarget) -> SidebarDropEdge? {
        guard indicator?.target == target else { return nil }
        return indicator?.edge
    }

    func setEdge(_ edge: SidebarDropEdge?, for target: SidebarDropTarget) {
        guard let edge else {
            clear(target: target)
            return
        }
        let nextIndicator = Indicator(target: target, edge: edge)
        guard indicator != nextIndicator else { return }
        indicator = nextIndicator
    }

    func sessionUpdated(_ phase: DragSession.Phase) {
        switch phase {
        case .initial, .ended(_):
            clear()
        case .active, .dataTransferCompleted:
            break
        @unknown default:
            break
        }
    }

    func clear() {
        guard indicator != nil else { return }
        indicator = nil
    }

    private func clear(target: SidebarDropTarget) {
        guard indicator?.target == target else { return }
        clear()
    }
}
