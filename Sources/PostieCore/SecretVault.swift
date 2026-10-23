import CryptoKit
import Foundation
import Security

public enum SecretVaultError: Error, Equatable, LocalizedError, Sendable {
    case keyCreationNotAllowed
    case missingKey
    case keyUnavailable
    case keyConflict
    case unsupportedKeyIdentifier
    case invalidKeyLength
    case unsupportedEnvelopeVersion
    case malformedEnvelope
    case authenticationFailed
    case invalidPlaintext
    case encryptionFailed

    public var errorDescription: String? {
        switch self {
        case .keyCreationNotAllowed:
            "Key creation is disabled."
        case .missingKey:
            "The encryption key is missing."
        case .keyUnavailable:
            "The encryption key is unavailable."
        case .keyConflict:
            "A different encryption key is already stored."
        case .unsupportedKeyIdentifier:
            "The key store does not support identified encryption keys."
        case .invalidKeyLength:
            "The encryption key is invalid."
        case .unsupportedEnvelopeVersion:
            "The encrypted value uses an unsupported version."
        case .malformedEnvelope:
            "The encrypted value is malformed."
        case .authenticationFailed:
            "The encrypted value could not be authenticated."
        case .invalidPlaintext:
            "The decrypted value is not valid UTF-8."
        case .encryptionFailed:
            "The value could not be encrypted."
        }
    }
}

public enum SecretKeyImportResult: Equatable, Sendable {
    case imported
    case alreadyPresent
}

public actor SecretVault: SecretValueDecrypting {
    private static let keyByteCount = 32
    private static let combinedBoxMinimumByteCount = 12 + 16

    private let keyStore: any ApplicationKeyStore
    private var allowsKeyCreation: Bool
    private var cachedKey: Data?
    private var cachedKeysByID: [UUID: Data] = [:]
    private var activeKeyID: UUID?

    public init(keyStore: any ApplicationKeyStore, allowsKeyCreation: Bool = false) {
        self.keyStore = keyStore
        self.allowsKeyCreation = allowsKeyCreation
    }

    public func setAllowsKeyCreation(_ allowsKeyCreation: Bool) {
        self.allowsKeyCreation = allowsKeyCreation
    }

    public func configure(activeKeyID: UUID?) {
        self.activeKeyID = activeKeyID
    }

    public func exportKey() throws -> Data {
        guard let existingKey = try loadKey(for: activeKeyID) else {
            throw SecretVaultError.missingKey
        }

        try validateKey(existingKey)
        if let cachedKey = cachedKey(for: activeKeyID), cachedKey != existingKey {
            throw SecretVaultError.keyConflict
        }

        return existingKey
    }

    public func importKey(
        _ keyData: Data,
        validating envelopes: [SecretEnvelope]
    ) throws -> SecretKeyImportResult {
        try validateKey(keyData)
        let destinationKeyID = activeKeyID
        if let cachedKey = cachedKey(for: destinationKeyID), cachedKey != keyData {
            throw SecretVaultError.keyConflict
        }

        for envelope in envelopes {
            let sealedBox = try decodeSealedBox(envelope)
            guard envelope.keyID == destinationKeyID else {
                throw SecretVaultError.keyConflict
            }
            _ = try decrypt(sealedBox, using: keyData)
        }

        if let existingKey = try loadKey(for: destinationKeyID) {
            try validateKey(existingKey)
            guard existingKey == keyData else {
                throw SecretVaultError.keyConflict
            }

            cacheKey(existingKey, for: destinationKeyID)
            return .alreadyPresent
        }

        let createdKey = try createKey(keyData, for: destinationKeyID)

        try validateKey(createdKey)
        guard createdKey == keyData else {
            throw SecretVaultError.keyConflict
        }

        cacheKey(createdKey, for: destinationKeyID)
        return .imported
    }

    public func encrypt(_ value: String) async throws -> SecretEnvelope {
        try encrypt(value, using: activeKeyID)
    }

    private func encrypt(_ value: String, using keyID: UUID?) throws -> SecretEnvelope {
        let keyData = try encryptionKey(for: keyID)
        let sealedBox: AES.GCM.SealedBox

        do {
            sealedBox = try AES.GCM.seal(
                Data(value.utf8),
                using: SymmetricKey(data: keyData),
                nonce: AES.GCM.Nonce()
            )
        } catch {
            throw SecretVaultError.encryptionFailed
        }

        guard let combined = sealedBox.combined else {
            throw SecretVaultError.encryptionFailed
        }

        return SecretEnvelope(
            version: keyID == nil ? 1 : 2,
            combined: combined.base64EncodedString(),
            keyID: keyID
        )
    }

    public func decrypt(_ envelope: SecretEnvelope) async throws -> String {
        try plaintext(from: envelope)
    }

    private func plaintext(from envelope: SecretEnvelope) throws -> String {
        let sealedBox = try decodeSealedBox(envelope)
        let keyData = try decryptionKey(for: envelope.keyID)
        return try decrypt(sealedBox, using: keyData)
    }

    public func createRotationKey() throws -> UUID {
        let keyID = UUID()
        let proposedKey = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let createdKey = try createKey(proposedKey, for: keyID)

        try validateKey(createdKey)
        guard createdKey == proposedKey else {
            throw SecretVaultError.keyConflict
        }

        guard let readBackKey = try loadKey(for: keyID) else {
            throw SecretVaultError.missingKey
        }

        try validateKey(readBackKey)
        guard readBackKey == proposedKey else {
            throw SecretVaultError.keyConflict
        }

        cacheKey(readBackKey, for: keyID)
        return keyID
    }

    public func reencrypt(_ envelope: SecretEnvelope) throws -> SecretEnvelope {
        let destinationKeyID = activeKeyID
        let value = try plaintext(from: envelope)
        guard envelope.keyID != destinationKeyID else {
            return envelope
        }

        return try encrypt(value, using: destinationKeyID)
    }

    private func decodeSealedBox(_ envelope: SecretEnvelope) throws -> AES.GCM.SealedBox {
        switch envelope.version {
        case 1:
            guard envelope.keyID == nil else {
                throw SecretVaultError.malformedEnvelope
            }
        case 2:
            guard envelope.keyID != nil else {
                throw SecretVaultError.unsupportedEnvelopeVersion
            }
        default:
            throw SecretVaultError.unsupportedEnvelopeVersion
        }

        guard
            let combined = Data(base64Encoded: envelope.combined),
            combined.base64EncodedString() == envelope.combined,
            combined.count >= Self.combinedBoxMinimumByteCount
        else {
            throw SecretVaultError.malformedEnvelope
        }

        do {
            return try AES.GCM.SealedBox(combined: combined)
        } catch {
            throw SecretVaultError.malformedEnvelope
        }
    }

    private func decrypt(_ sealedBox: AES.GCM.SealedBox, using keyData: Data) throws -> String {
        let plaintext: Data

        do {
            plaintext = try AES.GCM.open(sealedBox, using: SymmetricKey(data: keyData))
        } catch {
            throw SecretVaultError.authenticationFailed
        }

        guard let value = String(data: plaintext, encoding: .utf8) else {
            throw SecretVaultError.invalidPlaintext
        }

        return value
    }

    private func encryptionKey(for keyID: UUID?) throws -> Data {
        if let cachedKey = cachedKey(for: keyID) {
            return cachedKey
        }

        let existingKey = try loadKey(for: keyID)
        if let existingKey {
            try validateKey(existingKey)
            cacheKey(existingKey, for: keyID)
            return existingKey
        }

        guard keyID == nil else {
            throw SecretVaultError.missingKey
        }

        guard allowsKeyCreation else {
            throw SecretVaultError.keyCreationNotAllowed
        }

        let proposedKey = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let createdKey = try createKey(proposedKey, for: nil)

        try validateKey(createdKey)
        cacheKey(createdKey, for: nil)
        return createdKey
    }

    private func decryptionKey(for keyID: UUID?) throws -> Data {
        if let cachedKey = cachedKey(for: keyID) {
            return cachedKey
        }

        guard let existingKey = try loadKey(for: keyID) else {
            throw SecretVaultError.missingKey
        }

        try validateKey(existingKey)
        cacheKey(existingKey, for: keyID)
        return existingKey
    }

    private func loadKey(for keyID: UUID?) throws -> Data? {
        do {
            guard let keyID else {
                return try keyStore.loadKey()
            }
            return try keyStore.loadKey(id: keyID)
        } catch let error as ApplicationKeyStoreError where error == .unsupportedKeyIdentifier {
            throw SecretVaultError.unsupportedKeyIdentifier
        } catch {
            throw SecretVaultError.keyUnavailable
        }
    }

    private func createKey(_ proposedKey: Data, for keyID: UUID?) throws -> Data {
        do {
            guard let keyID else {
                return try keyStore.createKey(proposedKey)
            }
            return try keyStore.createKey(proposedKey, id: keyID)
        } catch let error as ApplicationKeyStoreError where error == .unsupportedKeyIdentifier {
            throw SecretVaultError.unsupportedKeyIdentifier
        } catch {
            throw SecretVaultError.keyUnavailable
        }
    }

    private func cachedKey(for keyID: UUID?) -> Data? {
        guard let keyID else {
            return cachedKey
        }
        return cachedKeysByID[keyID]
    }

    private func cacheKey(_ keyData: Data, for keyID: UUID?) {
        guard let keyID else {
            cachedKey = keyData
            return
        }
        cachedKeysByID[keyID] = keyData
    }

    private func validateKey(_ key: Data) throws {
        guard key.count == Self.keyByteCount else {
            throw SecretVaultError.invalidKeyLength
        }
    }
}

public struct KeychainApplicationKeyStore: ApplicationKeyStore {
    private let service: String
    private let account: String
    private let client: any KeychainItemClient

    public init(service: String, account: String = "workspace-key-v1") {
        self.init(service: service, account: account, client: SystemKeychainItemClient())
    }

    init(service: String, account: String = "workspace-key-v1", client: any KeychainItemClient) {
        self.service = service
        self.account = account
        self.client = client
    }

    public func loadKey() throws -> Data? {
        try client.load(service: service, account: account)
    }

    public func createKey(_ proposedKey: Data) throws -> Data {
        try createKey(proposedKey, service: service, account: account)
    }

    public func loadKey(id: UUID) throws -> Data? {
        try client.load(service: service, account: accountName(for: id))
    }

    public func createKey(_ proposedKey: Data, id: UUID) throws -> Data {
        try createKey(proposedKey, service: service, account: accountName(for: id))
    }

    private func accountName(for keyID: UUID) -> String {
        "workspace-key-\(keyID.uuidString.lowercased())"
    }

    private func createKey(_ proposedKey: Data, service: String, account: String) throws -> Data {
        switch try client.add(proposedKey, service: service, account: account) {
        case .inserted:
            return proposedKey
        case .duplicate:
            guard let existingKey = try client.load(service: service, account: account) else {
                throw KeychainItemClientError.operationFailed
            }
            return existingKey
        }
    }
}

enum KeychainAddResult: Sendable {
    case inserted
    case duplicate
}

protocol KeychainItemClient: Sendable {
    func load(service: String, account: String) throws -> Data?
    func add(_ data: Data, service: String, account: String) throws -> KeychainAddResult
}

private struct SystemKeychainItemClient: KeychainItemClient {
    func load(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainItemClientError.operationFailed
        }

        return data
    }

    func add(_ data: Data, service: String, account: String) throws -> KeychainAddResult {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess {
            return .inserted
        }
        if status == errSecDuplicateItem {
            return .duplicate
        }

        throw KeychainItemClientError.operationFailed
    }
}

enum KeychainItemClientError: Error {
    case operationFailed
}
