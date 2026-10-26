import PostieCore
import SwiftUI

@MainActor
struct BodySourceTextDisplay: View {
    let text: String
    let syntax: BodySyntax
    let wrapsText: Bool

    var body: some View {
        HighlightedResponseText(
            text: text.isEmpty ? "(empty body)" : text,
            syntax: syntax,
            wrapsToWidth: wrapsText
        )
        .frame(minWidth: 0, maxWidth: .infinity)
        .responseBodyViewportFilling()
    }
}
