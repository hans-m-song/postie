import AppKit
import PostieCore
import SwiftUI

struct ParameterTextField: View {
    private let label: String
    @Binding private var text: String
    private let availableVariables: Set<String>
    private let completionVariables: [VariableCompletion]
    private let focused: Binding<Bool>?
    private let isReadOnly: Bool
    private let foregroundColor: NSColor?

    init(
        _ label: String,
        text: Binding<String>,
        availableVariables: Set<String> = [],
        completionVariables: [VariableCompletion] = [],
        focused: Binding<Bool>? = nil,
        isReadOnly: Bool = false,
        foregroundColor: NSColor? = nil
    ) {
        self.label = label
        _text = text
        self.availableVariables = availableVariables
        self.completionVariables = completionVariables
        self.focused = focused
        self.isReadOnly = isReadOnly
        self.foregroundColor = foregroundColor
    }

    var body: some View {
        HighlightedTextField(
            label,
            text: $text,
            availableVariables: availableVariables,
            isReadOnly: isReadOnly,
            completionVariables: completionVariables,
            focused: focused,
            wrapping: .unbounded,
            foregroundColor: foregroundColor
        )
        .font(.system(.body, design: .monospaced))
    }
}
