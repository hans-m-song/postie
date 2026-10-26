import PostieCore
import SwiftUI

@MainActor
struct HighlightedResponseText: View {
    let text: String
    let syntax: BodySyntax
    let wrapsToWidth: Bool

    init(text: String, syntax: BodySyntax, wrapsToWidth: Bool = false) {
        self.text = text
        self.syntax = syntax
        self.wrapsToWidth = wrapsToWidth
    }

    var body: some View {
        ResponseTextViewport(text: text, syntax: syntax, wrapsToWidth: wrapsToWidth)
    }
}
