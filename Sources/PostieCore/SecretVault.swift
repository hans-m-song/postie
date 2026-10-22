import CryptoKit
import Foundation
import Security

public enum SecretVaultError: Error, Equatable, LocalizedError, Sendable {
    case keyCreationNotAllowed
    case missingKey
    case keyUnavailable
    case keyConflict
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

    public init(keyStore: any ApplicationKeyStore, allowsKeyCreation: Bool = false) {
        self.keyStore = keyStore
        self.allowsKeyCreation = allowsKeyCreation
    }

    public func setAllowsKeyCreation(_ allowsKeyCreation: Bool) {
        self.allowsKeyCreation = allowsKeyCreation
    }

    public func exportKey() throws -> Data {
        guard let existingKey = try loadKey() else {
            throw SecretVaultError.missingKey
        }

        try validateKey(existingKey)
        if let cachedKey, cachedKey != existingKey {
            throw SecretVaultError.keyConflict
        }

        return existingKey
    }

    public func importKey(
        _ keyData: Data,
        validating envelopes: [SecretEnvelope]
    ) throws -> SecretKeyImportResult {
        try validateKey(keyData)
        if let cachedKey, cachedKey != keyData {
            throw SecretVaultError.keyConflict
        }

        for envelope in envelopes {
            _ = try decrypt(decodeSealedBox(envelope), using: keyData)
        }

        if let existingKey = try loadKey() {
            try validateKey(existingKey)
            guard existingKey == keyData else {
                throw SecretVaultError.keyConflict
            }

            cachedKey = existingKey
            return .alreadyPresent
        }

        let createdKey: Data
        do {
            createdKey = try keyStore.createKey(keyData)
        } catch {
            throw SecretVaultError.keyUnavailable
        }

        try validateKey(createdKey)
        guard createdKey == keyData else {
            throw SecretVaultError.keyConflict
        }

        cachedKey = createdKey
        return .imported
    }

    public func encrypt(_ value: String) async throws -> SecretEnvelope {
        let keyData = try encryptionKey()
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

        return SecretEnvelope(version: 1, combined: combined.base64EncodedString())
    }

    public func decrypt(_ envelope: SecretEnvelope) async throws -> String {
        let sealedBox = try decodeSealedBox(envelope)
        let keyData = try decryptionKey()
        return try decrypt(sealedBox, using: keyData)
    }

    private func decodeSealedBox(_ envelope: SecretEnvelope) throws -> AES.GCM.SealedBox {
        guard envelope.version == 1 else {
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

    private func encryptionKey() throws -> Data {
        if let cachedKey {
            return cachedKey
        }

        let existingKey = try loadKey()
        if let existingKey {
            try validateKey(existingKey)
            cachedKey = existingKey
            return existingKey
        }

        guard allowsKeyCreation else {
            throw SecretVaultError.keyCreationNotAllowed
        }

        let proposedKey = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let createdKey: Data
        do {
            createdKey = try keyStore.createKey(proposedKey)
        } catch {
            throw SecretVaultError.keyUnavailable
        }

        try validateKey(createdKey)
        cachedKey = createdKey
        return createdKey
    }

    private func decryptionKey() throws -> Data {
        if let cachedKey {
            return cachedKey
        }

        guard let existingKey = try loadKey() else {
            throw SecretVaultError.missingKey
        }

        try validateKey(existingKey)
        cachedKey = existingKey
        return existingKey
    }

    private func loadKey() throws -> Data? {
        do {
            return try keyStore.loadKey()
        } catch {
            throw SecretVaultError.keyUnavailable
        }
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
