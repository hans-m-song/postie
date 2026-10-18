import AppKit
import PostieCore
import SwiftUI

@MainActor
struct RequestResponseSplit: NSViewControllerRepresentable {
    let model: AppModel
    let identity: RequestIdentity

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSViewController(context: Context) -> NSSplitViewController {
        let splitController = NSSplitViewController()
        splitController.splitView.isVertical = true
        splitController.splitView.dividerStyle = .thin

        let requestController = NSHostingController(
            rootView: RequestPaneRoot(model: model, identity: identity)
        )
        requestController.sizingOptions = []
        let requestItem = NSSplitViewItem(viewController: requestController)
        requestItem.minimumThickness = 320
        requestItem.preferredThicknessFraction = 0.5
        requestItem.canCollapse = false
        requestItem.canCollapseFromWindowResize = false

        let responseController = NSHostingController(
            rootView: ResponsePaneRoot(model: model, identity: identity)
        )
        responseController.sizingOptions = []
        let responseItem = NSSplitViewItem(viewController: responseController)
        responseItem.minimumThickness = 300
        responseItem.preferredThicknessFraction = 0.5
        responseItem.canCollapse = false
        responseItem.canCollapseFromWindowResize = false

        splitController.addSplitViewItem(requestItem)
        splitController.addSplitViewItem(responseItem)
        context.coordinator.requestController = requestController
        context.coordinator.responseController = responseController
        return splitController
    }

    func updateNSViewController(_ splitController: NSSplitViewController, context: Context) {
        context.coordinator.requestController?.rootView = RequestPaneRoot(model: model, identity: identity)
        context.coordinator.responseController?.rootView = ResponsePaneRoot(model: model, identity: identity)
    }

    @MainActor
    final class Coordinator {
        fileprivate var requestController: NSHostingController<RequestPaneRoot>?
        fileprivate var responseController: NSHostingController<ResponsePaneRoot>?
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
