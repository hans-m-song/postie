import Foundation
import Darwin

private enum HTTPExecutionError: LocalizedError {
    case alreadyRunning
    case shutDown
    case bodyStorageUnavailable
    case bodyNotOwned
    case bodyUnavailable
    case redirectUnavailable

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "This request is already running."
        case .shutDown:
            return "The HTTP execution manager has shut down."
        case .bodyStorageUnavailable:
            return "Response storage is unavailable. Check the selected folder and available storage."
        case .bodyNotOwned:
            return "The selected file is not a retained response body."
        case .bodyUnavailable:
            return "The retained response body is no longer available."
        case .redirectUnavailable:
            return "This response does not have a followable redirect."
        }
    }
}

private enum RunCancellation: Sendable {
    case user
    case shutdown
}

private func reconciledHeaderSources(
    for request: URLRequest,
    inheriting sources: [String: HTTPHeaderSource],
    defaultSource: HTTPHeaderSource
) -> [String: HTTPHeaderSource] {
    let normalizedSources = sources.reduce(into: [String: HTTPHeaderSource]()) { result, entry in
        result[entry.key.lowercased()] = entry.value
    }
    return (request.allHTTPHeaderFields ?? [:]).keys.reduce(into: [:]) { result, name in
        let normalizedName = name.lowercased()
        result[normalizedName] = normalizedSources[normalizedName] ?? defaultSource
    }
}

private struct HTTPResponseMetadata: Sendable {
    let finalURL: URL
    let effectiveMethod: String
    let statusCode: Int
    let requestHeaders: [HTTPField]
    let requestHeaderSources: [String: HTTPHeaderSource]
    let responseHeaders: [HTTPField]
    let redirects: [HTTPRedirect]
    let bodyFileURL: URL
    let bodyByteCount: Int64
    let duration: TimeInterval
    let redirectLimitReached: Bool
    let redirectRequest: URLRequest?
    let pendingRedirect: HTTPRedirect?
}

private enum HTTPDownloadOutcome: Sendable {
    case completed(HTTPResponseMetadata)
    case failed(String, bodyFileURL: URL?)
    case cancelled(bodyFileURL: URL?)
}

private struct ActiveHTTPRun {
    let identity: RequestIdentity
    let configuration: HTTPRequestConfiguration
    let preparedRequest: URLRequest
    let requestHeaderSources: [String: HTTPHeaderSource]
    let sensitiveRequestHeaderNames: Set<String>
    let secretRequestHeaderNames: Set<String>
    let redirects: [HTTPRedirect]
    let followedRedirectCount: Int
    let continuation: AsyncStream<HTTPExecutionEvent>.Continuation
    let startedAt: Date
    var cancellation: RunCancellation?
    var session: URLSession?
    var task: URLSessionDownloadTask?
    var delegate: HTTPDownloadDelegate?
}

private struct RetainedHTTPResponse {
    let identity: RequestIdentity
    let bodyURL: URL
    let requestHeaderSources: [String: HTTPHeaderSource]
    let sensitiveRequestHeaderNames: Set<String>
    let secretRequestHeaderNames: Set<String>
}

private enum HTTPStorageLockError: Error {
    case alreadyLocked
    case unavailable
}

private final class HTTPStorageFileLock {
    private var fileHandle: FileHandle?

    init(at url: URL, createIfMissing: Bool, nonblocking: Bool) throws {
        var flags = O_RDWR | O_CLOEXEC | O_NOFOLLOW
        if createIfMissing {
            flags |= O_CREAT
        }

        let descriptor = url.path.withCString { open($0, flags, mode_t(0o600)) }
        guard descriptor >= 0 else {
            throw HTTPStorageLockError.unavailable
        }

        var lockOperation = LOCK_EX
        if nonblocking {
            lockOperation |= LOCK_NB
        }

        while flock(descriptor, lockOperation) != 0 {
            let lockError = errno
            if !nonblocking, lockError == EINTR {
                continue
            }

            _ = close(descriptor)
            if nonblocking, lockError == EWOULDBLOCK || lockError == EAGAIN {
                throw HTTPStorageLockError.alreadyLocked
            }
            throw HTTPStorageLockError.unavailable
        }

        fileHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func write(_ data: Data) throws {
        guard let fileHandle else {
            throw HTTPStorageLockError.unavailable
        }
        try fileHandle.write(contentsOf: data)
    }

    func readContents() throws -> Data {
        guard let fileHandle else {
            throw HTTPStorageLockError.unavailable
        }
        try fileHandle.seek(toOffset: 0)
        return try fileHandle.readToEnd() ?? Data()
    }

    func release() {
        guard let fileHandle else {
            return
        }

        _ = flock(fileHandle.fileDescriptor, LOCK_UN)
        try? fileHandle.close()
        self.fileHandle = nil
    }

    deinit {
        release()
    }
}

private final class HTTPBodyStore {
    private static let sessionDirectoryPrefix = ".postie-http-session-"
    private static let cleanupLockName = ".postie-http-cleanup.lock"
    private static let ownerLockName = ".owner.lock"
    private static let ownerMarker = Data("Postie HTTP response body store v1\n".utf8)

    let sessionDirectory: URL
    private var ownerLock: HTTPStorageFileLock?

    init(baseDirectory: URL) throws {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        } catch {
            throw HTTPExecutionError.bodyStorageUnavailable
        }

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: baseDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw HTTPExecutionError.bodyStorageUnavailable
        }

        let resolvedBaseDirectory = baseDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let cleanupLock: HTTPStorageFileLock
        do {
            cleanupLock = try HTTPStorageFileLock(
                at: resolvedBaseDirectory.appendingPathComponent(Self.cleanupLockName),
                createIfMissing: true,
                nonblocking: false
            )
        } catch {
            throw HTTPExecutionError.bodyStorageUnavailable
        }
        defer { cleanupLock.release() }

        Self.removeStaleSessionDirectories(in: resolvedBaseDirectory)

        let newSessionDirectory = resolvedBaseDirectory.appendingPathComponent(
            Self.sessionDirectoryPrefix + UUID().uuidString,
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: newSessionDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let newOwnerLock = try HTTPStorageFileLock(
                at: newSessionDirectory.appendingPathComponent(Self.ownerLockName),
                createIfMissing: true,
                nonblocking: false
            )
            try newOwnerLock.write(Self.ownerMarker)

            self.sessionDirectory = newSessionDirectory
            self.ownerLock = newOwnerLock
        } catch {
            try? fileManager.removeItem(at: newSessionDirectory)
            throw HTTPExecutionError.bodyStorageUnavailable
        }
    }

    func removeSessionDirectory() {
        guard ownerLock != nil else {
            return
        }

        try? FileManager.default.removeItem(at: sessionDirectory)
        ownerLock?.release()
        ownerLock = nil
    }

    private static func removeStaleSessionDirectories(in baseDirectory: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else {
            return
        }

        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(sessionDirectoryPrefix),
                  UUID(uuidString: String(name.dropFirst(sessionDirectoryPrefix.count))) != nil,
                  let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else {
                continue
            }

            let ownerLockURL = entry.appendingPathComponent(ownerLockName)
            guard let ownerLock = try? HTTPStorageFileLock(
                at: ownerLockURL,
                createIfMissing: false,
                nonblocking: true
            ) else {
                continue
            }

            if let marker = try? ownerLock.readContents(), marker == ownerMarker {
                try? FileManager.default.removeItem(at: entry)
            }
            ownerLock.release()
        }
    }

    deinit {
        ownerLock?.release()
    }
}

public actor HTTPExecutionManager {
    private let bodyStore: HTTPBodyStore
    private var bodyDirectory: URL { bodyStore.sessionDirectory }
    private var activeRuns: [UUID: ActiveHTTPRun] = [:]
    private var runByIdentity: [RequestIdentity: UUID] = [:]
    private var retainedBodies: Set<URL> = []
    private var retainedResponses: [UUID: RetainedHTTPResponse] = [:]
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var isShutDown = false
    private var shutdownCompleted = false

    public init(bodyDirectory: URL) throws {
        self.bodyStore = try HTTPBodyStore(baseDirectory: bodyDirectory)
    }

    public func start(identity: RequestIdentity, configuration: HTTPRequestConfiguration) throws -> HTTPRun {
        guard !isShutDown else {
            throw HTTPExecutionError.shutDown
        }

        guard runByIdentity[identity] == nil else {
            throw HTTPExecutionError.alreadyRunning
        }

        let preparedRequest = try RequestPreparer.prepare(configuration)
        return try launch(
            identity: identity,
            configuration: configuration,
            preparedRequest: preparedRequest,
            requestHeaderSources: [:],
            sensitiveRequestHeaderNames: RequestPreparer.standardSensitiveRequestHeaderNames,
            secretRequestHeaderNames: [],
            redirects: [],
            followedRedirectCount: 0
        )
    }

    public func start(identity: RequestIdentity, prepared: PreparedHTTPRequest) throws -> HTTPRun {
        try Task.checkCancellation()
        guard !isShutDown else {
            throw HTTPExecutionError.shutDown
        }

        guard runByIdentity[identity] == nil else {
            throw HTTPExecutionError.alreadyRunning
        }

        return try launch(
            identity: identity,
            configuration: prepared.configuration,
            preparedRequest: prepared.request,
            requestHeaderSources: prepared.requestHeaderSources,
            sensitiveRequestHeaderNames: prepared.sensitiveRequestHeaderNames,
            secretRequestHeaderNames: prepared.secretRequestHeaderNames,
            redirects: [],
            followedRedirectCount: 0
        )
    }

    public func followRedirect(identity: RequestIdentity, response: HTTPResponseRecord) throws -> HTTPRun {
        try Task.checkCancellation()
        guard !isShutDown else {
            throw HTTPExecutionError.shutDown
        }

        let bodyURL = response.bodyFileURL.standardizedFileURL.resolvingSymlinksInPath()
        guard let retainedResponse = retainedResponses[response.runID],
              retainedResponse.identity == identity,
              retainedResponse.bodyURL == bodyURL,
              retainedBodies.contains(bodyURL),
              !response.redirectLimitReached,
              response.redirects.count <= 10,
              let pendingRedirect = response.pendingRedirect,
              response.statusCode == pendingRedirect.statusCode,
              [301, 302, 303, 307, 308].contains(pendingRedirect.statusCode),
              let redirectRequest = response.redirectRequest,
              let redirectURL = redirectRequest.url,
              redirectURL.scheme.map({ ["http", "https"].contains($0.lowercased()) }) == true,
              redirectURL == pendingRedirect.nextURL,
              response.finalURL == pendingRedirect.url,
              redirectRequest.httpMethod?.uppercased() == pendingRedirect.nextMethod.uppercased(),
              response.redirects.last?.id == pendingRedirect.id else {
            throw HTTPExecutionError.redirectUnavailable
        }

        var capturedRequest = redirectRequest
        if !sameOrigin(response.finalURL, redirectURL) {
            Self.stripCrossOriginCredentials(
                from: &capturedRequest,
                additionalNames: retainedResponse.sensitiveRequestHeaderNames.union(retainedResponse.secretRequestHeaderNames)
            )
        }
        let requestHeaderSources = reconciledHeaderSources(
            for: capturedRequest,
            inheriting: retainedResponse.requestHeaderSources,
            defaultSource: .automatic
        )

        return try launch(
            identity: identity,
            configuration: response.request,
            preparedRequest: capturedRequest,
            requestHeaderSources: requestHeaderSources,
            sensitiveRequestHeaderNames: retainedResponse.sensitiveRequestHeaderNames,
            secretRequestHeaderNames: retainedResponse.secretRequestHeaderNames,
            redirects: response.redirects,
            followedRedirectCount: response.redirects.count
        )
    }

    private func launch(
        identity: RequestIdentity,
        configuration: HTTPRequestConfiguration,
        preparedRequest: URLRequest,
        requestHeaderSources: [String: HTTPHeaderSource],
        sensitiveRequestHeaderNames: Set<String>,
        secretRequestHeaderNames: Set<String>,
        redirects: [HTTPRedirect],
        followedRedirectCount: Int
    ) throws -> HTTPRun {
        guard !isShutDown else {
            throw HTTPExecutionError.shutDown
        }

        guard runByIdentity[identity] == nil else {
            throw HTTPExecutionError.alreadyRunning
        }

        let runID = UUID()
        let (events, continuation) = AsyncStream.makeStream(
            of: HTTPExecutionEvent.self,
            bufferingPolicy: .bufferingNewest(128)
        )

        activeRuns[runID] = ActiveHTTPRun(
            identity: identity,
            configuration: configuration,
            preparedRequest: preparedRequest,
            requestHeaderSources: reconciledHeaderSources(
                for: preparedRequest,
                inheriting: requestHeaderSources,
                defaultSource: .request
            ),
            sensitiveRequestHeaderNames: sensitiveRequestHeaderNames,
            secretRequestHeaderNames: secretRequestHeaderNames,
            redirects: redirects,
            followedRedirectCount: followedRedirectCount,
            continuation: continuation,
            startedAt: Date(),
            cancellation: nil,
            session: nil,
            task: nil,
            delegate: nil
        )
        runByIdentity[identity] = runID

        Task { [weak self] in
            await self?.begin(runID: runID)
        }

        return HTTPRun(id: runID, events: events)
    }

    private func sameOrigin(_ firstURL: URL, _ secondURL: URL) -> Bool {
        guard let first = origin(of: firstURL), let second = origin(of: secondURL) else {
            return false
        }

        return first.scheme == second.scheme && first.host == second.host && first.port == second.port
    }

    private func origin(of url: URL) -> (scheme: String, host: String, port: Int)? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else {
            return nil
        }

        let defaultPort = scheme == "https" ? 443 : 80
        return (scheme, host, components.port ?? defaultPort)
    }

    private static func stripCrossOriginCredentials(from request: inout URLRequest, additionalNames: Set<String>) {
        for header in Set(["Authorization", "Proxy-Authorization", "Cookie", "Cookie2"]).union(additionalNames) {
            request.setValue(nil, forHTTPHeaderField: header)
        }
    }

    public func cancel(identity: RequestIdentity, runID expectedRunID: UUID? = nil) {
        guard let runID = runByIdentity[identity],
              expectedRunID == nil || expectedRunID == runID,
              var activeRun = activeRuns[runID] else {
            return
        }

        activeRun.cancellation = .user
        activeRuns[runID] = activeRun

        guard let task = activeRun.task else {
            finish(runID: runID, outcome: .cancelled(bodyFileURL: nil))
            return
        }

        task.cancel()
    }

    public func discardBody(at url: URL) throws {
        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedURL.deletingLastPathComponent() == bodyDirectory,
              retainedBodies.contains(resolvedURL) else {
            throw HTTPExecutionError.bodyNotOwned
        }

        guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
            retainedBodies.remove(resolvedURL)
            throw HTTPExecutionError.bodyUnavailable
        }

        do {
            try FileManager.default.removeItem(at: resolvedURL)
            retainedBodies.remove(resolvedURL)
            retainedResponses = retainedResponses.filter { $0.value.bodyURL != resolvedURL }
        } catch {
            throw HTTPExecutionError.bodyStorageUnavailable
        }
    }

    public func shutdown() async {
        guard !shutdownCompleted else {
            return
        }

        if !isShutDown {
            isShutDown = true
            for runID in Array(activeRuns.keys) {
                guard var activeRun = activeRuns[runID] else {
                    continue
                }

                activeRun.cancellation = .shutdown
                activeRuns[runID] = activeRun

                guard let task = activeRun.task else {
                    finish(runID: runID, outcome: .cancelled(bodyFileURL: nil))
                    continue
                }

                task.cancel()
                activeRun.session?.invalidateAndCancel()
            }
        }

        completeShutdownIfPossible()
        guard !shutdownCompleted else {
            return
        }

        await withCheckedContinuation { continuation in
            if shutdownCompleted {
                continuation.resume()
            } else {
                shutdownWaiters.append(continuation)
            }
        }
    }

    private func begin(runID: UUID) {
        guard let activeRun = activeRuns[runID] else {
            return
        }

        guard !isShutDown else {
            finish(runID: runID, outcome: .cancelled(bodyFileURL: nil))
            return
        }

        let onCompletion: @Sendable (UUID, HTTPDownloadOutcome) -> Void = { [weak self] runID, outcome in
            Task {
                await self?.complete(runID: runID, outcome: outcome)
            }
        }

        let delegate = HTTPDownloadDelegate(
            runID: runID,
            request: activeRun.configuration,
            preparedRequest: activeRun.preparedRequest,
            requestHeaderSources: activeRun.requestHeaderSources,
            sensitiveRequestHeaderNames: activeRun.sensitiveRequestHeaderNames,
            secretRequestHeaderNames: activeRun.secretRequestHeaderNames,
            redirects: activeRun.redirects,
            followedRedirectCount: activeRun.followedRedirectCount,
            bodyDirectory: bodyDirectory,
            startedAt: activeRun.startedAt,
            continuation: activeRun.continuation,
            onCompletion: onCompletion
        )

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.httpCookieAcceptPolicy = .never
        sessionConfiguration.urlCache = nil
        sessionConfiguration.urlCredentialStorage = nil
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.timeoutIntervalForRequest = activeRun.configuration.options.inactivityTimeout
        sessionConfiguration.timeoutIntervalForResource = activeRun.configuration.options.overallTimeout ?? 604_800
        sessionConfiguration.waitsForConnectivity = false

        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.name = "Postie.HTTP.\(runID.uuidString)"

        let session = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: delegateQueue)
        let task = session.downloadTask(with: activeRun.preparedRequest)

        var updatedRun = activeRun
        updatedRun.session = session
        updatedRun.task = task
        updatedRun.delegate = delegate
        activeRuns[runID] = updatedRun
        task.resume()
    }

    private func complete(runID: UUID, outcome: HTTPDownloadOutcome) {
        guard let activeRun = activeRuns[runID] else {
            cleanupBody(for: outcome)
            return
        }

        if let cancellation = activeRun.cancellation {
            switch cancellation {
            case .user, .shutdown:
                finish(runID: runID, outcome: .cancelled(bodyFileURL: bodyURL(for: outcome)))
            }
            return
        }

        finish(runID: runID, outcome: outcome)
    }

    private func finish(runID: UUID, outcome: HTTPDownloadOutcome) {
        guard let activeRun = activeRuns.removeValue(forKey: runID) else {
            cleanupBody(for: outcome)
            return
        }

        if runByIdentity[activeRun.identity] == runID {
            runByIdentity.removeValue(forKey: activeRun.identity)
        }

        switch outcome {
        case .completed(let metadata):
            let bodyURL = metadata.bodyFileURL.standardizedFileURL.resolvingSymlinksInPath()
            retainedBodies.insert(bodyURL)
            retainedResponses[runID] = RetainedHTTPResponse(
                identity: activeRun.identity,
                bodyURL: bodyURL,
                requestHeaderSources: metadata.requestHeaderSources,
                sensitiveRequestHeaderNames: activeRun.sensitiveRequestHeaderNames,
                secretRequestHeaderNames: activeRun.secretRequestHeaderNames
            )
            activeRun.continuation.yield(.completed(HTTPResponseRecord(
                runID: runID,
                request: activeRun.configuration,
                finalURL: metadata.finalURL,
                statusCode: metadata.statusCode,
                requestHeaders: metadata.requestHeaders,
                responseHeaders: metadata.responseHeaders,
                redirects: metadata.redirects,
                bodyFileURL: metadata.bodyFileURL,
                bodyByteCount: metadata.bodyByteCount,
                duration: metadata.duration,
                redirectLimitReached: metadata.redirectLimitReached,
                effectiveMethod: metadata.effectiveMethod,
                redirectRequest: metadata.redirectRequest,
                pendingRedirect: metadata.pendingRedirect,
                sensitiveRequestHeaderNames: activeRun.sensitiveRequestHeaderNames,
                secretRequestHeaderNames: activeRun.secretRequestHeaderNames,
                requestHeaderSources: metadata.requestHeaderSources
            )))
        case .failed(let message, let bodyFileURL):
            if let bodyFileURL {
                try? FileManager.default.removeItem(at: bodyFileURL)
            }
            activeRun.continuation.yield(.failed(message))
        case .cancelled(let bodyFileURL):
            if let bodyFileURL {
                try? FileManager.default.removeItem(at: bodyFileURL)
            }
            activeRun.continuation.yield(.cancelled)
        }

        activeRun.continuation.finish()
        activeRun.session?.finishTasksAndInvalidate()

        completeShutdownIfPossible()
    }

    private func removeOwnedBodyStore() {
        retainedBodies.removeAll()
        bodyStore.removeSessionDirectory()
    }

    private func completeShutdownIfPossible() {
        guard isShutDown, !shutdownCompleted, activeRuns.isEmpty else {
            return
        }

        removeOwnedBodyStore()
        shutdownCompleted = true
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func cleanupBody(for outcome: HTTPDownloadOutcome) {
        if case .completed(let metadata) = outcome {
            try? FileManager.default.removeItem(at: metadata.bodyFileURL)
        } else if case .failed(_, let bodyFileURL) = outcome, let bodyFileURL {
            try? FileManager.default.removeItem(at: bodyFileURL)
        } else if case .cancelled(let bodyFileURL) = outcome, let bodyFileURL {
            try? FileManager.default.removeItem(at: bodyFileURL)
        }
    }

    private func bodyURL(for outcome: HTTPDownloadOutcome) -> URL? {
        switch outcome {
        case .completed(let metadata):
            return metadata.bodyFileURL
        case .failed(_, let bodyFileURL), .cancelled(let bodyFileURL):
            return bodyFileURL
        }
    }
}

// URLSession invokes each run's mutable delegate state on a serial operation queue.
private final class HTTPDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let runID: UUID
    private let request: HTTPRequestConfiguration
    private let bodyDirectory: URL
    private let startedAt: Date
    private let continuation: AsyncStream<HTTPExecutionEvent>.Continuation
    private let onCompletion: @Sendable (UUID, HTTPDownloadOutcome) -> Void
    private let maximumResponseBytes: Int64?
    private let sensitiveRequestHeaderNames: Set<String>
    private let secretRequestHeaderNames: Set<String>
    private var currentRequest: URLRequest
    private var currentRequestHeaderSources: [String: HTTPHeaderSource]
    private var redirects: [HTTPRedirect]
    private var followedRedirectCount: Int
    private var redirectLimitReached = false
    private var redirectRequest: URLRequest?
    private var pendingRedirect: HTTPRedirect?
    private var bodyFileURL: URL?
    private var responseMetadata: HTTPResponseMetadata?
    private var failureMessage: String?
    private var bodyLimitExceeded = false

    init(
        runID: UUID,
        request: HTTPRequestConfiguration,
        preparedRequest: URLRequest,
        requestHeaderSources: [String: HTTPHeaderSource],
        sensitiveRequestHeaderNames: Set<String>,
        secretRequestHeaderNames: Set<String>,
        redirects: [HTTPRedirect],
        followedRedirectCount: Int,
        bodyDirectory: URL,
        startedAt: Date,
        continuation: AsyncStream<HTTPExecutionEvent>.Continuation,
        onCompletion: @escaping @Sendable (UUID, HTTPDownloadOutcome) -> Void
    ) {
        self.runID = runID
        self.request = request
        self.currentRequest = preparedRequest
        self.currentRequestHeaderSources = reconciledHeaderSources(
            for: preparedRequest,
            inheriting: requestHeaderSources,
            defaultSource: .request
        )
        self.sensitiveRequestHeaderNames = sensitiveRequestHeaderNames
        self.secretRequestHeaderNames = secretRequestHeaderNames
        self.redirects = redirects
        self.followedRedirectCount = followedRedirectCount
        self.bodyDirectory = bodyDirectory
        self.startedAt = startedAt
        self.continuation = continuation
        self.onCompletion = onCompletion
        self.maximumResponseBytes = request.options.maximumResponseBytes
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let currentRequest = task.currentRequest {
            self.currentRequest = currentRequest
        }
        currentRequestHeaderSources = reconciledHeaderSources(
            for: currentRequest,
            inheriting: currentRequestHeaderSources,
            defaultSource: .automatic
        )

        guard let nextURL = newRequest.url else {
            completionHandler(nil)
            return
        }

        let previousURL = currentRequest.url ?? response.url ?? nextURL
        var redirectedRequest = newRequest
        if redirectedRequest.httpMethod == nil {
            redirectedRequest.httpMethod = "GET"
        }
        if redirectedRequest.httpMethod?.caseInsensitiveCompare(currentRequest.httpMethod ?? "GET") == .orderedSame,
           redirectedRequest.httpBody == nil {
            redirectedRequest.httpBody = currentRequest.httpBody
        }

        if !sameOrigin(previousURL, nextURL) {
            let credentialNames = Set(["Authorization", "Proxy-Authorization", "Cookie", "Cookie2"])
                .union(sensitiveRequestHeaderNames)
                .union(secretRequestHeaderNames)
            for name in credentialNames {
                redirectedRequest.setValue(nil, forHTTPHeaderField: name)
            }
        }
        let redirectedHeaderSources = reconciledHeaderSources(
            for: redirectedRequest,
            inheriting: currentRequestHeaderSources,
            defaultSource: .automatic
        )

        let redirect = HTTPRedirect(
            statusCode: response.statusCode,
            url: previousURL,
            nextURL: nextURL,
            method: currentRequest.httpMethod ?? "GET",
            nextMethod: redirectedRequest.httpMethod ?? "GET",
            requestHeaders: requestHeaders(from: currentRequest),
            responseHeaders: responseHeaders(from: response),
            sensitiveRequestHeaderNames: sensitiveRequestHeaderNames,
            secretRequestHeaderNames: secretRequestHeaderNames,
            requestHeaderSources: currentRequestHeaderSources
        )
        redirects.append(redirect)
        continuation.yield(.redirect(redirect))

        guard [301, 302, 303, 307, 308].contains(response.statusCode),
              ["http", "https"].contains(nextURL.scheme?.lowercased() ?? "") else {
            redirectRequest = nil
            pendingRedirect = nil
            completionHandler(nil)
            return
        }

        guard followedRedirectCount < 10 else {
            redirectLimitReached = true
            redirectRequest = redirectedRequest
            pendingRedirect = redirect
            completionHandler(nil)
            return
        }

        guard request.options.followRedirects else {
            redirectRequest = redirectedRequest
            pendingRedirect = redirect
            completionHandler(nil)
            return
        }

        currentRequest = redirectedRequest
        currentRequestHeaderSources = redirectedHeaderSources
        followedRedirectCount += 1
        redirectRequest = nil
        pendingRedirect = nil
        completionHandler(redirectedRequest)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let expectedBytes = totalBytesExpectedToWrite >= 0 ? totalBytesExpectedToWrite : nil
        continuation.yield(.progress(HTTPProgress(receivedBytes: totalBytesWritten, expectedBytes: expectedBytes)))

        if let maximumResponseBytes, totalBytesWritten > maximumResponseBytes {
            bodyLimitExceeded = true
            failureMessage = "The response exceeded the configured byte limit."
            downloadTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard !bodyLimitExceeded else {
            failureMessage = "The response exceeded the configured byte limit."
            return
        }

        guard let response = downloadTask.response as? HTTPURLResponse else {
            failureMessage = "The server returned an invalid HTTP response."
            return
        }

        if let currentRequest = downloadTask.currentRequest {
            self.currentRequest = currentRequest
        }
        currentRequestHeaderSources = reconciledHeaderSources(
            for: currentRequest,
            inheriting: currentRequestHeaderSources,
            defaultSource: .automatic
        )

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
            let bodyByteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            if let maximumResponseBytes, bodyByteCount > maximumResponseBytes {
                failureMessage = "The response exceeded the configured byte limit."
                return
            }

            let destination = bodyDirectory.appendingPathComponent("response-\(runID.uuidString).body")
            try FileManager.default.moveItem(at: location, to: destination)
            bodyFileURL = destination

            responseMetadata = HTTPResponseMetadata(
                finalURL: response.url ?? currentRequest.url ?? destination,
                effectiveMethod: currentRequest.httpMethod ?? request.method,
                statusCode: response.statusCode,
                requestHeaders: requestHeaders(from: currentRequest),
                requestHeaderSources: currentRequestHeaderSources,
                responseHeaders: responseHeaders(from: response),
                redirects: redirects,
                bodyFileURL: destination,
                bodyByteCount: bodyByteCount,
                duration: max(0, Date().timeIntervalSince(startedAt)),
                redirectLimitReached: redirectLimitReached,
                redirectRequest: redirectRequest,
                pendingRedirect: pendingRedirect
            )
        } catch {
            failureMessage = "The response body could not be saved. Check available storage and folder permissions."
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if bodyLimitExceeded {
            onCompletion(runID, .failed("The response exceeded the configured byte limit.", bodyFileURL: bodyFileURL))
            return
        }

        if let failureMessage {
            onCompletion(runID, .failed(failureMessage, bodyFileURL: bodyFileURL))
            return
        }

        if let error {
            if (error as NSError).code == NSURLErrorCancelled {
                onCompletion(runID, .cancelled(bodyFileURL: bodyFileURL))
            } else {
                onCompletion(runID, .failed(safeNetworkError(error), bodyFileURL: bodyFileURL))
            }
            return
        }

        guard let responseMetadata else {
            onCompletion(runID, .failed("The response body could not be saved.", bodyFileURL: bodyFileURL))
            return
        }

        onCompletion(runID, .completed(responseMetadata))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(.performDefaultHandling, nil)
    }

    private func requestHeaders(from request: URLRequest) -> [HTTPField] {
        let fields = request.allHTTPHeaderFields ?? [:]
        return fields.map { HTTPField(name: $0.key, value: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func responseHeaders(from response: HTTPURLResponse) -> [HTTPField] {
        response.allHeaderFields.map { key, value in
            HTTPField(name: String(describing: key), value: String(describing: value))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func sameOrigin(_ firstURL: URL, _ secondURL: URL) -> Bool {
        guard let first = origin(of: firstURL), let second = origin(of: secondURL) else {
            return false
        }

        return first.scheme == second.scheme && first.host == second.host && first.port == second.port
    }

    private func origin(of url: URL) -> (scheme: String, host: String, port: Int)? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else {
            return nil
        }

        let defaultPort = scheme == "https" ? 443 : 80
        return (scheme, host, components.port ?? defaultPort)
    }

    private func safeNetworkError(_ error: Error) -> String {
        let code = (error as NSError).code
        switch code {
        case NSURLErrorTimedOut:
            return "The request timed out."
        case NSURLErrorNotConnectedToInternet:
            return "No network connection is available."
        case NSURLErrorCancelled:
            return "The request was cancelled."
        default:
            return "The request could not be completed. Check the URL and try again."
        }
    }
}
