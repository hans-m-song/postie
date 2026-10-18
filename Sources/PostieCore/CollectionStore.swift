import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum CollectionStoreError: LocalizedError, Sendable {
    case alreadyOpen
    case collectionNotFound
    case collectionIsAmbiguous
    case collectionIsReadOnly
    case requestNotFound
    case requestAlreadyExists
    case requestIsNotIndexed
    case requestIsAmbiguous
    case requestDocumentIsMalformed
    case requestVersionIsUnsupported
    case requestOrderIsInvalid
    case ioFailure(operation: String)
    case partialFailure(operation: String)

    public var errorDescription: String? {
        switch self {
        case .alreadyOpen:
            "Another Postie instance already owns this data directory."
        case .collectionNotFound:
            "The collection could not be found."
        case .collectionIsAmbiguous:
            "The collection has more than one directory with the same identity."
        case .collectionIsReadOnly:
            "The collection format is unavailable or damaged, so it is read-only."
        case .requestNotFound:
            "The request could not be found."
        case .requestAlreadyExists:
            "A request with this identity already exists."
        case .requestIsNotIndexed:
            "The request is not a member of this collection."
        case .requestIsAmbiguous:
            "The collection has more than one index entry or file for this request."
        case .requestDocumentIsMalformed:
            "The request document is malformed and was preserved."
        case .requestVersionIsUnsupported:
            "The request document uses an unsupported format and was preserved."
        case .requestOrderIsInvalid:
            "The requested order does not match the collection's available requests."
        case .ioFailure(let operation):
            "Postie could not \(operation)."
        case .partialFailure(let operation):
            "Postie could not finish \(operation); remaining data was preserved for recovery."
        }
    }
}

public actor CollectionStore {
    private static let currentFormatVersion = 1
    private static let lockFilename = ".postie.lock"
    private static let globalsFilename = "globals.json"
    private static let collectionsDirectoryName = "collections"
    private static let deletionStagingDirectoryName = ".deletion-staging"

    private let rootURL: URL
    private let collectionsURL: URL
    private let globalsURL: URL
    private let deletionStagingURL: URL
    private let lockPath: String
    private var lockDescriptor: Int32 = -1

    public init(rootURL: URL) throws {
        let resolvedRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.rootURL = resolvedRoot
        self.collectionsURL = resolvedRoot.appendingPathComponent(Self.collectionsDirectoryName, isDirectory: true)
        self.globalsURL = resolvedRoot.appendingPathComponent(Self.globalsFilename, isDirectory: false)
        self.deletionStagingURL = resolvedRoot.appendingPathComponent(Self.deletionStagingDirectoryName, isDirectory: true)
        let lockURL = resolvedRoot.appendingPathComponent(Self.lockFilename, isDirectory: false)
        self.lockPath = lockURL.path

        do {
            try FileManager.default.createDirectory(at: resolvedRoot, withIntermediateDirectories: true)
        } catch {
            throw CollectionStoreError.ioFailure(operation: "create the data directory")
        }

        guard ProcessLockRegistry.shared.claim(lockURL.path) else {
            throw CollectionStoreError.alreadyOpen
        }
        let descriptor = Self.openLock(at: lockURL)
        guard descriptor >= 0 else {
            ProcessLockRegistry.shared.release(lockURL.path)
            throw CollectionStoreError.ioFailure(operation: "open the data-directory lock")
        }
        guard Self.lockExclusively(descriptor) == 0 else {
            ProcessLockRegistry.shared.release(lockURL.path)
            _ = Self.closeDescriptor(descriptor)
            throw CollectionStoreError.alreadyOpen
        }
        self.lockDescriptor = descriptor

        do {
            try FileManager.default.createDirectory(at: collectionsURL, withIntermediateDirectories: true)
            guard Self.isDirectory(collectionsURL) else {
                throw CollectionStoreError.ioFailure(operation: "prepare the collections directory")
            }
            try Self.initializeGlobalsIfMissing(at: globalsURL)
        } catch let error as CollectionStoreError {
            self.lockDescriptor = -1
            ProcessLockRegistry.shared.release(lockPath)
            _ = Self.closeDescriptor(descriptor)
            throw error
        } catch {
            self.lockDescriptor = -1
            ProcessLockRegistry.shared.release(lockPath)
            _ = Self.closeDescriptor(descriptor)
            throw CollectionStoreError.ioFailure(operation: "initialize the data directory")
        }
    }

    deinit {
        if lockDescriptor >= 0 {
            _ = Self.closeDescriptor(lockDescriptor)
            ProcessLockRegistry.shared.release(lockPath)
        }
    }

    public func load() throws -> WorkspaceLoad {
        var issues: [StorageIssue] = []
        let globals = loadGlobals(issues: &issues)

        let collectionEntries: [URL]
        do {
            collectionEntries = try FileManager.default.contentsOfDirectory(
                at: collectionsURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
        } catch {
            throw CollectionStoreError.ioFailure(operation: "list collections")
        }

        var validDirectories: [(id: UUID, url: URL)] = []
        for url in collectionEntries {
            guard Self.isDirectory(url) else {
                issues.append(makeIssue(.unexpectedCollectionEntry, detail: url.lastPathComponent, message: "An unrecognised item in the collections directory was preserved."))
                continue
            }
            guard let id = UUID(uuidString: url.lastPathComponent) else {
                issues.append(makeIssue(.invalidCollectionDirectory, detail: url.lastPathComponent, message: "A collection directory has an invalid identity and was preserved."))
                continue
            }
            validDirectories.append((id, url))
        }

        let groupedDirectories = Dictionary(grouping: validDirectories, by: \.id)
        var collections: [RequestCollection] = []
        for id in groupedDirectories.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let directories = groupedDirectories[id], directories.count == 1, let directory = directories.first?.url else {
                issues.append(makeIssue(.duplicateCollectionDirectory, collectionID: id, message: "More than one collection directory has this identity; the collection was not loaded."))
                collections.append(RequestCollection(id: id, name: "Ambiguous collection", isReadOnly: true))
                continue
            }

            collections.append(loadCollection(id: id, at: directory, issues: &issues))
        }

        appendStagedDeletionIssues(to: &issues)
        collections.sort {
            if $0.name.localizedStandardCompare($1.name) == .orderedSame {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }

        return WorkspaceLoad(
            collections: collections,
            issues: issues,
            globalVariables: globals.values,
            globalVariablesAreReadOnly: globals.isReadOnly,
            globalOptions: globals.options,
            globalOptionsAreReadOnly: globals.optionsAreReadOnly
        )
    }

    public func saveGlobalVariables(_ variables: VariableValues) throws {
        var object = try writableGlobalsObject()
        let incoming = try Self.variableJSONValue(variables)
        let existing = object["variables"] ?? .object([:])
        object["variables"] = Self.mergeOwnedVariables(existing, with: incoming)
        try replaceJSON(.object(object), at: globalsURL, operation: "save global variables")
    }

    public func saveGlobalOptions(_ options: HTTPOptions) throws {
        guard Self.valid(options) else {
            throw CollectionStoreError.ioFailure(operation: "save invalid global HTTP settings")
        }

        var object = try writableGlobalsObject()
        let incoming = try Self.httpOptionsJSONValue(options)
        if let existing = object["httpOptions"] {
            do {
                _ = try Self.decodeHTTPOptions(existing)
            } catch {
                throw CollectionStoreError.ioFailure(operation: "save global HTTP settings because their stored value is malformed")
            }
            object["httpOptions"] = Self.mergeUnknownData(existing, with: incoming)
        } else {
            object["httpOptions"] = incoming
        }
        try replaceJSON(.object(object), at: globalsURL, operation: "save global HTTP settings")
    }

    public func saveCollectionVariables(_ variables: VariableValues, in collectionID: UUID) throws {
        let (directory, record) = try writableCollection(id: collectionID)
        let existing = record.object["variables"] ?? .object([:])
        var updated = record
        let incoming = try Self.variableJSONValue(variables)
        updated.object["variables"] = Self.mergeOwnedVariables(existing, with: incoming)
        try replaceJSON(updated.jsonValue, at: directory.appendingPathComponent("collection.json"), operation: "save collection variables")
    }

    public func saveCollectionConfiguration(
        _ defaults: CollectionRequestDefaults,
        variables: VariableValues,
        in collectionID: UUID
    ) throws {
        let (directory, record) = try writableCollection(id: collectionID)
        let settings = try Self.collectionDefaultsJSONValue(defaults)
        guard case .object(let settingsObject) = settings,
              let incomingHeaders = settingsObject["headers"],
              let incomingAuthentication = settingsObject["authentication"] else {
            throw CollectionStoreError.ioFailure(operation: "encode collection settings")
        }

        var updated = record
        let existingVariables = updated.object["variables"] ?? .object([:])
        let incomingVariables = try Self.variableJSONValue(variables)
        updated.object["variables"] = Self.mergeOwnedVariables(existingVariables, with: incomingVariables)
        updated.object["headers"] = Self.mergeUnknownData(updated.object["headers"] ?? .array([]), with: incomingHeaders)
        updated.object["authentication"] = Self.mergeAuthentication(updated.object["authentication"] ?? .object([:]), with: incomingAuthentication)
        try replaceJSON(updated.jsonValue, at: directory.appendingPathComponent("collection.json"), operation: "save collection configuration")
    }

    public func createCollection(name: String) throws -> RequestCollection {
        var id = UUID()
        var directoryURL = collectionDirectoryURL(id)
        for _ in 0..<4 {
            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
                let record = CollectionRecord(name: name, entries: [])
                do {
                    try writeNewJSON(record.jsonValue, to: directoryURL.appendingPathComponent("collection.json"), operation: "create collection metadata")
                } catch {
                    do {
                        let remaining = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
                        if remaining.isEmpty {
                            try FileManager.default.removeItem(at: directoryURL)
                        }
                    } catch {
                        throw CollectionStoreError.partialFailure(operation: "create the collection")
                    }
                    throw error
                }
                return RequestCollection(id: id, name: name)
            } catch let error as CollectionStoreError {
                throw error
            } catch {
                if FileManager.default.fileExists(atPath: directoryURL.path) {
                    id = UUID()
                    directoryURL = collectionDirectoryURL(id)
                    continue
                }
                throw CollectionStoreError.ioFailure(operation: "create the collection")
            }
        }
        throw CollectionStoreError.ioFailure(operation: "allocate a collection identity")
    }

    public func renameCollection(id: UUID, name: String) throws {
        let (directory, record) = try writableCollection(id: id)
        var renamed = record
        renamed.name = name
        try replaceJSON(renamed.jsonValue, at: directory.appendingPathComponent("collection.json"), operation: "rename the collection")
    }

    public func deleteCollection(id: UUID) throws {
        let (directory, _) = try writableCollection(id: id)
        do {
            if Self.fileMode(at: deletionStagingURL) != nil && !Self.isDirectory(deletionStagingURL) {
                throw CollectionStoreError.ioFailure(operation: "prepare collection deletion")
            }
            try FileManager.default.createDirectory(at: deletionStagingURL, withIntermediateDirectories: true)
            guard Self.isDirectory(deletionStagingURL) else {
                throw CollectionStoreError.ioFailure(operation: "prepare collection deletion")
            }
        } catch {
            if let error = error as? CollectionStoreError { throw error }
            throw CollectionStoreError.ioFailure(operation: "prepare collection deletion")
        }

        var stagedURL: URL?
        for _ in 0..<4 {
            let candidate = deletionStagingURL.appendingPathComponent("\(id.uuidString.lowercased())-\(UUID().uuidString.lowercased())", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                continue
            }
            do {
                try FileManager.default.moveItem(at: directory, to: candidate)
                stagedURL = candidate
                break
            } catch {
                if FileManager.default.fileExists(atPath: candidate.path) {
                    if !FileManager.default.fileExists(atPath: directory.path) {
                        throw CollectionStoreError.partialFailure(operation: "stage the collection for deletion")
                    }
                    continue
                }
                throw CollectionStoreError.ioFailure(operation: "stage the collection for deletion")
            }
        }
        guard let stagedURL else {
            throw CollectionStoreError.ioFailure(operation: "stage the collection for deletion")
        }

        do {
            try FileManager.default.removeItem(at: stagedURL)
        } catch {
            throw CollectionStoreError.partialFailure(operation: "delete the collection")
        }
    }

    public func createRequest(_ request: HTTPRequestConfiguration, in collectionID: UUID) throws {
        let (directory, record) = try writableCollection(id: collectionID)
        let membershipCount = record.entries.reduce(into: 0) { count, entry in
            if Self.uuidValue(entry) == request.id { count += 1 }
        }
        guard membershipCount == 0 else {
            throw membershipCount > 1 ? CollectionStoreError.requestIsAmbiguous : CollectionStoreError.requestAlreadyExists
        }

        let requestFiles = try requestFileURLs(in: directory)
        guard requestFiles[request.id, default: []].isEmpty else {
            throw CollectionStoreError.requestAlreadyExists
        }

        let destination = directory.appendingPathComponent(Self.requestFilename(request.id), isDirectory: false)
        let data = try encodeRequest(request)
        do {
            try AtomicFileWriter.writeNew(data, to: destination)
        } catch {
            throw CollectionStoreError.ioFailure(operation: "create the request")
        }

        var updated = record
        updated.entries.append(.string(Self.canonicalID(request.id)))
        do {
            try replaceJSON(updated.jsonValue, at: directory.appendingPathComponent("collection.json"), operation: "update collection membership")
        } catch {
            throw CollectionStoreError.partialFailure(operation: "create the request; it remains available for explicit recovery")
        }
    }

    public func saveRequest(_ request: HTTPRequestConfiguration, in collectionID: UUID) throws {
        let (directory, record) = try writableCollection(id: collectionID)
        let membershipCount = record.entries.reduce(into: 0) { count, entry in
            if Self.uuidValue(entry) == request.id { count += 1 }
        }
        guard membershipCount == 1 else {
            throw membershipCount > 1 ? CollectionStoreError.requestIsAmbiguous : CollectionStoreError.requestIsNotIndexed
        }

        let requestFiles = try requestFileURLs(in: directory)
        let urls = requestFiles[request.id, default: []]
        guard urls.count == 1, let url = urls.first else {
            throw urls.count > 1 ? CollectionStoreError.requestIsAmbiguous : CollectionStoreError.requestNotFound
        }

        let existing = try readRequest(at: url, identity: request.id)
        let incoming = try requestJSONValue(request)
        let merged = Self.mergeRequestData(existing.jsonValue, with: incoming)
        try replaceJSON(merged, at: url, operation: "save the request")
    }

    public func deleteRequest(id: UUID, in collectionID: UUID) throws {
        let (directory, record) = try writableCollection(id: collectionID)
        let matchingIndices = record.entries.indices.filter { Self.uuidValue(record.entries[$0]) == id }
        guard matchingIndices.count == 1, let matchingIndex = matchingIndices.first else {
            throw matchingIndices.count > 1 ? CollectionStoreError.requestIsAmbiguous : CollectionStoreError.requestIsNotIndexed
        }

        let requestFiles = try requestFileURLs(in: directory)
        let urls = requestFiles[id, default: []]
        guard urls.count <= 1 else {
            throw CollectionStoreError.requestIsAmbiguous
        }

        var updated = record
        updated.entries.remove(at: matchingIndex)
        try replaceJSON(updated.jsonValue, at: directory.appendingPathComponent("collection.json"), operation: "remove request membership")

        guard let requestURL = urls.first else { return }
        if Self.isDirectory(requestURL) && !Self.isSymbolicLink(requestURL) {
            throw CollectionStoreError.partialFailure(operation: "delete the request file")
        }
        do {
            try FileManager.default.removeItem(at: requestURL)
        } catch {
            throw CollectionStoreError.partialFailure(operation: "delete the request file")
        }
    }

    public func recoverRequest(id: UUID, in collectionID: UUID) throws {
        let (directory, record) = try writableCollection(id: collectionID)
        let membershipCount = record.entries.reduce(into: 0) { count, entry in
            if Self.uuidValue(entry) == id { count += 1 }
        }
        guard membershipCount == 0 else {
            throw membershipCount > 1 ? CollectionStoreError.requestIsAmbiguous : CollectionStoreError.requestAlreadyExists
        }

        let requestFiles = try requestFileURLs(in: directory)
        let urls = requestFiles[id, default: []]
        guard urls.count == 1, let url = urls.first else {
            throw urls.count > 1 ? CollectionStoreError.requestIsAmbiguous : CollectionStoreError.requestNotFound
        }
        _ = try readRequest(at: url, identity: id)

        var updated = record
        updated.entries.append(.string(Self.canonicalID(id)))
        try replaceJSON(updated.jsonValue, at: directory.appendingPathComponent("collection.json"), operation: "recover the request")
    }

    public func reorderRequests(ids: [UUID], in collectionID: UUID) throws {
        let (directory, record) = try writableCollection(id: collectionID)
        let counts = record.entries.reduce(into: [UUID: Int]()) { result, entry in
            if let id = Self.uuidValue(entry) { result[id, default: 0] += 1 }
        }
        let requestFiles = try requestFileURLs(in: directory)
        var movableIndices: [Int] = []
        var movableIDs: [UUID] = []

        for (index, entry) in record.entries.enumerated() {
            guard let id = Self.uuidValue(entry), counts[id] == 1 else { continue }
            let urls = requestFiles[id, default: []]
            guard urls.count == 1, let url = urls.first, (try? readRequest(at: url, identity: id)) != nil else { continue }
            movableIndices.append(index)
            movableIDs.append(id)
        }

        guard ids.count == Set(ids).count, Set(ids) == Set(movableIDs) else {
            throw CollectionStoreError.requestOrderIsInvalid
        }

        guard !movableIndices.isEmpty else { return }
        var updated = record
        for (index, id) in zip(movableIndices, ids) {
            updated.entries[index] = .string(Self.canonicalID(id))
        }
        try replaceJSON(updated.jsonValue, at: directory.appendingPathComponent("collection.json"), operation: "reorder requests")
    }

    private static func initializeGlobalsIfMissing(at url: URL) throws {
        guard fileMode(at: url) == nil else { return }
        let options = try httpOptionsJSONValue(HTTPOptions())
        let emptyGlobals = JSONValue.object([
            "formatVersion": .number(Decimal(currentFormatVersion)),
            "variables": .object([:]),
            "httpOptions": options
        ])
        do {
            let data = try JSONEncoder.postieEncoder.encode(emptyGlobals)
            try AtomicFileWriter.writeNew(data, to: url)
        } catch {
            if FileManager.default.fileExists(atPath: url.path) { return }
            throw CollectionStoreError.ioFailure(operation: "create the initial globals document")
        }
    }

    private func loadGlobals(issues: inout [StorageIssue]) -> (
        values: VariableValues,
        isReadOnly: Bool,
        options: HTTPOptions,
        optionsAreReadOnly: Bool
    ) {
        guard Self.isRegularFile(globalsURL), let data = try? Data(contentsOf: globalsURL) else {
            issues.append(makeIssue(.missingGlobals, message: "The globals document is missing or unreadable and was preserved."))
            return ([:], true, HTTPOptions(), true)
        }
        guard case .object(let object) = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .number(let version)? = object["formatVersion"] else {
            issues.append(makeIssue(.malformedGlobals, message: "The globals document is malformed and was preserved."))
            return ([:], true, HTTPOptions(), true)
        }
        guard version == Decimal(Self.currentFormatVersion) else {
            issues.append(makeIssue(.unsupportedGlobalsVersion, message: "The globals document uses an unsupported format and was preserved."))
            return ([:], true, HTTPOptions(), true)
        }

        var values: VariableValues = [:]
        var variablesAreReadOnly = false
        guard let rawVariables = object["variables"] else {
            issues.append(makeIssue(.malformedGlobals, message: "The globals document is malformed and was preserved."))
            variablesAreReadOnly = true
            return (values, variablesAreReadOnly, HTTPOptions(), true)
        }
        do {
            values = try Self.decodeVariables(rawVariables)
        } catch {
            issues.append(makeIssue(.malformedGlobals, message: "The globals document is malformed and was preserved."))
            variablesAreReadOnly = true
        }

        let options: HTTPOptions
        var optionsAreReadOnly = variablesAreReadOnly
        if let rawOptions = object["httpOptions"] {
            do {
                options = try Self.decodeHTTPOptions(rawOptions)
            } catch {
                issues.append(makeIssue(
                    .malformedGlobals,
                    detail: "httpOptions",
                    message: "The global HTTP settings are malformed and were preserved."
                ))
                options = HTTPOptions()
                optionsAreReadOnly = true
            }
        } else {
            options = HTTPOptions()
        }

        return (values, variablesAreReadOnly, options, optionsAreReadOnly)
    }

    private func writableGlobalsObject() throws -> [String: JSONValue] {
        let unavailable = CollectionStoreError.ioFailure(operation: "save global variables because the globals document is unavailable or unsupported")
        guard Self.isRegularFile(globalsURL), let data = try? Data(contentsOf: globalsURL) else {
            throw unavailable
        }
        guard case .object(let object) = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .number(let version)? = object["formatVersion"],
              version == Decimal(Self.currentFormatVersion),
              let rawVariables = object["variables"] else {
            throw unavailable
        }
        do {
            _ = try Self.decodeVariables(rawVariables)
        } catch {
            throw unavailable
        }
        return object
    }

    private func loadCollection(id: UUID, at directory: URL, issues: inout [StorageIssue]) -> RequestCollection {
        let metadataURL = directory.appendingPathComponent("collection.json", isDirectory: false)
        guard Self.isRegularFile(metadataURL), let data = try? Data(contentsOf: metadataURL) else {
            issues.append(makeIssue(.missingCollectionMetadata, collectionID: id, message: "Collection metadata is missing or unreadable; the collection files were preserved."))
            return RequestCollection(id: id, name: "Unavailable collection", isReadOnly: true)
        }

        let raw: JSONValue
        do {
            raw = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            issues.append(makeIssue(.malformedCollectionMetadata, collectionID: id, message: "Collection metadata is malformed; the collection files were preserved."))
            return RequestCollection(id: id, name: "Unavailable collection", isReadOnly: true)
        }

        guard case .object(let object) = raw,
              case .number(let version)? = object["formatVersion"] else {
            issues.append(makeIssue(.malformedCollectionMetadata, collectionID: id, message: "Collection metadata is malformed; the collection files were preserved."))
            return RequestCollection(id: id, name: "Unavailable collection", isReadOnly: true)
        }

        let displayName: String
        if case .string(let name)? = object["name"] {
            displayName = name
        } else {
            displayName = "Unavailable collection"
        }

        guard version == Decimal(Self.currentFormatVersion) else {
            issues.append(makeIssue(.unsupportedCollectionVersion, collectionID: id, message: "This collection uses an unsupported format and is read-only."))
            return RequestCollection(id: id, name: displayName, isReadOnly: true)
        }
        guard object["id"] == nil,
              case .array(let entries)? = object["requests"], case .string? = object["name"] else {
            issues.append(makeIssue(.malformedCollectionMetadata, collectionID: id, message: "Collection metadata is malformed; the collection files were preserved."))
            return RequestCollection(id: id, name: "Unavailable collection", isReadOnly: true)
        }

        let variables: VariableValues
        var collectionIsReadOnly = false
        if let rawVariables = object["variables"] {
            do {
                variables = try Self.decodeVariables(rawVariables)
            } catch {
                issues.append(makeIssue(.malformedCollectionVariables, collectionID: id, message: "Collection variables are malformed; the collection was loaded read-only and its files were preserved."))
                variables = [:]
                collectionIsReadOnly = true
            }
        } else {
            variables = [:]
        }

        let defaults: CollectionRequestDefaults
        do {
            defaults = try Self.decodeCollectionDefaults(from: object)
        } catch {
            issues.append(makeIssue(.malformedCollectionSettings, collectionID: id, message: "Collection headers or authentication are malformed; the collection was loaded read-only and its files were preserved."))
            defaults = .init()
            collectionIsReadOnly = true
        }

        let record = CollectionRecord(object: object, name: displayName, entries: entries)
        let requestFiles: [UUID: [URL]]
        do {
            requestFiles = try requestFileURLs(in: directory)
        } catch {
            issues.append(makeIssue(.unreadableCollectionContents, collectionID: id, message: "Collection contents could not be listed; the files were preserved."))
            return RequestCollection(id: id, name: displayName, isReadOnly: true)
        }

        var indexCounts: [UUID: Int] = [:]
        for entry in record.entries {
            if let requestID = Self.uuidValue(entry) { indexCounts[requestID, default: 0] += 1 }
        }

        var loadedIDs = Set<UUID>()
        var requests: [HTTPRequestConfiguration] = []
        for (index, entry) in record.entries.enumerated() {
            guard let rawID = entry.stringValue else {
                issues.append(makeIssue(.malformedIndexEntry, collectionID: id, detail: String(index), message: "A malformed request index entry was preserved."))
                continue
            }
            guard let requestID = UUID(uuidString: rawID) else {
                issues.append(makeIssue(.invalidIndexIdentity, collectionID: id, detail: "\(index)-\(rawID)", message: "A request index entry has an invalid identity and was preserved."))
                continue
            }
            if indexCounts[requestID, default: 0] > 1 {
                issues.append(makeIssue(.duplicateIndexIdentity, collectionID: id, requestID: requestID, message: "A request appears more than once in the collection index; all index entries were preserved."))
            }
            guard loadedIDs.insert(requestID).inserted else { continue }

            let urls = requestFiles[requestID, default: []]
            guard urls.count == 1, let url = urls.first else {
                if urls.isEmpty {
                    issues.append(makeIssue(.indexedRequestMissing, collectionID: id, requestID: requestID, message: "An indexed request file is missing; its index entry was preserved."))
                } else {
                    issues.append(makeIssue(.duplicateRequestFile, collectionID: id, requestID: requestID, message: "More than one request file has this identity; all files were preserved."))
                }
                continue
            }

            switch readRequestForLoad(at: url, identity: requestID) {
            case .success(let request):
                requests.append(request)
            case .failure(.unsupported):
                issues.append(makeIssue(.unsupportedRequestVersion, collectionID: id, requestID: requestID, message: "The request uses an unsupported format and was preserved."))
            case .failure(.malformed):
                issues.append(makeIssue(.malformedRequest, collectionID: id, requestID: requestID, message: "The request is malformed and was preserved."))
            case .failure(.unreadable):
                issues.append(makeIssue(.unreadableRequest, collectionID: id, requestID: requestID, message: "The request could not be read and was preserved."))
            }
        }

        appendUnknownEntryIssues(in: directory, collectionID: id, requestFiles: requestFiles, issues: &issues)
        appendOrphanIssues(in: directory, collectionID: id, requestFiles: requestFiles, indexedIDs: Set(indexCounts.keys), issues: &issues)
        return RequestCollection(
            id: id,
            name: record.name,
            requests: requests,
            isReadOnly: collectionIsReadOnly,
            variables: variables,
            headers: defaults.headers,
            authentication: defaults.authentication
        )
    }

    private func appendUnknownEntryIssues(in directory: URL, collectionID: UUID, requestFiles: [UUID: [URL]], issues: inout [StorageIssue]) {
        let knownPaths = Set(requestFiles.values.flatMap { $0.map(\.standardizedFileURL.path) })
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return }
        for url in entries where url.lastPathComponent != "collection.json" && !knownPaths.contains(url.standardizedFileURL.path) {
            issues.append(makeIssue(.unknownCollectionData, collectionID: collectionID, detail: url.lastPathComponent, message: "Unrecognised collection data was preserved."))
        }
    }

    private func appendOrphanIssues(in directory: URL, collectionID: UUID, requestFiles: [UUID: [URL]], indexedIDs: Set<UUID>, issues: inout [StorageIssue]) {
        for requestID in requestFiles.keys.sorted(by: { $0.uuidString < $1.uuidString }) where !indexedIDs.contains(requestID) {
            let urls = requestFiles[requestID, default: []]
            guard urls.count == 1, let url = urls.first else {
                if urls.count > 1 {
                    issues.append(makeIssue(.duplicateRequestFile, collectionID: collectionID, requestID: requestID, message: "More than one unindexed request file has this identity; all files were preserved."))
                }
                continue
            }
            switch readRequestForLoad(at: url, identity: requestID) {
            case .success:
                issues.append(makeIssue(.orphanRequest, collectionID: collectionID, requestID: requestID, message: "A valid unindexed request can be added to this collection through explicit recovery.", canRecover: true))
            case .failure(.unsupported):
                issues.append(makeIssue(.unsupportedRequestVersion, collectionID: collectionID, requestID: requestID, message: "An unindexed request uses an unsupported format and was preserved."))
            case .failure(.malformed):
                issues.append(makeIssue(.malformedOrphanRequest, collectionID: collectionID, requestID: requestID, message: "An unindexed request is malformed and was preserved."))
            case .failure(.unreadable):
                issues.append(makeIssue(.unreadableOrphanRequest, collectionID: collectionID, requestID: requestID, message: "An unindexed request could not be read and was preserved."))
            }
        }
    }

    private func appendStagedDeletionIssues(to issues: inout [StorageIssue]) {
        guard Self.fileMode(at: deletionStagingURL) != nil else { return }
        guard Self.isDirectory(deletionStagingURL) else {
            issues.append(makeIssue(.unreadableDeletionStaging, message: "Staged collection data could not be listed and was preserved."))
            return
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(at: deletionStagingURL, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
            issues.append(makeIssue(.unreadableDeletionStaging, message: "Staged collection data could not be listed and was preserved."))
            return
        }
        for url in entries {
            let name = url.lastPathComponent
            let prefix = String(name.prefix(36))
            let collectionID = UUID(uuidString: prefix)
            issues.append(makeIssue(.stagedCollectionDeletion, collectionID: collectionID, detail: name, message: "A collection deletion is incomplete; staged data was preserved."))
        }
    }

    private func writableCollection(id: UUID) throws -> (URL, CollectionRecord) {
        let directories: [URL]
        do {
            directories = try collectionDirectories(matching: id)
        } catch {
            throw CollectionStoreError.ioFailure(operation: "find the collection")
        }
        guard !directories.isEmpty else { throw CollectionStoreError.collectionNotFound }
        guard directories.count == 1, let directory = directories.first else { throw CollectionStoreError.collectionIsAmbiguous }

        let metadataURL = directory.appendingPathComponent("collection.json", isDirectory: false)
        let data: Data
        guard Self.isRegularFile(metadataURL) else {
            throw CollectionStoreError.collectionIsReadOnly
        }
        do {
            data = try Data(contentsOf: metadataURL)
        } catch {
            throw CollectionStoreError.collectionIsReadOnly
        }

        do {
            let record = try CollectionRecord.decode(data)
            return (directory, record)
        } catch {
            throw CollectionStoreError.collectionIsReadOnly
        }
    }

    private func collectionDirectories(matching id: UUID) throws -> [URL] {
        let entries = try FileManager.default.contentsOfDirectory(at: collectionsURL, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        return entries.filter { Self.isDirectory($0) && UUID(uuidString: $0.lastPathComponent) == id }
    }

    private func collectionDirectoryURL(_ id: UUID) -> URL {
        collectionsURL.appendingPathComponent(Self.canonicalID(id), isDirectory: true)
    }

    private func requestFileURLs(in directory: URL) throws -> [UUID: [URL]] {
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        var result: [UUID: [URL]] = [:]
        for url in entries where url.lastPathComponent != "collection.json" && url.pathExtension.lowercased() == "json" {
            let stem = url.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: stem) else { continue }
            result[id, default: []].append(url)
        }
        for id in result.keys {
            result[id]?.sort { $0.lastPathComponent < $1.lastPathComponent }
        }
        return result
    }

    private func readRequest(at url: URL, identity: UUID) throws -> ParsedRequest {
        let data: Data
        guard Self.isRegularFile(url) else {
            throw CollectionStoreError.requestDocumentIsMalformed
        }
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CollectionStoreError.requestDocumentIsMalformed
        }
        do {
            return try ParsedRequest.decode(data, identity: identity)
        } catch RequestDocumentFailure.unsupported {
            throw CollectionStoreError.requestVersionIsUnsupported
        } catch {
            throw CollectionStoreError.requestDocumentIsMalformed
        }
    }

    private func readRequestForLoad(at url: URL, identity: UUID) -> Result<HTTPRequestConfiguration, RequestLoadFailure> {
        let data: Data
        guard Self.isRegularFile(url) else {
            return .failure(.unreadable)
        }
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .failure(.unreadable)
        }
        do {
            return .success(try ParsedRequest.decode(data, identity: identity).configuration)
        } catch RequestDocumentFailure.unsupported {
            return .failure(.unsupported)
        } catch {
            return .failure(.malformed)
        }
    }

    private func encodeRequest(_ request: HTTPRequestConfiguration) throws -> Data {
        let value = try requestJSONValue(request)
        return try encodeJSON(value)
    }

    private func requestJSONValue(_ request: HTTPRequestConfiguration) throws -> JSONValue {
        let payload = StoredRequest(configuration: request)
        let data = try JSONEncoder.postieEncoder.encode(payload)
        guard case .object(var requestObject) = try JSONDecoder().decode(JSONValue.self, from: data),
              case .object(var options)? = requestObject["options"] else {
            throw CollectionStoreError.requestDocumentIsMalformed
        }
        if request.options.overallTimeout == nil {
            options["overallTimeout"] = .null
        }
        if request.options.maximumResponseBytes == nil {
            options["maximumResponseBytes"] = .null
        }
        requestObject["options"] = .object(options)
        if let overrides = request.optionOverrides {
            requestObject["optionOverrides"] = try Self.httpOptionsOverridesJSONValue(overrides)
        }
        return .object(requestObject)
    }

    private static func decodeVariables(_ value: JSONValue) throws -> VariableValues {
        guard case .object = value else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Variable values must be a JSON object."))
        }
        let data = try JSONEncoder.postieEncoder.encode(value)
        return try JSONDecoder().decode(VariableValues.self, from: data)
    }

    private static func variableJSONValue(_ variables: VariableValues) throws -> JSONValue {
        let data = try JSONEncoder.postieEncoder.encode(variables)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func httpOptionsJSONValue(_ options: HTTPOptions) throws -> JSONValue {
        let data = try JSONEncoder.postieEncoder.encode(options)
        guard case .object(var object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw CollectionStoreError.ioFailure(operation: "encode global HTTP settings")
        }
        if options.overallTimeout == nil { object["overallTimeout"] = .null }
        if options.maximumResponseBytes == nil { object["maximumResponseBytes"] = .null }
        return .object(object)
    }

    private static func httpOptionsOverridesJSONValue(_ overrides: HTTPOptionsOverrides) throws -> JSONValue {
        let data = try JSONEncoder.postieEncoder.encode(overrides)
        guard case .object(var object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw CollectionStoreError.ioFailure(operation: "encode request HTTP settings")
        }
        if overrides.followRedirects == nil { object["followRedirects"] = .null }
        if overrides.inactivityTimeout == nil { object["inactivityTimeout"] = .null }
        if overrides.overallTimeout == nil { object["overallTimeout"] = .null }
        if overrides.maximumResponseBytes == nil { object["maximumResponseBytes"] = .null }
        return .object(object)
    }

    private static func decodeHTTPOptions(_ value: JSONValue) throws -> HTTPOptions {
        guard case .object(let object) = value,
              object["followRedirects"] != nil,
              object["inactivityTimeout"] != nil,
              object["overallTimeout"] != nil,
              object["maximumResponseBytes"] != nil else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Global HTTP settings are incomplete."))
        }
        let options = try decodeJSON(value, as: HTTPOptions.self)
        guard valid(options) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Global HTTP settings are outside their valid range."))
        }
        return options
    }

    private static func valid(_ options: HTTPOptions) -> Bool {
        options.inactivityTimeout.isFinite && options.inactivityTimeout > 0
            && (options.overallTimeout.map { $0.isFinite && $0 > 0 } ?? true)
            && (options.maximumResponseBytes.map { $0 >= 0 } ?? true)
    }

    private static func collectionDefaultsJSONValue(_ defaults: CollectionRequestDefaults) throws -> JSONValue {
        let data = try JSONEncoder.postieEncoder.encode(defaults)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func decodeCollectionDefaults(from object: [String: JSONValue]) throws -> CollectionRequestDefaults {
        let headers = try object["headers"].map { try decodeJSON($0, as: [HTTPField].self) } ?? []
        let authentication = try object["authentication"].map { try decodeJSON($0, as: RequestAuthentication.self) } ?? .init()
        return CollectionRequestDefaults(headers: headers, authentication: authentication)
    }

    private static func decodeJSON<Value: Decodable>(_ value: JSONValue, as type: Value.Type) throws -> Value {
        let data = try JSONEncoder.postieEncoder.encode(value)
        return try JSONDecoder().decode(type, from: data)
    }

    private func writeNewJSON(_ value: JSONValue, to url: URL, operation: String) throws {
        let data: Data
        do {
            data = try encodeJSON(value)
            try AtomicFileWriter.writeNew(data, to: url)
        } catch {
            throw CollectionStoreError.ioFailure(operation: operation)
        }
    }

    private func replaceJSON(_ value: JSONValue, at url: URL, operation: String) throws {
        do {
            try AtomicFileWriter.replace(encodeJSON(value), at: url)
        } catch let error as CollectionStoreError {
            throw error
        } catch {
            throw CollectionStoreError.ioFailure(operation: operation)
        }
    }

    private func encodeJSON(_ value: JSONValue) throws -> Data {
        try JSONEncoder.postieEncoder.encode(value)
    }

    private func makeIssue(
        _ kind: IssueKind,
        collectionID: UUID? = nil,
        requestID: UUID? = nil,
        detail: String? = nil,
        message: String,
        canRecover: Bool = false
    ) -> StorageIssue {
        var parts = ["store", kind.rawValue]
        if let collectionID { parts.append(Self.canonicalID(collectionID)) }
        if let requestID { parts.append(Self.canonicalID(requestID)) }
        if let detail { parts.append(detail) }
        return StorageIssue(
            id: parts.joined(separator: ":"),
            message: message,
            collectionID: collectionID,
            requestID: requestID,
            canRecover: canRecover
        )
    }

    private static func uuidValue(_ value: JSONValue) -> UUID? {
        guard let string = value.stringValue else { return nil }
        return UUID(uuidString: string)
    }

    private static func canonicalID(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    private static func requestFilename(_ id: UUID) -> String {
        "\(canonicalID(id)).json"
    }

    private static func isDirectory(_ url: URL) -> Bool {
        guard let mode = fileMode(at: url) else { return false }
        return mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        guard let mode = fileMode(at: url) else { return false }
        return mode & mode_t(S_IFMT) == mode_t(S_IFLNK)
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        guard let mode = fileMode(at: url) else { return false }
        return mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }

    private static func fileMode(at url: URL) -> mode_t? {
        var info = stat()
        let result = url.path.withCString { path in
#if canImport(Darwin)
            Darwin.lstat(path, &info)
#else
            Glibc.lstat(path, &info)
#endif
        }
        guard result == 0 else { return nil }
        return info.st_mode
    }

    private static func mergeUnknownData(_ old: JSONValue, with incoming: JSONValue) -> JSONValue {
        switch (old, incoming) {
        case (.object(let oldObject), .object(let newObject)):
            var merged = oldObject
            for (key, newValue) in newObject {
                if let oldValue = oldObject[key] {
                    merged[key] = mergeUnknownData(oldValue, with: newValue)
                } else {
                    merged[key] = newValue
                }
            }
            return .object(merged)
        case (.array(let oldArray), .array(let newArray)):
            guard newArray.allSatisfy({ objectID($0) != nil }) else { return incoming }
            var oldByID: [String: [JSONValue]] = [:]
            for value in oldArray {
                if let id = objectID(value) { oldByID[id, default: []].append(value) }
            }
            let merged = newArray.map { value -> JSONValue in
                guard let id = objectID(value), var candidates = oldByID[id], !candidates.isEmpty else { return value }
                let oldValue = candidates.removeFirst()
                oldByID[id] = candidates
                return mergeUnknownData(oldValue, with: value)
            }
            return .array(merged)
        default:
            return incoming
        }
    }

    private static func mergeRequestData(_ old: JSONValue, with incoming: JSONValue) -> JSONValue {
        guard case .object(let oldObject) = old,
              case .object(let newObject) = incoming else {
            return incoming
        }

        var merged = oldObject
        for (key, newValue) in newObject {
            switch key {
            case "variables":
                merged[key] = mergeOwnedVariables(oldObject[key] ?? .object([:]), with: newValue)
            case "authentication":
                merged[key] = mergeAuthentication(oldObject[key] ?? .object([:]), with: newValue)
            default:
                if let oldValue = oldObject[key] {
                    merged[key] = mergeUnknownData(oldValue, with: newValue)
                } else {
                    merged[key] = newValue
                }
            }
        }
        if newObject["optionOverrides"] == nil {
            merged.removeValue(forKey: "optionOverrides")
        }
        return .object(merged)
    }

    private static func mergeOwnedVariables(_ old: JSONValue, with incoming: JSONValue) -> JSONValue {
        guard case .object(let oldValues) = old,
              case .object(let newValues) = incoming else {
            return incoming
        }

        var merged: [String: JSONValue] = [:]
        for (name, newValue) in newValues {
            if let oldValue = oldValues[name] {
                merged[name] = mergeUnknownData(oldValue, with: newValue)
            } else {
                merged[name] = newValue
            }
        }
        return .object(merged)
    }

    private static func mergeAuthentication(_ old: JSONValue, with incoming: JSONValue) -> JSONValue {
        guard case .object(let oldObject) = old,
              case .object(let newObject) = incoming else {
            return incoming
        }

        let knownFields: Set<String> = ["kind", "username", "password", "token", "apiKeyHeaderName", "apiKey"]
        var merged = oldObject
        for key in knownFields {
            guard let newValue = newObject[key] else {
                merged.removeValue(forKey: key)
                continue
            }
            if (key == "password" || key == "token" || key == "apiKey"), let oldValue = oldObject[key] {
                merged[key] = mergeUnknownData(oldValue, with: newValue)
            } else {
                merged[key] = newValue
            }
        }
        for (key, newValue) in newObject where !knownFields.contains(key) {
            if let oldValue = oldObject[key] {
                merged[key] = mergeUnknownData(oldValue, with: newValue)
            } else {
                merged[key] = newValue
            }
        }
        return .object(merged)
    }

    private static func objectID(_ value: JSONValue) -> String? {
        guard case .object(let object) = value else { return nil }
        return object["id"]?.stringValue
    }

    private static func openLock(at url: URL) -> Int32 {
        url.path.withCString { path in
#if canImport(Darwin)
            Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
#else
            Glibc.open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
#endif
        }
    }

    private static func lockExclusively(_ descriptor: Int32) -> Int32 {
#if canImport(Darwin)
        var lock = Darwin.flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        return Darwin.fcntl(descriptor, F_SETLK, &lock)
#else
        var lock = Glibc.flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        return Glibc.fcntl(descriptor, F_SETLK, &lock)
#endif
    }

    private static func closeDescriptor(_ descriptor: Int32) -> Int32 {
#if canImport(Darwin)
        Darwin.close(descriptor)
#else
        Glibc.close(descriptor)
#endif
    }

    private enum IssueKind: String {
        case missingGlobals = "globals-missing"
        case malformedGlobals = "globals-malformed"
        case unsupportedGlobalsVersion = "globals-version-unsupported"
        case unexpectedCollectionEntry = "unexpected-collection-entry"
        case invalidCollectionDirectory = "invalid-collection-directory"
        case duplicateCollectionDirectory = "duplicate-collection-directory"
        case missingCollectionMetadata = "collection-metadata-missing"
        case malformedCollectionMetadata = "collection-metadata-malformed"
        case malformedCollectionVariables = "collection-variables-malformed"
        case malformedCollectionSettings = "collection-settings-malformed"
        case unsupportedCollectionVersion = "collection-version-unsupported"
        case unreadableCollectionContents = "collection-contents-unreadable"
        case malformedIndexEntry = "index-entry-malformed"
        case invalidIndexIdentity = "index-identity-invalid"
        case duplicateIndexIdentity = "index-identity-duplicate"
        case indexedRequestMissing = "indexed-request-missing"
        case duplicateRequestFile = "request-file-duplicate"
        case unsupportedRequestVersion = "request-version-unsupported"
        case malformedRequest = "request-malformed"
        case unreadableRequest = "request-unreadable"
        case unknownCollectionData = "collection-data-unknown"
        case orphanRequest = "request-orphan"
        case malformedOrphanRequest = "request-orphan-malformed"
        case unreadableOrphanRequest = "request-orphan-unreadable"
        case stagedCollectionDeletion = "collection-deletion-staged"
        case unreadableDeletionStaging = "collection-deletion-staging-unreadable"
    }

    private struct CollectionRecord {
        var object: [String: JSONValue]
        var name: String
        var entries: [JSONValue]

        init(name: String, entries: [JSONValue]) {
            self.object = [
                "formatVersion": .number(Decimal(CollectionStore.currentFormatVersion)),
                "name": .string(name),
                "variables": .object([:]),
                "requests": .array(entries)
            ]
            self.name = name
            self.entries = entries
        }

        init(object: [String: JSONValue], name: String, entries: [JSONValue]) {
            self.object = object
            self.name = name
            self.entries = entries
        }

        var jsonValue: JSONValue {
            var updated = object
            updated["formatVersion"] = .number(Decimal(CollectionStore.currentFormatVersion))
            updated["name"] = .string(name)
            updated["requests"] = .array(entries)
            return .object(updated)
        }

        static func decode(_ data: Data) throws -> CollectionRecord {
            let value: JSONValue
            do {
                value = try JSONDecoder().decode(JSONValue.self, from: data)
            } catch {
                throw DocumentFailure.malformed
            }
            guard case .object(let object) = value,
                  case .number(let version)? = object["formatVersion"] else {
                throw DocumentFailure.malformed
            }
            guard version == Decimal(CollectionStore.currentFormatVersion) else {
                throw DocumentFailure.unsupported
            }
            guard object["id"] == nil,
                  case .string(let name)? = object["name"], case .array(let entries)? = object["requests"] else {
                throw DocumentFailure.malformed
            }
            if let variables = object["variables"] {
                do {
                    _ = try CollectionStore.decodeVariables(variables)
                } catch {
                    throw DocumentFailure.malformed
                }
            }
            do {
                _ = try CollectionStore.decodeCollectionDefaults(from: object)
            } catch {
                throw DocumentFailure.malformed
            }
            return CollectionRecord(object: object, name: name, entries: entries)
        }
    }

    private struct StoredRequest: Codable {
        var formatVersion: Int
        var name: String
        var method: String
        var url: String
        var pathParameters: [HTTPField]?
        var query: [HTTPField]
        var headers: [HTTPField]
        var body: String
        var bodyEnabled: Bool
        var bodySyntax: BodySyntax
        var options: HTTPOptions
        var optionOverrides: HTTPOptionsOverrides?
        var variables: VariableValues?
        var authentication: RequestAuthentication?
        var inheritsCollectionAuthentication: Bool?

        init(configuration: HTTPRequestConfiguration) {
            self.formatVersion = CollectionStore.currentFormatVersion
            self.name = configuration.name
            self.method = configuration.method
            self.url = configuration.url
            self.pathParameters = configuration.pathParameters
            self.query = configuration.query
            self.headers = configuration.headers
            self.body = configuration.body
            self.bodyEnabled = configuration.bodyEnabled
            self.bodySyntax = configuration.bodySyntax
            self.options = configuration.options
            self.optionOverrides = configuration.optionOverrides
            self.variables = configuration.variables
            self.authentication = configuration.authentication
            self.inheritsCollectionAuthentication = configuration.inheritsCollectionAuthentication
        }

        func configuration(identity: UUID) -> HTTPRequestConfiguration {
            let normalizedQuery = QueryParameters.normalize(url: url, fields: query)
            return HTTPRequestConfiguration(
                id: identity,
                name: name,
                method: method,
                url: normalizedQuery.baseURL,
                pathParameters: pathParameters ?? [],
                query: normalizedQuery.fields,
                headers: headers,
                body: body,
                bodyEnabled: bodyEnabled,
                bodySyntax: bodySyntax,
                options: options,
                optionOverrides: optionOverrides,
                variables: variables ?? [:],
                authentication: authentication ?? RequestAuthentication(),
                inheritsCollectionAuthentication: inheritsCollectionAuthentication ?? false
            )
        }
    }

    private struct ParsedRequest {
        let jsonValue: JSONValue
        let configuration: HTTPRequestConfiguration

        static func decode(_ data: Data, identity: UUID) throws -> ParsedRequest {
            let raw: JSONValue
            do {
                raw = try JSONDecoder().decode(JSONValue.self, from: data)
            } catch {
                throw RequestDocumentFailure.malformed
            }
            guard case .object(let object) = raw,
                  case .number(let version)? = object["formatVersion"] else {
                throw RequestDocumentFailure.malformed
            }
            guard version == Decimal(CollectionStore.currentFormatVersion) else {
                throw RequestDocumentFailure.unsupported
            }
            guard object["id"] == nil else {
                throw RequestDocumentFailure.malformed
            }
            let stored: StoredRequest
            do {
                stored = try JSONDecoder().decode(StoredRequest.self, from: data)
            } catch {
                throw RequestDocumentFailure.malformed
            }
            guard stored.formatVersion == CollectionStore.currentFormatVersion else {
                throw RequestDocumentFailure.unsupported
            }
            return ParsedRequest(jsonValue: raw, configuration: stored.configuration(identity: identity))
        }
    }

    private enum RequestDocumentFailure: Error {
        case malformed
        case unsupported
    }

    private enum DocumentFailure: Error {
        case malformed
        case unsupported
    }

    private enum RequestLoadFailure: Error {
        case malformed
        case unsupported
        case unreadable
    }
}

private indirect enum JSONValue: Codable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Decimal)
    case bool(Bool)
    case null

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: JSONCodingKey.self) {
            var object: [String: JSONValue] = [:]
            for key in container.allKeys {
                object[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
            }
            self = .object(object)
            return
        }

        if var container = try? decoder.unkeyedContainer() {
            var values: [JSONValue] = []
            while !container.isAtEnd {
                values.append(try container.decode(JSONValue.self))
            }
            self = .array(values)
            return
        }

        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Decimal.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .object(let object):
            var container = encoder.container(keyedBy: JSONCodingKey.self)
            for key in object.keys.sorted() {
                guard let value = object[key] else { continue }
                try container.encode(value, forKey: JSONCodingKey(key))
            }
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values { try container.encode(value) }
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .number(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .bool(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
}

private struct JSONCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        return nil
    }
}

private extension JSONEncoder {
    static var postieEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private enum AtomicFileWriter {
    static func writeNew(_ data: Data, to destination: URL) throws {
        try write(data, to: destination, replacing: false)
    }

    static func replace(_ data: Data, at destination: URL) throws {
        try write(data, to: destination, replacing: true)
    }

    private static func write(_ data: Data, to destination: URL, replacing: Bool) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString.lowercased())")
        let descriptor = openPath(temporary.path, flags: O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, mode: S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw FileWriteFailure(operation: "create temporary file") }
        var isOpen = true
        defer {
            if isOpen { _ = closeDescriptor(descriptor) }
            _ = unlinkPath(temporary.path)
        }

        var writeFailed = false
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = writeDescriptor(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                if count < 0 && currentErrno == EINTR { continue }
                if count <= 0 {
                    writeFailed = true
                    break
                }
                offset += count
            }
        }
        guard !writeFailed, syncDescriptor(descriptor) == 0 else {
            throw FileWriteFailure(operation: "write temporary file")
        }
        guard closeDescriptor(descriptor) == 0 else {
            isOpen = false
            throw FileWriteFailure(operation: "close temporary file")
        }
        isOpen = false

        let result = replacing
            ? renamePath(temporary.path, destination.path)
            : linkPath(temporary.path, destination.path)
        guard result == 0 else {
            throw FileWriteFailure(operation: replacing ? "replace file" : "create file")
        }
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

    private static func renamePath(_ source: String, _ destination: String) -> Int32 {
        source.withCString { sourcePath in
            destination.withCString { destinationPath in
#if canImport(Darwin)
                Darwin.rename(sourcePath, destinationPath)
#else
                Glibc.rename(sourcePath, destinationPath)
#endif
            }
        }
    }

    private static func linkPath(_ source: String, _ destination: String) -> Int32 {
        source.withCString { sourcePath in
            destination.withCString { destinationPath in
#if canImport(Darwin)
                Darwin.link(sourcePath, destinationPath)
#else
                Glibc.link(sourcePath, destinationPath)
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

private struct FileWriteFailure: Error {
    let operation: String
}

private final class ProcessLockRegistry: @unchecked Sendable {
    static let shared = ProcessLockRegistry()

    private let mutex = NSLock()
    private var paths: Set<String> = []

    func claim(_ path: String) -> Bool {
        mutex.lock()
        defer { mutex.unlock() }
        return paths.insert(path).inserted
    }

    func release(_ path: String) {
        mutex.lock()
        defer { mutex.unlock() }
        paths.remove(path)
    }
}
