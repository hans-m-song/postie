import AppKit
import PostieCore
import SwiftUI

@MainActor
struct RequestResponseSplit: NSViewControllerRepresentable {
    let model: AppModel
    let identity: RequestIdentity
    let layout: RequestResponseLayout

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSViewController(context: Context) -> NSSplitViewController {
        let splitController = NSSplitViewController()
        splitController.splitView.dividerStyle = .thin

        let requestController = NSHostingController(
            rootView: RequestPaneRoot(model: model, identity: identity)
        )
        requestController.sizingOptions = []
        let requestItem = NSSplitViewItem(viewController: requestController)
        requestItem.preferredThicknessFraction = 0.5
        requestItem.canCollapse = false
        requestItem.canCollapseFromWindowResize = false

        let responseController = NSHostingController(
            rootView: ResponsePaneRoot(model: model, identity: identity)
        )
        responseController.sizingOptions = []
        let responseItem = NSSplitViewItem(viewController: responseController)
        responseItem.preferredThicknessFraction = 0.5
        responseItem.canCollapse = false
        responseItem.canCollapseFromWindowResize = false

        splitController.addSplitViewItem(requestItem)
        splitController.addSplitViewItem(responseItem)
        configure(splitController)

        context.coordinator.requestController = requestController
        context.coordinator.responseController = responseController
        context.coordinator.requestIdentity = identity
        context.coordinator.modelIdentifier = ObjectIdentifier(model)
        return splitController
    }

    func updateNSViewController(_ splitController: NSSplitViewController, context: Context) {
        let coordinator = context.coordinator
        let modelIdentifier = ObjectIdentifier(model)
        if coordinator.modelIdentifier != modelIdentifier || coordinator.requestIdentity != identity {
            coordinator.requestController?.rootView = RequestPaneRoot(model: model, identity: identity)
            coordinator.responseController?.rootView = ResponsePaneRoot(model: model, identity: identity)
            coordinator.modelIdentifier = modelIdentifier
            coordinator.requestIdentity = identity
        }

        configure(splitController)
    }

    private func configure(_ splitController: NSSplitViewController) {
        let splitView = splitController.splitView
        let layoutChanged = splitView.isVertical != layout.isVertical
        let splitItems = splitController.splitViewItems
        splitItems[0].minimumThickness = layout.requestMinimumThickness
        splitItems[1].minimumThickness = layout.responseMinimumThickness

        if layoutChanged {
            splitItems.forEach { $0.preferredThicknessFraction = 0.5 }
        }

        splitView.isVertical = layout.isVertical
    }

    @MainActor
    final class Coordinator {
        fileprivate var requestController: NSHostingController<RequestPaneRoot>?
        fileprivate var responseController: NSHostingController<ResponsePaneRoot>?
        fileprivate var requestIdentity: RequestIdentity?
        fileprivate var modelIdentifier: ObjectIdentifier?
    }
}

@MainActor
private struct RequestPaneRoot: View {
    let model: AppModel
    let identity: RequestIdentity

    var body: some View {
        RequestEditorView(identity: identity)
            .environmentObject(model)
            .environment(\.variableInspectionOwner, .request(identity))
    }
}

@MainActor
private struct ResponsePaneRoot: View {
    let model: AppModel
    let identity: RequestIdentity

    var body: some View {
        ResponseView(identity: identity)
            .environmentObject(model)
    }
}
