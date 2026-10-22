import AppKit
import PostieCore
import SwiftUI

struct UploadBodyEditor: View {
    let kind: RequestBodyKind
    @Binding var rawFile: HTTPFileReference?
    @Binding var parts: [HTTPMultipartPart]
    let availableVariables: Set<String>
    let completionVariables: [VariableCompletion]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if kind == .rawFile {
                UploadFileReferenceEditor(file: $rawFile)
            } else {
                ForEach($parts) { $part in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top) {
                            Toggle("Enabled", isOn: $part.isEnabled).labelsHidden()
                            TextField("Part name", text: $part.name, axis: .vertical)
                            Picker("Part type", selection: $part.kind) {
                                Text("Text").tag(MultipartPartKind.text)
                                Text("File").tag(MultipartPartKind.file)
                            }
                            .labelsHidden()
                            .frame(width: 85)
                            Button("Remove part", systemImage: "minus.circle") {
                                parts.removeAll { $0.id == part.id }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                        }
                        if part.kind == .file {
                            UploadFileReferenceEditor(file: $part.file)
                        } else {
                            HighlightedTextField(
                                "Value", text: $part.text, availableVariables: availableVariables,
                                completionVariables: completionVariables, wrapping: .unbounded
                            )
                        }
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                }
                Button("Add part", systemImage: "plus") { parts.append(HTTPMultipartPart()) }
            }
            Text(
                "Files are read from their original locations when sent. Detectable changes are reported; snapshots retain metadata only."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct UploadFileReferenceEditor: View {
    @Binding var file: HTTPFileReference?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                TextField("Absolute file path", text: value(\.path), axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                Button("Choose…", action: chooseFile)
                if file != nil {
                    Button("Clear", systemImage: "xmark.circle") { file = nil }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }
            TextField("Filename override (optional)", text: optionalValue(\.filename))
            TextField("Content type (application/octet-stream when empty)", text: optionalValue(\.contentType))
        }
    }

    private func value(_ keyPath: WritableKeyPath<HTTPFileReference, String>) -> Binding<String> {
        Binding(
            get: { file?[keyPath: keyPath] ?? "" },
            set: { value in
                var reference = file ?? HTTPFileReference(path: "")
                reference[keyPath: keyPath] = value
                file = reference
            })
    }

    private func optionalValue(_ keyPath: WritableKeyPath<HTTPFileReference, String?>) -> Binding<String> {
        Binding(
            get: { file?[keyPath: keyPath] ?? "" },
            set: { value in
                var reference = file ?? HTTPFileReference(path: "")
                reference[keyPath: keyPath] = value.isEmpty ? nil : value
                file = reference
            })
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var reference = file ?? HTTPFileReference(path: url.path)
        reference.path = url.path
        file = reference
    }
}
