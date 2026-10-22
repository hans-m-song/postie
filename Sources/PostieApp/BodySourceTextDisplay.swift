import PostieCore
import SwiftUI

@MainActor
struct BodySourceTextDisplay: View {
    let text: String
    let syntax: BodySyntax
    let wrapsText: Bool

    @ViewBuilder
    var body: some View {
        if wrapsText {
            highlightedText(wrapsToWidth: true)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .padding(10)
        } else {
            ScrollView(.horizontal) {
                highlightedText(wrapsToWidth: false)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(10)
            }
        }
    }

    private func highlightedText(wrapsToWidth: Bool) -> some View {
        HighlightedResponseText(
            text: text.isEmpty ? "(empty body)" : text,
            syntax: syntax,
            wrapsToWidth: wrapsToWidth
        )
    }
}
