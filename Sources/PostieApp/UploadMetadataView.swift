import PostieCore
import SwiftUI

struct UploadMetadataView: View {
    let upload: SnapshotUploadBody

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            valueRow(label: "Kind", value: kindLabel)
            valueRow(label: "Content-Type", value: upload.contentType)
            valueRow(label: "Size", value: upload.byteCount.formatted(.byteCount(style: .file)))

            ForEach(upload.parts ?? [], id: \.id) { part in
                if part.kind == .text {
                    valueRow(label: part.name, value: part.text ?? "")
                }
            }

            if !upload.files.isEmpty {
                Text(upload.files.count == 1 ? "File" : "Files")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(upload.files.indices, id: \.self) { index in
                    fileMetadata(upload.files[index])
                }
            }

            if upload.binaryOmitted {
                Label(
                    "Uploaded file bytes are omitted; text fields and file metadata are retained.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var kindLabel: String {
        switch upload.kind {
        case .text: "Text"
        case .rawFile: "Raw file"
        case .multipart: "Multipart"
        }
    }

    private func fileMetadata(_ file: SnapshotUploadFile) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            valueRow(label: "Name", value: file.filename)
            if let partName = file.partName, !partName.isEmpty {
                valueRow(label: "Part", value: partName)
            }
            valueRow(label: "Content-Type", value: file.contentType)
            valueRow(label: "Size", value: file.byteCount.formatted(.byteCount(style: .file)))
            if let sha256 = file.sha256 {
                valueRow(label: "SHA-256", value: sha256)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 7))
    }

    private func valueRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .leading)
            Text(value.isEmpty ? "(empty)" : value)
                .textSelection(.enabled)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.callout, design: .monospaced))
        .fixedSize(horizontal: false, vertical: true)
    }
}
