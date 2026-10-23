import CoreFoundation
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

public enum WorkspaceKeyRotationError: Error, Equatable, LocalizedError, Sendable {
    case operationInProgress
    case invalidMetadata
    case invalidWorkspace
    case unsafeStorageEntry
    case malformedCollectionIndex
    case ambiguousIdentity
    case missingRequest
    case unindexedRequest
    case metadataRequiredForIdentifiedEnvelope
    case incompleteRotation
    case concurrentModification
    case fileSystemFailure

    public var errorDescription: String? {
        switch self {
        case .operationInProgress:
            "Workspace-key maintenance is already in progress."
        case .invalidMetadata:
            "The workspace encryption metadata is malformed or unavailable."
        case .invalidWorkspace:
            "Workspace storage could not be inventoried safely."
        case .unsafeStorageEntry:
            "Workspace storage contains an unsupported or unsafe entry."
        case .malformedCollectionIndex:
            "A collection request index is malformed or unsupported."
        case .ambiguousIdentity:
            "Workspace storage contains duplicate identities."
        case .missingRequest:
            "An indexed request document is missing."
        case .unindexedRequest:
            "An unindexed request document was preserved."
        case .metadataRequiredForIdentifiedEnvelope:
            "Workspace encryption metadata is missing for identified secret keys."
        case .incompleteRotation:
            "Workspace-key rotation is incomplete and remains available for recovery."
        case .concurrentModification:
            "Workspace storage changed during key rotation."
        case .fileSystemFailure:
            "Workspace storage could not be updated safely."
        }
    }
}

enum WorkspaceKeyRotationCheckpoint: Equatable, Sendable {
    case pendingPublished
    case documentTemporaryWritten(Int)
    case documentRewritten(Int)
    case rotationCompleted
}

public actor WorkspaceKeyRotation {
    private let rootURL: URL
    private let stagingURL: URL
    private let vault: SecretVault
    private let checkpoint: (@Sendable (WorkspaceKeyRotationCheckpoint) throws -> Void)?
    private var operationInProgress = false

    public init(rootURL: URL, vault: SecretVault) {
        let resolvedRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.rootURL = resolvedRoot
        self.stagingURL = resolvedRoot.appendingPathComponent(".key-rotation-staging", isDirectory: true)
        self.vault = vault
        self.checkpoint = nil
    }

    init(
        rootURL: URL,
        vault: SecretVault,
        checkpoint: @escaping @Sendable (WorkspaceKeyRotationCheckpoint) throws -> Void
    ) {
        let resolvedRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.rootURL = resolvedRoot
        self.stagingURL = resolvedRoot.appendingPathComponent(".key-rotation-staging", isDirectory: true)
        self.vault = vault
        self.checkpoint = checkpoint
    }

    public func isPending() throws -> Bool {
        try WorkspaceEncryptionMetadataFile.read(at: metadataURL)?.pendingRotation ?? false
    }

    public func prepareWorkspace() async throws {
        guard !operationInProgress else { throw WorkspaceKeyRotationError.operationInProgress }
        operationInProgress = true
        defer { operationInProgress = false }
        try WorkspaceFileSystem.recoverStagingDirectory(in: rootURL)

        guard let metadata = try WorkspaceEncryptionMetadataFile.read(at: metadataURL) else {
            await vault.configure(activeKeyID: nil)
            if try WorkspaceInventoryScanner(rootURL: rootURL).containsIdentifiedEnvelopes() {
                throw WorkspaceKeyRotationError.metadataRequiredForIdentifiedEnvelope
            }
            return
        }

        await vault.configure(activeKeyID: metadata.activeKeyID)
        if metadata.pendingRotation {
            try await finishPendingRotation(metadata)
            return
        }

        let inventory = try WorkspaceInventoryScanner(rootURL: rootURL).scan()
        try await validateSnapshotStore()
        guard
            inventory.documents.flatMap(\.envelopes).allSatisfy({
                $0.version == 2 && $0.keyID == metadata.activeKeyID
            })
        else {
            throw WorkspaceKeyRotationError.incompleteRotation
        }
    }

    public func rotate() async throws {
        guard !operationInProgress else { throw WorkspaceKeyRotationError.operationInProgress }
        operationInProgress = true
        defer { operationInProgress = false }
        try WorkspaceFileSystem.recoverStagingDirectory(in: rootURL)

        let currentMetadata = try WorkspaceEncryptionMetadataFile.read(at: metadataURL)
        if let currentMetadata {
            await vault.configure(activeKeyID: currentMetadata.activeKeyID)
            if currentMetadata.pendingRotation {
                try await finishPendingRotation(currentMetadata)
                return
            }
        } else {
            await vault.configure(activeKeyID: nil)
            if try WorkspaceInventoryScanner(rootURL: rootURL).containsIdentifiedEnvelopes() {
                throw WorkspaceKeyRotationError.metadataRequiredForIdentifiedEnvelope
            }
        }

        let inventory = try WorkspaceInventoryScanner(rootURL: rootURL).scan()
        try await validateSnapshotStore()
        try await authenticate(inventory)
        try Task.checkCancellation()

        let newKeyID = try await vault.createRotationKey()
        let pendingMetadata = try WorkspaceEncryptionMetadataFile.write(
            activeKeyID: newKeyID,
            pendingRotation: true,
            at: metadataURL,
            expecting: currentMetadata?.rawData,
            stagingDirectory: stagingURL
        )
        try checkpoint?(.pendingPublished)
        await vault.configure(activeKeyID: newKeyID)
        try await finishPendingRotation(pendingMetadata)
    }

    private var metadataURL: URL {
        rootURL.appendingPathComponent("workspace-encryption.json", isDirectory: false)
    }

    private func finishPendingRotation(_ metadata: WorkspaceEncryptionMetadata) async throws {
        let targetKeyID = metadata.activeKeyID
        await vault.configure(activeKeyID: targetKeyID)

        let inventory = try WorkspaceInventoryScanner(rootURL: rootURL).scan()
        try await validateSnapshotStore()
        try await authenticate(inventory)
        try await validateActiveKey(targetKeyID)

        var rewrittenCount = 0
        for document in inventory.documents {
            try Task.checkCancellation()
            guard !document.envelopes.isEmpty else { continue }

            var replacements: [SecretEnvelope] = []
            replacements.reserveCapacity(document.envelopes.count)
            for envelope in document.envelopes {
                let replacement = try await vault.reencrypt(envelope)
                guard replacement.version == 2, replacement.keyID == targetKeyID else {
                    throw WorkspaceKeyRotationError.incompleteRotation
                }
                replacements.append(replacement)
            }
            guard replacements != document.envelopes else { continue }

            let replacementData = try EncryptedDocument.replacingEnvelopes(
                in: document.originalData,
                kind: document.kind,
                with: replacements
            )
            let nextRewriteIndex = rewrittenCount + 1
            try WorkspaceFileSystem.replace(
                replacementData,
                at: document.url,
                expecting: document.originalData,
                stagingDirectory: stagingURL,
                beforeCommit: { [checkpoint] in
                    try checkpoint?(.documentTemporaryWritten(nextRewriteIndex))
                }
            )
            rewrittenCount += 1
            try checkpoint?(.documentRewritten(rewrittenCount))
        }

        try Task.checkCancellation()
        let finalInventory = try WorkspaceInventoryScanner(rootURL: rootURL).scan()
        try await validateSnapshotStore()
        guard
            finalInventory.documents.flatMap(\.envelopes).allSatisfy({
                $0.version == 2 && $0.keyID == targetKeyID
            })
        else {
            throw WorkspaceKeyRotationError.incompleteRotation
        }
        try await authenticate(finalInventory)
        try await validateActiveKey(targetKeyID)

        let completedMetadata = try WorkspaceEncryptionMetadataFile.write(
            activeKeyID: targetKeyID,
            pendingRotation: false,
            at: metadataURL,
            expecting: metadata.rawData,
            stagingDirectory: stagingURL
        )
        await vault.configure(activeKeyID: completedMetadata.activeKeyID)
        try checkpoint?(.rotationCompleted)
    }

    private func authenticate(_ inventory: WorkspaceInventory) async throws {
        for document in inventory.documents {
            for envelope in document.envelopes {
                _ = try await vault.decrypt(envelope)
            }
        }
    }

    private func validateActiveKey(_ keyID: UUID) async throws {
        let probe = try await vault.encrypt("")
        guard probe.version == 2, probe.keyID == keyID else {
            throw WorkspaceKeyRotationError.incompleteRotation
        }
    }

    private func validateSnapshotStore() async throws {
        let load = try await SnapshotStore(
            rootURL: rootURL.appendingPathComponent("snapshots", isDirectory: true),
            vault: vault
        ).load()
        guard load.issues.isEmpty else { throw WorkspaceKeyRotationError.invalidWorkspace }
    }
}

private struct WorkspaceEncryptionMetadata: Sendable {
    let activeKeyID: UUID
    let pendingRotation: Bool
    let rawData: Data
}

private enum WorkspaceEncryptionMetadataFile {
    static func read(at url: URL) throws -> WorkspaceEncryptionMetadata? {
        switch try WorkspaceFileSystem.entryType(at: url) {
        case .missing:
            return nil
        case .regular:
            break
        default:
            throw WorkspaceKeyRotationError.invalidMetadata
        }

        guard try WorkspaceFileSystem.permissions(at: url) == 0o600 else {
            throw WorkspaceKeyRotationError.invalidMetadata
        }
        let data = try WorkspaceFileSystem.readRegularFile(at: url)
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawVersion = object["version"] as? NSNumber,
            CFGetTypeID(rawVersion) != CFBooleanGetTypeID(),
            rawVersion.doubleValue == 1,
            let rawKeyID = object["activeKeyID"] as? String,
            let activeKeyID = UUID(uuidString: rawKeyID),
            let rawPending = object["pendingRotation"] as? NSNumber,
            CFGetTypeID(rawPending) == CFBooleanGetTypeID()
        else {
            throw WorkspaceKeyRotationError.invalidMetadata
        }
        return WorkspaceEncryptionMetadata(
            activeKeyID: activeKeyID,
            pendingRotation: rawPending.boolValue,
            rawData: data
        )
    }

    static func write(
        activeKeyID: UUID,
        pendingRotation: Bool,
        at url: URL,
        expecting expectedData: Data?,
        stagingDirectory: URL
    ) throws -> WorkspaceEncryptionMetadata {
        var object: [String: Any] = [:]
        if let expectedData {
            guard let existing = try? JSONSerialization.jsonObject(with: expectedData) as? [String: Any] else {
                throw WorkspaceKeyRotationError.invalidMetadata
            }
            object = existing
        }
        object["version"] = 1
        object["activeKeyID"] = activeKeyID.uuidString
        object["pendingRotation"] = pendingRotation

        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw WorkspaceKeyRotationError.invalidMetadata
        }
        try WorkspaceFileSystem.writeAtomically(
            data,
            to: url,
            expecting: expectedData,
            stagingDirectory: stagingDirectory
        )
        return WorkspaceEncryptionMetadata(
            activeKeyID: activeKeyID,
            pendingRotation: pendingRotation,
            rawData: data
        )
    }
}

private struct WorkspaceInventoryDocument: Sendable {
    let url: URL
    let kind: EncryptedDocument.Kind
    let originalData: Data
    let envelopes: [SecretEnvelope]
}

private struct WorkspaceInventory: Sendable {
    let documents: [WorkspaceInventoryDocument]
}

private struct WorkspaceInventoryScanner {
    let rootURL: URL

    func scan() throws -> WorkspaceInventory {
        guard try WorkspaceFileSystem.entryType(at: rootURL) == .directory else {
            throw WorkspaceKeyRotationError.invalidWorkspace
        }
        try requireEmptyDirectoryIfPresent(named: ".moves")
        try requireEmptyDirectoryIfPresent(named: ".deletion-staging")

        var documents: [WorkspaceInventoryDocument] = []
        let globalsURL = rootURL.appendingPathComponent("globals.json", isDirectory: false)
        try appendDocument(at: globalsURL, kind: .globals, to: &documents)

        let collectionsURL = rootURL.appendingPathComponent("collections", isDirectory: true)
        let collectionEntries = try WorkspaceFileSystem.directoryEntries(at: collectionsURL)
        var seenCollectionIDs: Set<UUID> = []
        for collectionDirectory in collectionEntries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard try WorkspaceFileSystem.entryType(at: collectionDirectory) == .directory,
                let collectionID = UUID(uuidString: collectionDirectory.lastPathComponent)
            else {
                throw WorkspaceKeyRotationError.unsafeStorageEntry
            }
            guard seenCollectionIDs.insert(collectionID).inserted else {
                throw WorkspaceKeyRotationError.ambiguousIdentity
            }

            let metadataURL = collectionDirectory.appendingPathComponent("collection.json", isDirectory: false)
            let metadataData = try WorkspaceFileSystem.readRegularFile(at: metadataURL)
            let requestIDs = try indexedRequestIDs(in: metadataData)
            try appendDocument(at: metadataURL, kind: .collection, originalData: metadataData, to: &documents)

            var requestURLs: [UUID: URL] = [:]
            for entry in try WorkspaceFileSystem.directoryEntries(at: collectionDirectory) {
                guard try WorkspaceFileSystem.entryType(at: entry) == .regular else {
                    throw WorkspaceKeyRotationError.unsafeStorageEntry
                }
                if entry.lastPathComponent == "collection.json" { continue }
                guard entry.pathExtension.lowercased() == "json" else { continue }

                let stem = entry.deletingPathExtension().lastPathComponent
                guard let requestID = UUID(uuidString: stem) else {
                    throw WorkspaceKeyRotationError.malformedCollectionIndex
                }
                guard requestURLs.updateValue(entry, forKey: requestID) == nil else {
                    throw WorkspaceKeyRotationError.ambiguousIdentity
                }
                guard requestIDs.contains(requestID) else {
                    throw WorkspaceKeyRotationError.unindexedRequest
                }
            }

            guard requestIDs.allSatisfy({ requestURLs[$0] != nil }) else {
                throw WorkspaceKeyRotationError.missingRequest
            }
            for requestID in requestIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let requestURL = requestURLs[requestID] else {
                    throw WorkspaceKeyRotationError.missingRequest
                }
                try appendDocument(at: requestURL, kind: .request, to: &documents)
            }
        }

        let snapshotsURL = rootURL.appendingPathComponent("snapshots", isDirectory: true)
        if try WorkspaceFileSystem.entryType(at: snapshotsURL) != .missing {
            let snapshotEntries = try WorkspaceFileSystem.directoryEntries(at: snapshotsURL)
            for snapshotDirectory in snapshotEntries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if snapshotDirectory.lastPathComponent == ".staging" {
                    try requireEmptyDirectory(snapshotDirectory)
                    continue
                }
                guard try WorkspaceFileSystem.entryType(at: snapshotDirectory) == .directory,
                    let snapshotID = UUID(uuidString: snapshotDirectory.lastPathComponent),
                    snapshotID.uuidString == snapshotDirectory.lastPathComponent
                else {
                    throw WorkspaceKeyRotationError.unsafeStorageEntry
                }
                let children = try WorkspaceFileSystem.directoryEntries(at: snapshotDirectory)
                for child in children {
                    guard try WorkspaceFileSystem.entryType(at: child) == .regular,
                        ["snapshot.json", "response.body", ".postie-snapshot-stage"].contains(child.lastPathComponent)
                    else {
                        throw WorkspaceKeyRotationError.unsafeStorageEntry
                    }
                }
                let metadataURL = snapshotDirectory.appendingPathComponent("snapshot.json", isDirectory: false)
                let data = try WorkspaceFileSystem.readRegularFile(at: metadataURL)
                try appendDocument(at: metadataURL, kind: .snapshot, originalData: data, to: &documents)
            }
        }

        let automationURL = rootURL.appendingPathComponent("automation.json", isDirectory: false)
        if try WorkspaceFileSystem.entryType(at: automationURL) != .missing {
            try appendDocument(at: automationURL, kind: .automation, to: &documents)
        }

        return WorkspaceInventory(documents: documents)
    }

    func containsIdentifiedEnvelopes() throws -> Bool {
        var candidates: [(URL, EncryptedDocument.Kind)] = []
        let globalsURL = rootURL.appendingPathComponent("globals.json", isDirectory: false)
        candidates.append((globalsURL, .globals))

        let collectionsURL = rootURL.appendingPathComponent("collections", isDirectory: true)
        if try WorkspaceFileSystem.entryType(at: collectionsURL) == .directory {
            for directory in try WorkspaceFileSystem.directoryEntries(at: collectionsURL) {
                guard UUID(uuidString: directory.lastPathComponent) != nil,
                    try WorkspaceFileSystem.entryType(at: directory) == .directory
                else { continue }
                candidates.append((directory.appendingPathComponent("collection.json"), .collection))
                for entry in try WorkspaceFileSystem.directoryEntries(at: directory)
                where entry.pathExtension.lowercased() == "json"
                    && UUID(uuidString: entry.deletingPathExtension().lastPathComponent) != nil
                {
                    candidates.append((entry, .request))
                }
            }
        }

        let snapshotsURL = rootURL.appendingPathComponent("snapshots", isDirectory: true)
        if try WorkspaceFileSystem.entryType(at: snapshotsURL) == .directory {
            for directory in try WorkspaceFileSystem.directoryEntries(at: snapshotsURL) {
                guard UUID(uuidString: directory.lastPathComponent)?.uuidString == directory.lastPathComponent,
                    try WorkspaceFileSystem.entryType(at: directory) == .directory
                else { continue }
                candidates.append((directory.appendingPathComponent("snapshot.json"), .snapshot))
            }
        }
        candidates.append((rootURL.appendingPathComponent("automation.json"), .automation))

        for (url, kind) in candidates {
            guard try WorkspaceFileSystem.entryType(at: url) == .regular,
                let data = try? WorkspaceFileSystem.readRegularFile(at: url),
                let envelopes = try? EncryptedDocument.envelopes(in: data, kind: kind)
            else { continue }
            if envelopes.contains(where: { $0.version == 2 || $0.keyID != nil }) { return true }
        }
        return false
    }

    private func requireEmptyDirectoryIfPresent(named name: String) throws {
        let url = rootURL.appendingPathComponent(name, isDirectory: true)
        guard try WorkspaceFileSystem.entryType(at: url) != .missing else { return }
        try requireEmptyDirectory(url)
    }

    private func requireEmptyDirectory(_ url: URL) throws {
        guard try WorkspaceFileSystem.entryType(at: url) == .directory,
            try WorkspaceFileSystem.directoryEntries(at: url).isEmpty
        else {
            throw WorkspaceKeyRotationError.unsafeStorageEntry
        }
    }

    private func indexedRequestIDs(in data: Data) throws -> Set<UUID> {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawVersion = object["formatVersion"] as? NSNumber,
            CFGetTypeID(rawVersion) != CFBooleanGetTypeID(),
            rawVersion.doubleValue == 1,
            object["name"] is String,
            let rawIDs = object["requests"] as? [String]
        else {
            throw WorkspaceKeyRotationError.malformedCollectionIndex
        }

        var ids: Set<UUID> = []
        for rawID in rawIDs {
            guard let id = UUID(uuidString: rawID) else {
                throw WorkspaceKeyRotationError.malformedCollectionIndex
            }
            guard ids.insert(id).inserted else {
                throw WorkspaceKeyRotationError.ambiguousIdentity
            }
        }
        return ids
    }

    private func appendDocument(
        at url: URL,
        kind: EncryptedDocument.Kind,
        originalData: Data? = nil,
        to documents: inout [WorkspaceInventoryDocument]
    ) throws {
        let data = try originalData ?? WorkspaceFileSystem.readRegularFile(at: url)
        let envelopes = try EncryptedDocument.envelopes(in: data, kind: kind)
        try validateOwnedDocument(data, kind: kind)
        documents.append(WorkspaceInventoryDocument(url: url, kind: kind, originalData: data, envelopes: envelopes))
    }

    private func validateOwnedDocument(_ data: Data, kind: EncryptedDocument.Kind) throws {
        let decoder = JSONDecoder()
        switch kind {
        case .globals:
            let document = try decoder.decode(RotationGlobalsDocument.self, from: data)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                document.formatVersion == 1,
                document.mcpResponseViewing != .inherit
            else {
                throw WorkspaceKeyRotationError.invalidWorkspace
            }
            if let rawOptions = object["httpOptions"] {
                guard let options = document.httpOptions,
                    let optionFields = rawOptions as? [String: Any],
                    ["followRedirects", "inactivityTimeout", "overallTimeout", "maximumResponseBytes"]
                        .allSatisfy({ optionFields[$0] != nil }),
                    options.inactivityTimeout.isFinite, options.inactivityTimeout > 0,
                    options.overallTimeout.map({ $0.isFinite && $0 > 0 }) ?? true,
                    options.maximumResponseBytes.map({ $0 >= 0 }) ?? true
                else {
                    throw WorkspaceKeyRotationError.invalidWorkspace
                }
            }
            if let rawPolicy = object["mcpResponseViewing"] {
                guard let policy = rawPolicy as? String,
                    let decoded = MCPResponseViewPolicy(rawValue: policy), decoded != .inherit
                else {
                    throw WorkspaceKeyRotationError.invalidWorkspace
                }
            }
        case .collection:
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                object["id"] == nil,
                !["headers", "mcpPolicy"].contains(where: { object[$0] is NSNull })
            else {
                throw WorkspaceKeyRotationError.invalidWorkspace
            }
            let document = try decoder.decode(RotationCollectionDocument.self, from: data)
            guard document.formatVersion == 1 else { throw WorkspaceKeyRotationError.invalidWorkspace }
        case .request:
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["id"] == nil
            else {
                throw WorkspaceKeyRotationError.invalidWorkspace
            }
            let document = try decoder.decode(RotationRequestDocument.self, from: data)
            let hasUpload =
                document.bodyKind.map { $0 != .text } == true
                || document.rawFile != nil || !(document.multipartParts ?? []).isEmpty
            guard (document.formatVersion == 1 || document.formatVersion == 2),
                document.formatVersion != 1 || !hasUpload,
                document.formatVersion != 2 || document.bodyKind != nil
            else {
                throw WorkspaceKeyRotationError.invalidWorkspace
            }
        case .snapshot:
            break
        case .automation:
            let document = try decoder.decode(RotationAutomationDocument.self, from: data)
            guard document.formatVersion == 1 else { throw WorkspaceKeyRotationError.invalidWorkspace }
        }
    }
}

private struct RotationGlobalsDocument: Decodable {
    let formatVersion: Int
    let variables: VariableValues
    let httpOptions: HTTPOptions?
    let mcpResponseViewing: MCPResponseViewPolicy?
}

private struct RotationCollectionDocument: Decodable {
    let formatVersion: Int
    let name: String
    let variables: VariableValues?
    let headers: [HTTPField]?
    let authentication: RequestAuthentication?
    let mcpPolicy: MCPResourcePolicy?
    let requests: [String]
}

private struct RotationRequestDocument: Decodable {
    let formatVersion: Int
    let name: String
    let method: String
    let url: String
    let pathParameters: [HTTPField]?
    let query: [HTTPField]
    let headers: [HTTPField]
    let body: String
    let bodyEnabled: Bool
    let bodySyntax: BodySyntax
    let bodyKind: RequestBodyKind?
    let rawFile: HTTPFileReference?
    let multipartParts: [HTTPMultipartPart]?
    let options: HTTPOptions
    let optionOverrides: HTTPOptionsOverrides?
    let variables: VariableValues?
    let authentication: RequestAuthentication?
    let inheritsCollectionAuthentication: Bool?
    let mcpPolicy: MCPResourcePolicy?
}

private struct RotationAutomationDocument: Decodable {
    let formatVersion: Int
    let token: SecretEnvelope
}

private enum WorkspaceEntryType: Equatable {
    case missing
    case regular
    case directory
    case symbolicLink
    case other
}

private enum WorkspaceFileSystem {
    static func entryType(at url: URL) throws -> WorkspaceEntryType {
        var information = stat()
        let result = url.path.withCString { pointer in
            #if canImport(Darwin)
                Darwin.lstat(pointer, &information)
            #else
                Glibc.lstat(pointer, &information)
            #endif
        }
        if result != 0 {
            if currentErrno == ENOENT { return .missing }
            throw WorkspaceKeyRotationError.fileSystemFailure
        }

        let fileType = information.st_mode & mode_t(S_IFMT)
        if fileType == mode_t(S_IFREG) { return .regular }
        if fileType == mode_t(S_IFDIR) { return .directory }
        if fileType == mode_t(S_IFLNK) { return .symbolicLink }
        return .other
    }

    static func permissions(at url: URL) throws -> mode_t {
        var information = stat()
        let result = url.path.withCString { pointer in
            #if canImport(Darwin)
                Darwin.lstat(pointer, &information)
            #else
                Glibc.lstat(pointer, &information)
            #endif
        }
        guard result == 0 else { throw WorkspaceKeyRotationError.fileSystemFailure }
        return information.st_mode & 0o777
    }

    static func directoryEntries(at url: URL) throws -> [URL] {
        guard try entryType(at: url) == .directory else {
            throw WorkspaceKeyRotationError.unsafeStorageEntry
        }
        do {
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        } catch {
            throw WorkspaceKeyRotationError.fileSystemFailure
        }
    }

    static func readRegularFile(at url: URL) throws -> Data {
        let descriptor = openPath(url.path, flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW, mode: 0)
        guard descriptor >= 0 else {
            if currentErrno == ELOOP { throw WorkspaceKeyRotationError.unsafeStorageEntry }
            throw WorkspaceKeyRotationError.fileSystemFailure
        }
        defer { _ = closeDescriptor(descriptor) }

        var information = stat()
        guard fileStat(descriptor, &information) == 0 else {
            throw WorkspaceKeyRotationError.fileSystemFailure
        }
        guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw WorkspaceKeyRotationError.unsafeStorageEntry
        }

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                readDescriptor(descriptor, bytes.baseAddress!, bytes.count)
            }
            if count < 0 && currentErrno == EINTR { continue }
            guard count >= 0 else { throw WorkspaceKeyRotationError.fileSystemFailure }
            if count == 0 { return result }
            result.append(contentsOf: buffer.prefix(Int(count)))
        }
    }

    static func recoverStagingDirectory(in rootURL: URL) throws {
        guard try entryType(at: rootURL) == .directory else {
            if try entryType(at: rootURL) == .missing { return }
            throw WorkspaceKeyRotationError.invalidWorkspace
        }
        let stagingDirectory = rootURL.appendingPathComponent(".key-rotation-staging", isDirectory: true)
        guard try entryType(at: stagingDirectory) != .missing else { return }
        guard try entryType(at: stagingDirectory) == .directory,
            try permissions(at: stagingDirectory) == 0o700
        else {
            throw WorkspaceKeyRotationError.unsafeStorageEntry
        }

        for entry in try directoryEntries(at: stagingDirectory) {
            let name = entry.lastPathComponent
            let prefix = ".postie-workspace-key-rotation-"
            guard name.hasPrefix(prefix), name.hasSuffix(".tmp"),
                UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(4))) != nil,
                try entryType(at: entry) == .regular,
                try permissions(at: entry) == 0o600
            else {
                throw WorkspaceKeyRotationError.unsafeStorageEntry
            }
            guard unlinkPath(entry.path) == 0 else {
                throw WorkspaceKeyRotationError.fileSystemFailure
            }
        }
        try syncDirectory(stagingDirectory)
    }

    static func writeAtomically(
        _ data: Data,
        to destination: URL,
        expecting expectedData: Data?,
        stagingDirectory: URL,
        beforeCommit: (() throws -> Void)? = nil
    ) throws {
        try verifyExpectedData(expectedData, at: destination)
        guard try entryType(at: destination.deletingLastPathComponent()) == .directory else {
            throw WorkspaceKeyRotationError.fileSystemFailure
        }
        try ensureStagingDirectory(stagingDirectory)

        let temporary = stagingDirectory.appendingPathComponent(
            ".postie-workspace-key-rotation-\(UUID().uuidString).tmp"
        )
        let descriptor = openPath(
            temporary.path,
            flags: O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
            mode: 0o600
        )
        guard descriptor >= 0 else { throw WorkspaceKeyRotationError.fileSystemFailure }
        var temporaryExists = true
        var descriptorOpen = true
        defer {
            if descriptorOpen { _ = closeDescriptor(descriptor) }
            if temporaryExists { _ = unlinkPath(temporary.path) }
        }

        var failed = false
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = writeDescriptor(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0 && currentErrno == EINTR { continue }
                guard count > 0 else {
                    failed = true
                    break
                }
                offset += count
            }
        }
        guard !failed, syncDescriptor(descriptor) == 0 else {
            throw WorkspaceKeyRotationError.fileSystemFailure
        }
        guard closeDescriptor(descriptor) == 0 else {
            descriptorOpen = false
            throw WorkspaceKeyRotationError.fileSystemFailure
        }
        descriptorOpen = false

        do {
            try beforeCommit?()
        } catch {
            temporaryExists = false
            throw error
        }

        try verifyExpectedData(expectedData, at: destination)
        if expectedData == nil {
            guard linkPath(temporary.path, destination.path) == 0 else {
                if currentErrno == EEXIST { throw WorkspaceKeyRotationError.concurrentModification }
                throw WorkspaceKeyRotationError.fileSystemFailure
            }
            guard unlinkPath(temporary.path) == 0 else {
                temporaryExists = false
                throw WorkspaceKeyRotationError.fileSystemFailure
            }
        } else {
            guard renamePath(temporary.path, destination.path) == 0 else {
                throw WorkspaceKeyRotationError.fileSystemFailure
            }
        }
        temporaryExists = false
        try syncDirectory(destination.deletingLastPathComponent())
        try syncDirectory(stagingDirectory)
    }

    static func replace(
        _ data: Data,
        at destination: URL,
        expecting expectedData: Data,
        stagingDirectory: URL,
        beforeCommit: (() throws -> Void)? = nil
    ) throws {
        try writeAtomically(
            data,
            to: destination,
            expecting: expectedData,
            stagingDirectory: stagingDirectory,
            beforeCommit: beforeCommit
        )
    }

    private static func ensureStagingDirectory(_ stagingDirectory: URL) throws {
        switch try entryType(at: stagingDirectory) {
        case .missing:
            do {
                try FileManager.default.createDirectory(
                    at: stagingDirectory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw WorkspaceKeyRotationError.fileSystemFailure
            }
            try syncDirectory(stagingDirectory.deletingLastPathComponent())
        case .directory:
            guard try permissions(at: stagingDirectory) == 0o700 else {
                throw WorkspaceKeyRotationError.unsafeStorageEntry
            }
        default:
            throw WorkspaceKeyRotationError.unsafeStorageEntry
        }
    }

    private static func verifyExpectedData(_ expectedData: Data?, at destination: URL) throws {
        switch (expectedData, try entryType(at: destination)) {
        case (nil, .missing): return
        case (.some(let expected), .regular):
            guard try readRegularFile(at: destination) == expected else {
                throw WorkspaceKeyRotationError.concurrentModification
            }
        case (nil, _): throw WorkspaceKeyRotationError.concurrentModification
        default: throw WorkspaceKeyRotationError.unsafeStorageEntry
        }
    }

    private static func syncDirectory(_ directory: URL) throws {
        let descriptor = openPath(directory.path, flags: O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW, mode: 0)
        guard descriptor >= 0 else { throw WorkspaceKeyRotationError.fileSystemFailure }
        defer { _ = closeDescriptor(descriptor) }
        guard syncDescriptor(descriptor) == 0 else { throw WorkspaceKeyRotationError.fileSystemFailure }
    }

    private static var currentErrno: Int32 {
        #if canImport(Darwin)
            Darwin.errno
        #else
            Glibc.errno
        #endif
    }

    private static func openPath(_ path: String, flags: Int32, mode: mode_t) -> Int32 {
        path.withCString { pointer in
            #if canImport(Darwin)
                Darwin.open(pointer, flags, mode)
            #else
                Glibc.open(pointer, flags, mode)
            #endif
        }
    }

    private static func fileStat(_ descriptor: Int32, _ information: UnsafeMutablePointer<stat>) -> Int32 {
        #if canImport(Darwin)
            Darwin.fstat(descriptor, information)
        #else
            Glibc.fstat(descriptor, information)
        #endif
    }

    private static func readDescriptor(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
            Darwin.read(descriptor, buffer, count)
        #else
            Glibc.read(descriptor, buffer, count)
        #endif
    }

    private static func writeDescriptor(_ descriptor: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
            Darwin.write(descriptor, buffer, count)
        #else
            Glibc.write(descriptor, buffer, count)
        #endif
    }

    private static func syncDescriptor(_ descriptor: Int32) -> Int32 {
        #if canImport(Darwin)
            Darwin.fsync(descriptor)
        #else
            Glibc.fsync(descriptor)
        #endif
    }

    private static func closeDescriptor(_ descriptor: Int32) -> Int32 {
        #if canImport(Darwin)
            Darwin.close(descriptor)
        #else
            Glibc.close(descriptor)
        #endif
    }

    private static func linkPath(_ source: String, _ destination: String) -> Int32 {
        source.withCString { sourcePointer in
            destination.withCString { destinationPointer in
                #if canImport(Darwin)
                    Darwin.link(sourcePointer, destinationPointer)
                #else
                    Glibc.link(sourcePointer, destinationPointer)
                #endif
            }
        }
    }

    private static func renamePath(_ source: String, _ destination: String) -> Int32 {
        source.withCString { sourcePointer in
            destination.withCString { destinationPointer in
                #if canImport(Darwin)
                    Darwin.rename(sourcePointer, destinationPointer)
                #else
                    Glibc.rename(sourcePointer, destinationPointer)
                #endif
            }
        }
    }

    private static func unlinkPath(_ path: String) -> Int32 {
        path.withCString { pointer in
            #if canImport(Darwin)
                Darwin.unlink(pointer)
            #else
                Glibc.unlink(pointer)
            #endif
        }
    }
}
