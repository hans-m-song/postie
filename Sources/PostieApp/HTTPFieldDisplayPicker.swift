import SwiftUI

struct HTTPFieldDisplayPicker: View {
    @Binding var mode: HTTPFieldDisplayMode

    var body: some View {
        Picker("Field display", selection: $mode) {
            Text("Table").tag(HTTPFieldDisplayMode.table)
            Text("Bulk").tag(HTTPFieldDisplayMode.bulk)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Field display")
        .frame(width: 140)
    }
}
