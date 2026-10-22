import SwiftUI

struct ResponseBodyViewportScrollView<Content: View>: View {
    private let contentPadding: CGFloat
    private let previewBottomInset: CGFloat
    private let content: Content

    init(
        contentPadding: CGFloat = 16,
        previewBottomInset: CGFloat = 0,
        @ViewBuilder content: () -> Content
    ) {
        self.contentPadding = contentPadding
        self.previewBottomInset = previewBottomInset
        self.content = content()
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                content
                    .environment(
                        \.responseBodyViewport,
                        ResponseBodyViewport(
                            height: viewport.size.height,
                            contentPadding: contentPadding,
                            previewBottomInset: previewBottomInset
                        )
                    )
                    .coordinateSpace(name: ResponseBodyViewport.contentCoordinateSpace)
                    .padding(contentPadding)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    func responseBodyViewportFilling() -> some View {
        modifier(ResponseBodyViewportFillModifier())
    }
}

enum ResponseBodyViewportSizing {
    static let minimumHeight: CGFloat = 280

    static func height(
        viewportHeight: CGFloat,
        previewTop: CGFloat,
        contentPadding: CGFloat,
        previewBottomInset: CGFloat = 0
    ) -> CGFloat {
        guard
            viewportHeight.isFinite,
            previewTop.isFinite,
            contentPadding.isFinite,
            previewBottomInset.isFinite
        else {
            return minimumHeight
        }

        let availableHeight = viewportHeight - previewTop - (contentPadding * 2) - previewBottomInset
        return max(minimumHeight, availableHeight)
    }
}

private struct ResponseBodyViewportFillModifier: ViewModifier {
    @Environment(\.responseBodyViewport) private var viewport
    @State private var previewTop: CGFloat?

    func body(content: Content) -> some View {
        content
            .frame(height: previewHeight)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: ResponseBodyPreviewTopPreferenceKey.self,
                        value: geometry.frame(in: .named(ResponseBodyViewport.contentCoordinateSpace)).minY
                    )
                }
            }
            .onPreferenceChange(ResponseBodyPreviewTopPreferenceKey.self) { top in
                guard let top, top.isFinite, previewTop != top else { return }
                previewTop = top
            }
    }

    private var previewHeight: CGFloat {
        guard let previewTop else { return ResponseBodyViewportSizing.minimumHeight }
        return ResponseBodyViewportSizing.height(
            viewportHeight: viewport.height,
            previewTop: previewTop,
            contentPadding: viewport.contentPadding,
            previewBottomInset: viewport.previewBottomInset
        )
    }
}

private struct ResponseBodyPreviewTopPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

private struct ResponseBodyViewport: Sendable {
    static let contentCoordinateSpace = "responseBodyContent"

    let height: CGFloat
    let contentPadding: CGFloat
    let previewBottomInset: CGFloat
}

private struct ResponseBodyViewportEnvironmentKey: EnvironmentKey {
    static let defaultValue = ResponseBodyViewport(height: 0, contentPadding: 0, previewBottomInset: 0)
}

private extension EnvironmentValues {
    var responseBodyViewport: ResponseBodyViewport {
        get { self[ResponseBodyViewportEnvironmentKey.self] }
        set { self[ResponseBodyViewportEnvironmentKey.self] = newValue }
    }
}
