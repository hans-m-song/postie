import Combine
import Foundation
import PostieCore

@MainActor
final class SessionExecutionStore: ObservableObject {
    enum Phase: Equatable {
        case preparing, running, cancelling, completed, failed, cancelled

        var isActive: Bool {
            self == .preparing || self == .running || self == .cancelling
        }
    }

    struct Entry: Identifiable {
        var id: UUID { token }
        let token: UUID
        let source: SnapshotSource?
        var liveSourceIdentity: RequestIdentity?
        let method: String
        let requestName: String
        let url: String
        let startedAt: Date
        var finishedAt: Date?
        var phase: Phase
        var request: HTTPRequestConfiguration?
        var capture: SnapshotPreparationCapture?
        var progress: HTTPProgress?
        var redirects: [HTTPRedirect]
        var response: HTTPResponseRecord?
        var statusCode: Int?
        var bodyByteCount: Int64?
        var errorMessage: String?
        var detailsUnavailableReason: String?
        fileprivate var retainedByteCount: Int64 = 0
    }

    enum InspectionError: LocalizedError {
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case let .unavailable(reason): reason
            }
        }
    }

    @Published private(set) var entries: [Entry] = []
    private let maximumCompletedEntries: Int
    private let maximumRetainedBytes: Int64
    private var ownerLeases: [UUID: HTTPBodyLease] = [:]
    private var releaseTasks: [Task<Void, Never>] = []
    private var manager: HTTPExecutionManager?
    private var isClosed = false

    init(maximumCompletedEntries: Int = 10, maximumRetainedBytes: Int64 = 100_000_000) {
        self.maximumCompletedEntries = max(0, maximumCompletedEntries)
        self.maximumRetainedBytes = max(0, maximumRetainedBytes)
    }

    func connect(to manager: HTTPExecutionManager) {
        guard self.manager == nil, !isClosed else { return }
        self.manager = manager
    }

    func entry(for token: UUID) -> Entry? {
        entries.first { $0.token == token }
    }

    func begin(identity: RequestIdentity, active: AppModel.ActiveRun) {
        guard !isClosed, entry(for: active.token) == nil else { return }
        let source = active.snapshotSource.map {
            SnapshotSource(
                identity: $0.identity, collectionName: bounded($0.collectionName), requestName: bounded($0.requestName))
        }
        entries.insert(
            Entry(
                token: active.token, source: source, liveSourceIdentity: identity,
                method: bounded(active.request.method), requestName: bounded(active.request.name),
                url: bounded(active.request.url, limit: 2048), startedAt: active.startedAt,
                phase: .preparing, request: active.request, capture: active.snapshotCapture,
                redirects: active.redirects), at: 0)
    }

    func update(_ active: AppModel.ActiveRun) {
        guard let index = entries.firstIndex(where: { $0.token == active.token && $0.phase.isActive }) else { return }
        switch active.phase {
        case .preparing: entries[index].phase = .preparing
        case .running: entries[index].phase = .running
        case .cancelling: entries[index].phase = .cancelling
        }
        entries[index].capture = active.snapshotCapture
        entries[index].progress = active.progress
        entries[index].redirects = active.redirects
    }

    func retainResponse(_ response: HTTPResponseRecord, for token: UUID) async {
        guard let entry = entry(for: token), entry.phase.isActive, let manager, !isClosed,
            ownerLeases[token] == nil
        else { return }
        let size = logicalBytes(entry: entry, response: response)
        guard size <= maximumRetainedBytes else { return }
        do {
            let lease = try await manager.acquireBodyLease(for: response)
            guard !isClosed, self.entry(for: token)?.phase.isActive == true, ownerLeases[token] == nil else {
                await manager.releaseBodyLease(lease)
                return
            }
            ownerLeases[token] = lease
        } catch {
            guard let index = entries.firstIndex(where: { $0.token == token && $0.phase.isActive }) else { return }
            entries[index].detailsUnavailableReason = "The response body is no longer available."
        }
    }

    func finish(token: UUID, phase: Phase, response: HTTPResponseRecord? = nil, error: String? = nil) {
        guard !phase.isActive,
            let index = entries.firstIndex(where: { $0.token == token && $0.phase.isActive })
        else { return }
        entries[index].phase = phase
        entries[index].finishedAt = response?.completedAt ?? Date()
        entries[index].response = response
        entries[index].statusCode = response?.statusCode
        entries[index].bodyByteCount = response?.bodyByteCount
        entries[index].errorMessage = error.map { bounded($0, limit: 2048) }
        if let response { entries[index].redirects = response.redirects }
        let size = logicalBytes(entry: entries[index], response: response)
        if size > maximumRetainedBytes {
            entries[index].request = nil
            entries[index].capture = nil
            entries[index].response = nil
            entries[index].redirects = []
            entries[index].detailsUnavailableReason = "Details exceeded the session history retention limit."
            releaseOwner(for: token)
        } else {
            entries[index].retainedByteCount = size
        }
        prune()
    }

    func remapSource(from oldIdentity: RequestIdentity, to newIdentity: RequestIdentity) {
        for index in entries.indices where entries[index].liveSourceIdentity == oldIdentity {
            entries[index].liveSourceIdentity = newIdentity
        }
    }

    func removeSource(_ identity: RequestIdentity) {
        for index in entries.indices where entries[index].liveSourceIdentity == identity {
            entries[index].liveSourceIdentity = nil
        }
    }

    func withRetainedResponse<Value>(
        for token: UUID,
        operation: @MainActor (HTTPResponseRecord, URL) async throws -> Value
    ) async throws -> Value {
        guard !isClosed, let entry = entry(for: token), let response = entry.response,
            let owner = ownerLeases[token], let manager
        else {
            throw InspectionError.unavailable(
                entry(for: token)?.detailsUnavailableReason
                    ?? "A completed response body was not captured for this run.")
        }
        let lease = try await manager.acquireBodyLease(for: response, sharing: owner)
        do {
            try Task.checkCancellation()
            let result = try await operation(response, lease.bodyURL)
            await manager.releaseBodyLease(lease)
            return result
        } catch {
            await manager.releaseBodyLease(lease)
            throw error
        }
    }

    func clear() async {
        isClosed = true
        let leases = Array(ownerLeases.values)
        ownerLeases.removeAll()
        entries.removeAll()
        let releases = releaseTasks
        releaseTasks.removeAll()
        if let manager {
            for lease in leases { await manager.releaseBodyLease(lease) }
        }
        for release in releases { await release.value }
    }

    private func prune() {
        while entries.filter({ !$0.phase.isActive }).count > maximumCompletedEntries
            || retainedByteCount > maximumRetainedBytes
        {
            guard let index = entries.lastIndex(where: { !$0.phase.isActive }) else { return }
            let token = entries.remove(at: index).token
            releaseOwner(for: token)
        }
    }

    private var retainedByteCount: Int64 {
        var count = SessionCaptureByteCount()
        for entry in entries { count.add(bytes: entry.retainedByteCount) }
        return count.bytes
    }

    private func releaseOwner(for token: UUID) {
        guard let lease = ownerLeases.removeValue(forKey: token), let manager else { return }
        let previous = releaseTasks.last
        releaseTasks = [
            Task {
                await previous?.value
                await manager.releaseBodyLease(lease)
            }
        ]
    }

    private func bounded(_ value: String, limit: Int = 512) -> String {
        String(decoding: value.utf8.prefix(limit), as: UTF8.self)
    }

    private func logicalBytes(entry: Entry, response: HTTPResponseRecord?) -> Int64 {
        var count = SessionCaptureByteCount()
        if let request = entry.request { count.add(request) }
        if let capture = entry.capture { count.add(capture) }
        for redirect in entry.redirects { count.add(redirect) }
        if let response {
            count.add(response.request)
            if let capture = response.snapshotCapture { count.add(capture) }
            count.add(response.finalURL.absoluteString)
            count.add(response.effectiveMethod)
            count.add(response.requestHeaders)
            count.add(response.responseHeaders)
            count.add(response.sensitiveRequestHeaderNames)
            count.add(response.secretRequestHeaderNames)
            count.add(response.requestHeaderSources.keys)
            for redirect in response.redirects { count.add(redirect) }
            if let redirect = response.pendingRedirect { count.add(redirect) }
            if let request = response.redirectRequest {
                count.add(request.url?.absoluteString ?? "")
                count.add(request.httpMethod ?? "")
                for (name, value) in request.allHTTPHeaderFields ?? [:] {
                    count.add(name)
                    count.add(value)
                }
                count.add(bytes: Int64(request.httpBody?.count ?? 0))
            }
            count.add(bytes: max(0, response.bodyByteCount))
        }
        return count.bytes
    }
}

private struct SessionCaptureByteCount {
    var bytes: Int64 = 0

    mutating func add(_ value: String) { add(bytes: Int64(value.utf8.count)) }

    mutating func add(bytes additional: Int64) {
        let result = bytes.addingReportingOverflow(max(0, additional))
        bytes = result.overflow ? Int64.max : result.partialValue
    }

    mutating func add<S: Sequence>(_ values: S) where S.Element == String {
        for value in values { add(value) }
    }

    mutating func add(_ fields: [HTTPField]) {
        for field in fields {
            add(field.name)
            add(field.value)
        }
    }

    mutating func add(_ request: HTTPRequestConfiguration) {
        add(request.name)
        add(request.method)
        add(request.url)
        add(request.pathParameters)
        add(request.query)
        add(request.headers)
        add(request.body)
        for (name, value) in request.variables {
            add(name)
            switch value {
            case let .plain(value): add(value)
            case let .encrypted(envelope): add(envelope.combined)
            }
        }
        add(request.authentication.username)
        add(request.authentication.password?.combined ?? "")
        add(request.authentication.token?.combined ?? "")
        add(request.authentication.apiKey?.combined ?? "")
        add(request.authentication.apiKeyHeaderName ?? "")
    }

    mutating func add(_ capture: SnapshotPreparationCapture) {
        add(capture.template.method)
        add(capture.template.url)
        add(capture.template.pathParameters)
        add(capture.template.query)
        add(capture.template.headers)
        add(capture.template.body)
        for (name, input) in capture.referencedInputs {
            add(name)
            add(input.value)
        }
        add(capture.authentication.username)
        add(capture.authentication.secretTemplate ?? "")
        add(capture.authentication.resolvedSecret ?? "")
        add(capture.authentication.apiKeyHeaderName ?? "")
        add(capture.submitted.method)
        add(capture.submitted.url.absoluteString)
        add(capture.submitted.headers)
        add(capture.submitted.body ?? "")
        add(capture.submitted.headerSources.keys)
        add(capture.submitted.sensitiveNames)
        add(capture.submitted.secretNames)
        for (name, input) in capture.redactionInputs?.inputs ?? [:] {
            add(name)
            add(input.value)
        }
    }

    mutating func add(_ redirect: HTTPRedirect) {
        add(redirect.url.absoluteString)
        add(redirect.nextURL.absoluteString)
        add(redirect.method)
        add(redirect.nextMethod)
        add(redirect.requestHeaders)
        add(redirect.responseHeaders)
        add(redirect.requestHeaderSources.keys)
        add(redirect.sensitiveRequestHeaderNames)
        add(redirect.secretRequestHeaderNames)
    }
}
