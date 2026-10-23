import Darwin
import Foundation
import PostieCore
import Security

actor EncryptedMCPTokenStore {
    private let rootURL: URL
    private let vault: SecretVault
    private let legacyKeyStore: any ApplicationKeyStore
    private var tokenTask: (id: UUID, task: Task<String, Error>)?

    init(rootURL: URL, vault: SecretVault, legacyKeyStore: any ApplicationKeyStore) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.vault = vault
        self.legacyKeyStore = legacyKeyStore
    }

    func storedEnvelope() throws -> SecretEnvelope? {
        guard let data = try EncryptedMCPTokenFile.read(rootURL: rootURL) else { return nil }
        let document: EncryptedMCPTokenDocument
        do {
            document = try JSONDecoder().decode(EncryptedMCPTokenDocument.self, from: data)
        } catch {
            throw EncryptedMCPTokenStoreError.invalidFile
        }

        guard document.formatVersion == 1 else {
            throw EncryptedMCPTokenStoreError.unsupportedFormatVersion
        }
        try Self.validate(document.token)
        return document.token
    }

    func token() async throws -> String {
        let shared: (id: UUID, task: Task<String, Error>)
        if let tokenTask {
            shared = tokenTask
        } else {
            let id = UUID()
            let task = Task.detached { [self] in
                try await self.loadOrCreateToken()
            }
            shared = (id, task)
            tokenTask = shared
        }

        do {
            let token = try await shared.task.value
            if tokenTask?.id == shared.id {
                tokenTask = nil
            }
            return token
        } catch {
            if tokenTask?.id == shared.id {
                tokenTask = nil
            }
            throw error
        }
    }

    private func loadOrCreateToken() async throws -> String {
        if let envelope = try storedEnvelope() {
            return try await decryptedToken(from: envelope)
        }

        let plaintext = try legacyToken()
        try Self.validateToken(plaintext)
        let envelope = try await vault.encrypt(plaintext)
        await vault.setAllowsKeyCreation(false)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(EncryptedMCPTokenDocument(formatVersion: 1, token: envelope))
        switch try EncryptedMCPTokenFile.publish(data, rootURL: rootURL) {
        case .created:
            guard let publishedEnvelope = try storedEnvelope() else {
                throw EncryptedMCPTokenStoreError.publicationFailed
            }
            let verifiedToken = try await decryptedToken(from: publishedEnvelope)
            guard verifiedToken == plaintext else {
                throw EncryptedMCPTokenStoreError.publicationFailed
            }
            return verifiedToken
        case .alreadyExists:
            guard let winningEnvelope = try storedEnvelope() else {
                throw EncryptedMCPTokenStoreError.publicationFailed
            }
            return try await decryptedToken(from: winningEnvelope)
        }
    }

    private func decryptedToken(from envelope: SecretEnvelope) async throws -> String {
        let token = try await vault.decrypt(envelope)
        try Self.validateToken(token)
        return token
    }

    private func legacyToken() throws -> String {
        guard let key = try legacyKeyStore.loadKey() else {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw EncryptedMCPTokenStoreError.tokenGenerationFailed
            }
            return Data(bytes).base64EncodedString()
        }

        guard key.count == 32 else {
            throw SecretVaultError.invalidKeyLength
        }
        return key.base64EncodedString()
    }

    private static func validate(_ envelope: SecretEnvelope) throws {
        guard envelope.version == 1 else {
            throw SecretVaultError.unsupportedEnvelopeVersion
        }
        guard
            let combined = Data(base64Encoded: envelope.combined),
            combined.base64EncodedString() == envelope.combined,
            combined.count >= 28
        else {
            throw SecretVaultError.malformedEnvelope
        }
    }

    private static func validateToken(_ token: String) throws {
        guard
            let bytes = Data(base64Encoded: token),
            bytes.count == 32,
            bytes.base64EncodedString() == token
        else {
            throw EncryptedMCPTokenStoreError.invalidToken
        }
    }
}

private struct EncryptedMCPTokenDocument: Codable {
    let formatVersion: Int
    let token: SecretEnvelope
}

private enum EncryptedMCPTokenStoreError: Error {
    case invalidFile
    case invalidToken
    case unsupportedFormatVersion
    case tokenGenerationFailed
    case publicationFailed
    case fileUnavailable
    case fileTooLarge
}

private enum EncryptedMCPTokenFile {
    private static let filename = "automation.json"
    private static let maximumSize = 4 * 1024
    private static let privateMode = mode_t(S_IRUSR | S_IWUSR)

    enum PublishResult {
        case created
        case alreadyExists
    }

    static func read(rootURL: URL) throws -> Data? {
        let directory = try openDirectory(rootURL)
        defer { _ = Darwin.close(directory) }

        let descriptor = filename.withCString {
            Darwin.openat(directory, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, mode_t(0))
        }
        guard descriptor >= 0 else {
            guard Darwin.errno == ENOENT else { throw EncryptedMCPTokenStoreError.fileUnavailable }
            return nil
        }
        defer { _ = Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw EncryptedMCPTokenStoreError.fileUnavailable
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw EncryptedMCPTokenStoreError.fileUnavailable
        }
        guard metadata.st_mode & mode_t(0o777) == privateMode else {
            throw EncryptedMCPTokenStoreError.fileUnavailable
        }
        guard metadata.st_size >= 0, metadata.st_size <= off_t(maximumSize) else {
            throw EncryptedMCPTokenStoreError.fileTooLarge
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: maximumSize + 1)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0 && Darwin.errno == EINTR { continue }
            guard count >= 0 else { throw EncryptedMCPTokenStoreError.fileUnavailable }
            guard count > 0 else { break }
            guard data.count + count <= maximumSize else {
                throw EncryptedMCPTokenStoreError.fileTooLarge
            }
            data.append(contentsOf: buffer[..<count])
        }
        return data
    }

    static func publish(_ data: Data, rootURL: URL) throws -> PublishResult {
        guard data.count <= maximumSize else { throw EncryptedMCPTokenStoreError.fileTooLarge }

        let directory = try openDirectory(rootURL)
        defer { _ = Darwin.close(directory) }

        let temporaryName = ".\(filename).tmp-\(UUID().uuidString.lowercased())"
        let descriptor = temporaryName.withCString {
            Darwin.openat(
                directory,
                $0,
                O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
                privateMode
            )
        }
        guard descriptor >= 0 else { throw EncryptedMCPTokenStoreError.fileUnavailable }

        var isOpen = true
        defer {
            if isOpen { _ = Darwin.close(descriptor) }
            _ = temporaryName.withCString { Darwin.unlinkat(directory, $0, 0) }
        }

        guard Darwin.fchmod(descriptor, privateMode) == 0 else {
            throw EncryptedMCPTokenStoreError.fileUnavailable
        }

        var writeFailed = false
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                if count < 0 && Darwin.errno == EINTR { continue }
                if count <= 0 {
                    writeFailed = true
                    break
                }
                offset += count
            }
        }
        guard !writeFailed, Darwin.fsync(descriptor) == 0 else {
            throw EncryptedMCPTokenStoreError.fileUnavailable
        }
        guard Darwin.close(descriptor) == 0 else {
            isOpen = false
            throw EncryptedMCPTokenStoreError.fileUnavailable
        }
        isOpen = false

        let linkResult = temporaryName.withCString { temporary in
            filename.withCString { destination in
                Darwin.linkat(directory, temporary, directory, destination, 0)
            }
        }
        if linkResult == 0 { return .created }
        if Darwin.errno == EEXIST { return .alreadyExists }
        throw EncryptedMCPTokenStoreError.fileUnavailable
    }

    private static func openDirectory(_ rootURL: URL) throws -> Int32 {
        let descriptor = rootURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW, mode_t(0))
        }
        guard descriptor >= 0 else { throw EncryptedMCPTokenStoreError.fileUnavailable }
        return descriptor
    }
}
