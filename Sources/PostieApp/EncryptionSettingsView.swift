import AppKit
import Darwin
import SwiftUI
import UniformTypeIdentifiers

struct EncryptionSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var activeSheet: TransferSheet?

    private enum TransferSheet: String, Identifiable {
        case importKey
        case exportKey

        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Encryption Key")
                .font(.headline)

            Text("Move access to encrypted workspace values between devices.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Import Key…") {
                    activeSheet = .importKey
                }

                Button("Export Key…") {
                    activeSheet = .exportKey
                }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            Group {
                switch sheet {
                case .importKey:
                    ImportEncryptionKeySheet()
                case .exportKey:
                    ExportEncryptionKeySheet()
                }
            }
            .environmentObject(model)
        }
    }
}

private struct ImportEncryptionKeySheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var keyText = ""
    @State private var fileKeyData: Data?
    @State private var selectedFileName: String?
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var isImporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Encryption Key")
                .font(.title3.weight(.semibold))

            Text(
                "Enter a Base64 encoded 32-byte key or choose a raw 32-byte or Base64 key file. The key is checked against encrypted workspace and snapshot values before it is stored."
            )
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.secondary)

            SecureField("Base64 key", text: keyTextBinding)
                .textFieldStyle(.roundedBorder)
                .disabled(isImporting)

            HStack {
                Button("Choose Key File…", action: chooseFile)
                    .disabled(isImporting)
                Text(selectedFileName ?? "No key file selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let statusMessage {
                Text(statusMessage)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", action: dismissSheet)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isImporting)
                Button(isImporting ? "Importing…" : "Import Key", action: importKey)
                    .buttonStyle(.borderedProminent)
                    .disabled(isImporting || (keyText.isEmpty && fileKeyData == nil))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
        .interactiveDismissDisabled(isImporting)
        .onDisappear(perform: clearDrafts)
    }

    private var keyTextBinding: Binding<String> {
        Binding(
            get: { keyText },
            set: { value in
                guard value.utf8.count <= 4096 else {
                    errorMessage = "The key text exceeds the 4 KiB input limit."
                    return
                }
                keyText = value
                clearFileKey()
                errorMessage = nil
                statusMessage = nil
            }
        )
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            fileKeyData = try EncryptionKeyFile.read(at: url)
            keyText = ""
            selectedFileName = url.lastPathComponent
            errorMessage = nil
            statusMessage = nil
        } catch {
            clearFileKey()
            errorMessage = error.localizedDescription
        }
    }

    private func importKey() {
        let candidate: Data
        do {
            candidate = try fileKeyData ?? EncryptionKeyFile.decodeBase64(keyText)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        keyText = ""
        clearFileKey()
        errorMessage = nil
        statusMessage = nil
        isImporting = true
        Task {
            var key = candidate
            defer { key.resetBytes(in: 0..<key.count) }
            do {
                let result = try await model.importEncryptionKey(key)
                switch result {
                case .imported:
                    statusMessage = "The encryption key was imported."
                case .alreadyPresent:
                    statusMessage = "This encryption key is already installed."
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isImporting = false
        }
    }

    private func dismissSheet() {
        clearDrafts()
        dismiss()
    }

    private func clearDrafts() {
        keyText = ""
        clearFileKey()
        selectedFileName = nil
    }

    private func clearFileKey() {
        guard var fileKeyData else { return }
        fileKeyData.resetBytes(in: 0..<fileKeyData.count)
        self.fileKeyData = nil
        selectedFileName = nil
    }

}

private struct ExportEncryptionKeySheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var keyText: String?
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var isRevealed = false
    @State private var isLoading = false
    @State private var isVisible = true
    @State private var revealTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export Encryption Key")
                .font(.title3.weight(.semibold))

            Text(
                "Anyone with this key can decrypt encrypted workspace values, authentication secrets, and saved request context. Store it separately and share it only with people who should have that access."
            )
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.secondary)

            if let keyText {
                Group {
                    if isRevealed {
                        TextField("Base64 key", text: .constant(keyText))
                            .textSelection(.enabled)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("Base64 key", text: .constant(keyText))
                            .textFieldStyle(.roundedBorder)
                    }
                }

                HStack {
                    Button(isRevealed ? "Hide Key" : "Reveal Key") {
                        isRevealed.toggle()
                    }
                    Button("Copy") {
                        copyKey(keyText)
                    }
                    Button("Save File…") {
                        saveKeyFile(keyText)
                    }
                }
            } else {
                Button(isLoading ? "Reading Key…" : "Reveal Key") {
                    revealKey()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let statusMessage {
                Text(statusMessage)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Done", action: dismissSheet)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 520)
        .onDisappear {
            isVisible = false
            revealTask?.cancel()
            clearDrafts()
        }
    }

    private func revealKey() {
        isLoading = true
        errorMessage = nil
        revealTask = Task {
            do {
                var key = try await model.exportEncryptionKey()
                defer { key.resetBytes(in: 0..<key.count) }
                guard !Task.isCancelled, isVisible else { return }
                keyText = key.base64EncodedString()
                isRevealed = true
            } catch {
                guard !Task.isCancelled, isVisible else { return }
                errorMessage = error.localizedDescription
            }
            guard !Task.isCancelled, isVisible else { return }
            isLoading = false
            revealTask = nil
        }
    }

    private func copyKey(_ key: String) {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(key, forType: .string) else {
            errorMessage = "The key could not be copied to the clipboard."
            return
        }
        errorMessage = nil
        statusMessage = "The key was copied to the clipboard."
    }

    private func saveKeyFile(_ key: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "postie-encryption-key.txt"
        panel.canCreateDirectories = false
        panel.prompt = "Save Key"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try EncryptionKeyFile.writePrivate(Data(key.utf8), to: url)
            errorMessage = nil
            statusMessage = "The key was saved in a private file."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func dismissSheet() {
        clearDrafts()
        dismiss()
    }

    private func clearDrafts() {
        keyText = nil
        isRevealed = false
    }

}

enum EncryptionKeyFile {
    private static let maximumSize = 4096

    static func read(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
            let size = values.fileSize, size <= maximumSize
        else {
            throw EncryptionKeyFileError.invalidFile
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let contents = try handle.read(upToCount: maximumSize + 1) ?? Data()
        guard contents.count <= maximumSize, contents.count == size else {
            throw EncryptionKeyFileError.invalidFile
        }
        if contents.count == 32 { return contents }
        guard let text = String(data: contents, encoding: .utf8) else {
            throw EncryptionKeyFileError.invalidKey
        }
        return try decodeBase64(text)
    }

    static func decodeBase64(_ text: String) throws -> Data {
        let encoded = String(text.filter { !$0.isWhitespace })
        guard encoded.utf8.count <= maximumSize,
            let key = Data(base64Encoded: encoded), key.count == 32,
            key.base64EncodedString() == encoded
        else {
            throw EncryptionKeyFileError.invalidKey
        }
        return key
    }

    static func writePrivate(_ data: Data, to url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { throw EncryptionKeyFileError.writeFailed }

        var createdFile = stat()
        guard Darwin.fstat(descriptor, &createdFile) == 0 else {
            _ = Darwin.close(descriptor)
            throw EncryptionKeyFileError.writeFailed
        }

        do {
            guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
                throw EncryptionKeyFileError.writeFailed
            }
            try data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw EncryptionKeyFileError.writeFailed }
                    offset += written
                }
            }
            guard Darwin.fsync(descriptor) == 0 else { throw EncryptionKeyFileError.writeFailed }
        } catch {
            _ = Darwin.close(descriptor)
            var currentFile = stat()
            if Darwin.lstat(url.path, &currentFile) == 0,
                currentFile.st_dev == createdFile.st_dev, currentFile.st_ino == createdFile.st_ino
            {
                _ = Darwin.unlink(url.path)
            }
            throw error
        }

        _ = Darwin.close(descriptor)
    }
}

private enum EncryptionKeyFileError: LocalizedError {
    case invalidFile
    case invalidKey
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            "Choose a regular key file no larger than 4 KiB."
        case .invalidKey:
            "The selected input is not a valid 32-byte key."
        case .writeFailed:
            "The key file could not be written. Choose a new file path and try again."
        }
    }
}
