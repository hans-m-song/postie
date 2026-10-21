import Darwin
import Foundation

public enum SnapshotStoreError: LocalizedError, Sendable {
    case invalidPath
    case malformedSnapshot
    case unsupportedVersion
    case unavailableBody
    case ineligibleResponse
    case invalidName
    case storageFailure

    public var errorDescription: String? {
        switch self {
        case .invalidPath: "The snapshot path is unavailable or unsafe."
        case .malformedSnapshot: "The snapshot is incomplete or malformed and was preserved."
        case .unsupportedVersion: "The snapshot uses an unsupported format and was preserved."
        case .unavailableBody: "The complete response body is unavailable."
        case .ineligibleResponse: "This response does not have a complete snapshot capture."
        case .invalidName: "Enter a non-empty snapshot name."
        case .storageFailure: "The snapshot could not be stored. Existing data was preserved."
        }
    }
}

private struct SnapshotRedirectMetadata: Codable {
    let id: UUID
    let statusCode: Int
    let method: String
    let nextMethod: String
    let responseHeaders: [HTTPField]

    init(_ redirect: HTTPRedirect) {
        id = redirect.id
        statusCode = redirect.statusCode
        method = redirect.method
        nextMethod = redirect.nextMethod
        responseHeaders = redirect.responseHeaders
    }
}

private struct SnapshotResponseMetadata: Codable {
    let statusCode: Int
    let headers: [HTTPField]
    let bodyByteCount: Int64
    let duration: TimeInterval
    let redirectLimitReached: Bool
    let effectiveMethod: String
    let redirects: [SnapshotRedirectMetadata]
}

private struct SnapshotDocument: Codable {
    let version: Int
    let name: String
    let capturedAt: Date
    let source: SnapshotSource
    let originalRunID: UUID
    let template: SnapshotRequestTemplate
    let preparationVersion: Int
    let encryptedContext: SecretEnvelope
    let response: SnapshotResponseMetadata

    func summary(id: UUID) -> SavedSnapshot {
        SavedSnapshot(id: id, name: name, capturedAt: capturedAt, source: source,
                      statusCode: response.statusCode, bodyByteCount: response.bodyByteCount)
    }
}

private struct EncryptedSnapshotContext: Codable {
    let referencedInputs: [String: SnapshotInput]
    let redactionInputs: SnapshotRedactionCapture?
    let authentication: SnapshotAuthenticationInput
    let submitted: SnapshotTransportRequest
    let observedTransport: SnapshotTransportRequest
    let redirects: [HTTPRedirect]
}

public actor SnapshotStore {
    private static let stagingMarker = Data("Postie snapshot staging v1\n".utf8)
    private let rootURL: URL
    private let vault: SecretVault
    private let fileManager = FileManager.default

    public init(rootURL: URL, vault: SecretVault) {
        self.rootURL = rootURL.standardizedFileURL
        self.vault = vault
    }

    public func load() throws -> SnapshotLoad {
        guard try pathExists(rootURL) else {
            return SnapshotLoad(snapshots: [], containsEncryptedData: false)
        }
        try requireDirectory(rootURL)
        var snapshots: [SavedSnapshot] = []
        var issues: [StorageIssue] = []
        var containsEncryptedData = false
        let entries = try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
        for entry in entries {
            if entry.lastPathComponent == ".staging" {
                do {
                    try cleanStaging(at: entry)
                } catch {
                    containsEncryptedData = true
                    issues.append(issue(for: entry, message: "Unrecognized snapshot staging data was preserved."))
                }
                continue
            }
            containsEncryptedData = true
            guard let id = UUID(uuidString: entry.lastPathComponent),
                  id.uuidString == entry.lastPathComponent else {
                issues.append(issue(for: entry, message: "An unrecognized snapshot entry was preserved."))
                continue
            }
            do {
                let document = try readDocument(id: id)
                snapshots.append(document.summary(id: id))
            } catch {
                issues.append(issue(for: entry, message: (error as? LocalizedError)?.errorDescription
                                    ?? "An unreadable snapshot was preserved."))
            }
        }
        snapshots.sort { $0.capturedAt > $1.capturedAt }
        return SnapshotLoad(snapshots: snapshots, issues: issues, containsEncryptedData: containsEncryptedData)
    }

    public func encryptionEnvelopes() throws -> [SecretEnvelope] {
        guard try pathExists(rootURL) else { return [] }
        try requireDirectory(rootURL)

        let entries = try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
        var envelopes: [SecretEnvelope] = []
        for entry in entries {
            if entry.lastPathComponent == ".staging" {
                try requireDirectory(entry)
                guard try fileManager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil).isEmpty else {
                    throw SnapshotStoreError.invalidPath
                }
                continue
            }
            guard let id = UUID(uuidString: entry.lastPathComponent),
                  id.uuidString == entry.lastPathComponent else {
                throw SnapshotStoreError.invalidPath
            }

            let envelope = try readDocument(id: id).encryptedContext
            try validate(envelope)
            envelopes.append(envelope)
        }
        return envelopes
    }

    public func save(response: HTTPResponseRecord, source: SnapshotSource, name: String,
                     bodyLease: HTTPBodyLease) async throws -> SavedSnapshot {
        try validateName(name)
        guard let capture = response.snapshotCapture, capture.preparationVersion == 1,
              bodyLease.runID == response.runID,
              bodyLease.bodyURL == response.bodyFileURL.standardizedFileURL,
              response.bodyByteCount >= 0,
              response.duration.isFinite, response.duration >= 0 else {
            throw SnapshotStoreError.ineligibleResponse
        }
        let context = EncryptedSnapshotContext(
            referencedInputs: capture.referencedInputs,
            redactionInputs: capture.redactionInputs,
            authentication: capture.authentication,
            submitted: capture.submitted,
            observedTransport: SnapshotTransportRequest(
                method: response.effectiveMethod, url: response.finalURL, headers: response.requestHeaders,
                headerSources: response.requestHeaderSources,
                sensitiveNames: response.sensitiveRequestHeaderNames, secretNames: response.secretRequestHeaderNames
            ),
            redirects: response.redirects
        )
        let encoder = Self.encoder()
        let plaintext = String(decoding: try encoder.encode(context), as: UTF8.self)
        let envelope = try await vault.encrypt(plaintext)
        try Task.checkCancellation()
        try prepareDirectories()
        try requireBody(bodyLease.bodyURL, byteCount: response.bodyByteCount)

        let id = UUID()
        let staging = rootURL.appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        let destination = directory(for: id)
        let document = SnapshotDocument(
            version: 1, name: name, capturedAt: response.completedAt, source: source,
            originalRunID: response.runID, template: capture.template,
            preparationVersion: capture.preparationVersion, encryptedContext: envelope,
            response: SnapshotResponseMetadata(
                statusCode: response.statusCode, headers: response.responseHeaders,
                bodyByteCount: response.bodyByteCount, duration: response.duration,
                redirectLimitReached: response.redirectLimitReached, effectiveMethod: response.effectiveMethod,
                redirects: response.redirects.map(SnapshotRedirectMetadata.init)
            )
        )
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
            defer { try? fileManager.removeItem(at: staging) }
            try Self.stagingMarker.write(to: staging.appendingPathComponent(".postie-snapshot-stage"))
            let body = staging.appendingPathComponent("response.body")
            try fileManager.copyItem(at: bodyLease.bodyURL, to: body)
            try requireBody(body, byteCount: response.bodyByteCount)
            try encoder.encode(document).write(to: staging.appendingPathComponent("snapshot.json"), options: .atomic)
            try Task.checkCancellation()
            guard try !pathExists(destination), Darwin.rename(staging.path, destination.path) == 0 else {
                throw SnapshotStoreError.storageFailure
            }
            try? fileManager.removeItem(at: destination.appendingPathComponent(".postie-snapshot-stage"))
            return document.summary(id: id)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SnapshotStoreError {
            throw error
        } catch {
            throw SnapshotStoreError.storageFailure
        }
    }

    public func open(id: UUID) async throws -> OpenedSnapshot {
        let document = try readDocument(id: id)
        var context: FrozenSnapshotContext?
        var contextError: String?
        do {
            let plaintext = try await vault.decrypt(document.encryptedContext)
            let decoded = try JSONDecoder().decode(EncryptedSnapshotContext.self, from: Data(plaintext.utf8))
            guard decoded.redirects.count == document.response.redirects.count else {
                throw SnapshotStoreError.malformedSnapshot
            }
            context = FrozenSnapshotContext(
                preparation: SnapshotPreparationCapture(
                    preparationVersion: document.preparationVersion, template: document.template,
                    referencedInputs: decoded.referencedInputs, authentication: decoded.authentication,
                    submitted: decoded.submitted, redactionInputs: decoded.redactionInputs
                ),
                observedTransport: decoded.observedTransport, redirects: decoded.redirects
            )
        } catch {
            contextError = "Captured request context is unavailable. "
                + ((error as? LocalizedError)?.errorDescription ?? "The encrypted context could not be read.")
        }
        // Revalidate after unlocking, which yields actor isolation to deletion and rename.
        let current = try readDocument(id: id)
        let observed = context?.observedTransport
        let unavailableURL = URL(string: "about:blank")!
        let redirects = context?.redirects ?? document.response.redirects.map {
            HTTPRedirect(id: $0.id, statusCode: $0.statusCode, url: unavailableURL, nextURL: unavailableURL,
                         method: $0.method, nextMethod: $0.nextMethod, requestHeaders: [], responseHeaders: $0.responseHeaders)
        }
        let response = HTTPResponseRecord(
            runID: document.originalRunID, request: document.template.configuration,
            finalURL: observed?.url ?? unavailableURL,
            statusCode: document.response.statusCode, requestHeaders: observed?.headers ?? [],
            responseHeaders: document.response.headers, redirects: redirects,
            bodyFileURL: directory(for: id).appendingPathComponent("response.body"),
            bodyByteCount: document.response.bodyByteCount, duration: document.response.duration,
            redirectLimitReached: document.response.redirectLimitReached,
            effectiveMethod: observed?.method ?? document.response.effectiveMethod,
            sensitiveRequestHeaderNames: observed?.sensitiveNames ?? [],
            secretRequestHeaderNames: observed?.secretNames ?? [],
            requestHeaderSources: observed?.headerSources ?? [:],
            snapshotCapture: context?.preparation, completedAt: document.capturedAt
        )
        return OpenedSnapshot(summary: current.summary(id: id), template: document.template, context: context,
                              contextError: contextError, response: response)
    }

    public func rename(id: UUID, name: String) throws -> SavedSnapshot {
        try validateName(name)
        let document = try readDocument(id: id)
        let url = directory(for: id).appendingPathComponent("snapshot.json")
        guard var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw SnapshotStoreError.malformedSnapshot
        }
        json["name"] = name
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
        return SavedSnapshot(id: id, name: name, capturedAt: document.capturedAt, source: document.source,
                             statusCode: document.response.statusCode, bodyByteCount: document.response.bodyByteCount)
    }

    public func delete(id: UUID) throws {
        try requireDirectory(rootURL)
        let entry = directory(for: id)
        try requireDirectory(entry)
        try requireSafeChildren(entry, allowedNames: ["snapshot.json", "response.body", ".postie-snapshot-stage"])
        try fileManager.removeItem(at: entry)
    }

    private func readDocument(id: UUID) throws -> SnapshotDocument {
        try requireDirectory(rootURL)
        let entry = directory(for: id)
        try requireDirectory(entry)
        try requireSafeChildren(entry, allowedNames: ["snapshot.json", "response.body", ".postie-snapshot-stage"])
        let metadata = entry.appendingPathComponent("snapshot.json")
        try requireRegularFile(metadata)
        let data = try Data(contentsOf: metadata)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? Int else {
            throw SnapshotStoreError.malformedSnapshot
        }
        guard version == 1 else { throw SnapshotStoreError.unsupportedVersion }
        let document = try JSONDecoder().decode(SnapshotDocument.self, from: data)
        guard document.preparationVersion == 1 else {
            throw SnapshotStoreError.unsupportedVersion
        }
        guard !document.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              document.response.bodyByteCount >= 0, document.response.duration.isFinite,
              document.response.duration >= 0, document.capturedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw SnapshotStoreError.malformedSnapshot
        }
        try requireBody(entry.appendingPathComponent("response.body"), byteCount: document.response.bodyByteCount)
        return document
    }

    private func validate(_ envelope: SecretEnvelope) throws {
        guard envelope.version == 1 else { throw SnapshotStoreError.unsupportedVersion }
        guard let combined = Data(base64Encoded: envelope.combined),
              combined.base64EncodedString() == envelope.combined,
              combined.count >= 12 + 16 else {
            throw SnapshotStoreError.malformedSnapshot
        }
    }

    private func prepareDirectories() throws {
        if try pathExists(rootURL) {
            try requireDirectory(rootURL)
        } else {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            try requireDirectory(rootURL)
        }
        let staging = rootURL.appendingPathComponent(".staging", isDirectory: true)
        if try !pathExists(staging) {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
        }
        try requireDirectory(staging)
    }

    private func cleanStaging(at staging: URL) throws {
        try requireDirectory(staging)
        for entry in try fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: entry.lastPathComponent), id.uuidString == entry.lastPathComponent else {
                throw SnapshotStoreError.invalidPath
            }
            try requireDirectory(entry)
            try requireSafeChildren(entry, allowedNames: [".postie-snapshot-stage", "snapshot.json", "response.body"])
            let marker = entry.appendingPathComponent(".postie-snapshot-stage")
            try requireRegularFile(marker)
            guard try Data(contentsOf: marker) == Self.stagingMarker else {
                throw SnapshotStoreError.invalidPath
            }
            try fileManager.removeItem(at: entry)
        }
    }

    private func requireSafeChildren(_ directory: URL, allowedNames: Set<String>) throws {
        for child in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard allowedNames.contains(child.lastPathComponent) else { throw SnapshotStoreError.invalidPath }
            try requireRegularFile(child)
        }
    }

    private func requireDirectory(_ url: URL) throws {
        guard url.isFileURL else { throw SnapshotStoreError.invalidPath }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw SnapshotStoreError.invalidPath
        }
    }

    private func requireRegularFile(_ url: URL) throws {
        guard url.isFileURL else { throw SnapshotStoreError.invalidPath }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw SnapshotStoreError.invalidPath
        }
    }

    private func requireBody(_ url: URL, byteCount: Int64) throws {
        try requireRegularFile(url)
        guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) == byteCount else {
            throw SnapshotStoreError.unavailableBody
        }
    }

    private func pathExists(_ url: URL) throws -> Bool {
        guard url.isFileURL else { throw SnapshotStoreError.invalidPath }
        var information = stat()
        if lstat(url.path, &information) == 0 { return true }
        guard errno == ENOENT else { throw SnapshotStoreError.invalidPath }
        return false
    }

    private func directory(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SnapshotStoreError.invalidName
        }
    }

    private func issue(for entry: URL, message: String) -> StorageIssue {
        StorageIssue(id: "snapshot-" + entry.lastPathComponent, message: message)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
