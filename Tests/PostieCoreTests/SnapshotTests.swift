import Foundation
import XCTest
@testable import PostieCore

final class SnapshotTests: XCTestCase {
    func testCaptureFreezesEffectiveQueryHeadersAndAuthentication() async throws {
        let vault = SecretVault(keyStore: SnapshotTestKeyStore(), allowsKeyCreation: true)
        let auth = try await vault.encrypt("{{token}}")
        let configuration = HTTPRequestConfiguration(
            url: "https://example.invalid/{{path}}?q={{query}}",
            query: [HTTPField(name: "q", value: "{{query}}"), HTTPField(name: "q", value: "")],
            headers: [
                HTTPField(name: "X-Override", value: "request"),
                HTTPField(name: "{{disabled}}", value: "unused", isEnabled: false),
            ],
            variables: ["query": .plain("request-query")], inheritsCollectionAuthentication: true
        )
        let prepared = try await RequestPreparer.prepare(
            configuration,
            context: VariableContext(
                global: ["query": .plain("global-query"), "unused": .plain("never capture")],
                collection: [
                    "path": .plain("frozen-path"), "token": .plain("frozen-token"),
                    "inherited": .plain("frozen-header"), "disabled": .plain("X-Disabled"),
                ]),
            decryptor: vault,
            collection: CollectionRequestDefaults(
                headers: [
                    HTTPField(name: "X-Inherited", value: "{{inherited}}"),
                    HTTPField(name: "X-Override", value: "{{unused}}"),
                ],
                authentication: RequestAuthentication(kind: .bearer, token: auth)
            )
        )
        let capture = try XCTUnwrap(prepared.snapshotCapture)
        XCTAssertEqual(Set(capture.referencedInputs.keys), ["query", "path", "token", "inherited"])
        XCTAssertEqual(capture.referencedInputs["query"]?.scope, .request)
        XCTAssertEqual(capture.template.url, configuration.url)
        XCTAssertEqual(capture.template.query, configuration.query)
        XCTAssertEqual(capture.template.headers.first?.name, "X-Inherited")
        XCTAssertEqual(capture.authentication.resolvedSecret, "frozen-token")
        XCTAssertEqual(
            capture.submitted.headers.first { $0.name.lowercased() == "authorization" }?.value, "Bearer frozen-token")
        XCTAssertNil(capture.submitted.body)
        var emptyBody = configuration
        emptyBody.bodyEnabled = true
        let emptyBodyPrepared = try await RequestPreparer.prepare(
            emptyBody,
            context: VariableContext(collection: ["path": .plain("path"), "disabled": .plain("X-Disabled")]),
            decryptor: nil
        )
        XCTAssertEqual(emptyBodyPrepared.snapshotCapture?.submitted.body, "")

        var overridden = configuration
        overridden.headers.append(HTTPField(name: "Authorization", value: "manual"))
        let overriddenPrepared = try await RequestPreparer.prepare(
            overridden,
            context: VariableContext(collection: ["path": .plain("path"), "disabled": .plain("X-Disabled")]),
            decryptor: nil,
            collection: CollectionRequestDefaults(authentication: RequestAuthentication(kind: .bearer, token: auth))
        )
        XCTAssertEqual(overriddenPrepared.snapshotCapture?.authentication.kind, AuthenticationKind.none)
        XCTAssertNil(overriddenPrepared.snapshotCapture?.referencedInputs["token"])
    }

    func testSaveRestartRenameAndDeleteKeepFrozenEncryptedContextAndBinaryBody() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let keyStore = SnapshotTestKeyStore()
        let vault = SecretVault(keyStore: keyStore, allowsKeyCreation: true)
        let store = SnapshotStore(rootURL: root.appendingPathComponent("snapshots"), vault: vault)
        let body = Data([0, 255, 1, 128, 10])
        let (response, source, lease) = try await fixture(root: root, body: body, vault: vault)
        let saved = try await store.save(response: response, source: source, name: "Saved exchange", bodyLease: lease)
        let metadata = root.appendingPathComponent("snapshots/\(saved.id.uuidString)/snapshot.json")
        let raw = try String(contentsOf: metadata, encoding: .utf8)
        for value in ["private-query-value", "private-token-value", "private-header-name", "private-header-value"] {
            XCTAssertFalse(raw.contains(value), "Resolved request data must stay inside ciphertext")
        }
        XCTAssertFalse(raw.contains(response.bodyFileURL.path))
        XCTAssertEqual(saved.capturedAt, response.completedAt)

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let envelope = try XCTUnwrap(json["encryptedContext"] as? NSDictionary)
        json["futureField"] = ["retained": true]
        try JSONSerialization.data(withJSONObject: json).write(to: metadata)
        let renamed = try await store.rename(id: saved.id, name: "Renamed exchange")
        let renamedJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        XCTAssertEqual(renamedJSON["encryptedContext"] as? NSDictionary, envelope)
        XCTAssertNotNil(renamedJSON["futureField"])

        try FileManager.default.removeItem(at: response.bodyFileURL)
        let restarted = SnapshotStore(
            rootURL: root.appendingPathComponent("snapshots"), vault: SecretVault(keyStore: keyStore))
        let load = try await restarted.load()
        XCTAssertEqual(load.snapshots, [renamed])
        XCTAssertTrue(load.containsEncryptedData)
        let opened = try await restarted.open(id: saved.id)
        XCTAssertNil(opened.contextError)
        XCTAssertEqual(opened.context?.preparation.referencedInputs["query"]?.value, "private-query-value")
        XCTAssertEqual(opened.response.finalURL, response.finalURL)
        XCTAssertEqual(opened.response.requestHeaders, response.requestHeaders)
        XCTAssertEqual(opened.response.redirects.first?.url, response.redirects.first?.url)
        XCTAssertEqual(opened.response.redirects.first?.requestHeaders, response.redirects.first?.requestHeaders)
        XCTAssertNil(opened.response.redirectRequest)
        XCTAssertEqual(try Data(contentsOf: opened.response.bodyFileURL), body)
        try await restarted.delete(id: saved.id)
        let empty = try await restarted.load()
        XCTAssertTrue(empty.snapshots.isEmpty)
    }

    func testMissingKeyKeepsResponseReadableAndBlocksReplacement() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = SecretVault(keyStore: SnapshotTestKeyStore(), allowsKeyCreation: true)
        let (response, source, lease) = try await fixture(root: root, body: Data(), vault: vault)
        let snapshotsURL = root.appendingPathComponent("snapshots")
        let store = SnapshotStore(rootURL: snapshotsURL, vault: vault)
        let saved = try await store.save(response: response, source: source, name: "Empty response", bodyLease: lease)
        let missingKey = SnapshotTestKeyStore()
        let restarted = SnapshotStore(rootURL: snapshotsURL, vault: SecretVault(keyStore: missingKey))
        let loaded = try await restarted.load()
        XCTAssertTrue(loaded.containsEncryptedData)
        let opened = try await restarted.open(id: saved.id)
        XCTAssertNil(opened.context)
        XCTAssertNotNil(opened.contextError)
        XCTAssertEqual(opened.response.statusCode, 418)
        XCTAssertEqual(opened.response.responseHeaders, response.responseHeaders)
        XCTAssertTrue(try Data(contentsOf: opened.response.bodyFileURL).isEmpty)
        XCTAssertEqual(opened.response.finalURL.absoluteString, "about:blank")
        XCTAssertNil(missingKey.key)
    }

    func testMalformedUnsupportedAndSymlinkEntriesArePreservedWithConservativeKeyGate() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshots = root.appendingPathComponent("snapshots")
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        let malformed = snapshots.appendingPathComponent(UUID().uuidString)
        let unsupported = snapshots.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: malformed, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: unsupported, withIntermediateDirectories: false)
        try Data("{broken".utf8).write(to: malformed.appendingPathComponent("snapshot.json"))
        try Data("{\"version\":99}".utf8).write(to: unsupported.appendingPathComponent("snapshot.json"))
        let target = root.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: snapshots.appendingPathComponent(UUID().uuidString), withDestinationURL: target)
        let abandoned = snapshots.appendingPathComponent(".staging/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try Data("Postie snapshot staging v1\n".utf8).write(
            to: abandoned.appendingPathComponent(".postie-snapshot-stage"))
        try Data([1]).write(to: abandoned.appendingPathComponent("response.body"))
        let store = SnapshotStore(rootURL: snapshots, vault: SecretVault(keyStore: SnapshotTestKeyStore()))
        let loaded = try await store.load()
        XCTAssertTrue(loaded.containsEncryptedData)
        XCTAssertTrue(loaded.snapshots.isEmpty)
        XCTAssertEqual(loaded.issues.count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: malformed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unsupported.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))

        let fileParent = root.appendingPathComponent("not-a-directory")
        try Data().write(to: fileParent)
        let uncertain = SnapshotStore(
            rootURL: fileParent.appendingPathComponent("snapshots"),
            vault: SecretVault(keyStore: SnapshotTestKeyStore()))
        do {
            _ = try await uncertain.load()
            XCTFail("Lookup uncertainty must never be reported as an empty snapshot store")
        } catch {}
    }

    func testFailedBodyCopyAndEncryptionPublishNothing() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = SecretVault(keyStore: SnapshotTestKeyStore(), allowsKeyCreation: true)
        let (response, source, lease) = try await fixture(root: root, body: Data([1, 2]), vault: vault)
        let snapshots = root.appendingPathComponent("snapshots")
        let store = SnapshotStore(rootURL: snapshots, vault: vault)
        try Data([1]).write(to: response.bodyFileURL)
        do {
            _ = try await store.save(response: response, source: source, name: "Incomplete", bodyLease: lease)
            XCTFail("An incomplete body must not publish")
        } catch {}
        let loaded = try await store.load()
        XCTAssertTrue(loaded.snapshots.isEmpty)
        let unavailable = SnapshotStore(
            rootURL: root.appendingPathComponent("denied"), vault: SecretVault(keyStore: SnapshotTestKeyStore()))
        do {
            _ = try await unavailable.save(response: response, source: source, name: "Denied", bodyLease: lease)
            XCTFail("Encryption failure must not publish")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("denied").path))
    }

    func testBodyLeasesDeferDiscardAndShutdownWithoutStartingRequests() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bodyRoot = root.appendingPathComponent("bodies")
        let manager = try HTTPExecutionManager(bodyDirectory: bodyRoot)
        let session = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: bodyRoot, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix(".postie-http-session-") }
        ).resolvingSymlinksInPath()
        let bodyURL = session.appendingPathComponent("synthetic.body")
        try Data([1, 2]).write(to: bodyURL)
        let request = HTTPRequestConfiguration(url: "https://example.invalid")
        let identity = RequestIdentity(collectionID: UUID(), requestID: request.id)
        let response = HTTPResponseRecord(
            runID: UUID(), request: request, finalURL: URL(string: request.url)!, statusCode: 200,
            requestHeaders: [], responseHeaders: [], redirects: [], bodyFileURL: bodyURL,
            bodyByteCount: 2, duration: 0
        )
        try await manager.retainCompletedResponse(response, identity: identity)
        let lease = try await manager.acquireBodyLease(for: response)
        try await manager.discardBody(at: bodyURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bodyURL.path))
        await manager.releaseBodyLease(lease)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bodyURL.path))

        try Data([3, 4]).write(to: bodyURL)
        try await manager.retainCompletedResponse(response, identity: identity)
        let shutdownLease = try await manager.acquireBodyLease(for: response)
        let shutdown = Task { await manager.shutdown() }
        var shutdownStarted = false
        for _ in 0..<100 {
            do {
                let additional = try await manager.acquireBodyLease(for: response)
                await manager.releaseBodyLease(additional)
            } catch {
                shutdownStarted = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(shutdownStarted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bodyURL.path))
        await manager.releaseBodyLease(shutdownLease)
        await shutdown.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.path))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "postie-snapshot-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func fixture(root: URL, body: Data, vault: SecretVault) async throws -> (
        HTTPResponseRecord, SnapshotSource, HTTPBodyLease
    ) {
        let token = try await vault.encrypt("private-token-value")
        let headerName = try await vault.encrypt("private-header-name")
        let configuration = HTTPRequestConfiguration(
            name: "Original request", url: "https://example.invalid/?q={{query}}",
            headers: [HTTPField(name: "{{headerName}}", value: "{{headerValue}}")],
            variables: [
                "query": .plain("private-query-value"), "headerName": .encrypted(headerName),
                "headerValue": .plain("private-header-value"),
            ],
            authentication: RequestAuthentication(kind: .bearer, token: token)
        )
        let prepared = try await RequestPreparer.prepare(configuration, context: .init(), decryptor: vault)
        let capture = try XCTUnwrap(prepared.snapshotCapture)
        let bodyURL = root.appendingPathComponent("live.body").standardizedFileURL
        try body.write(to: bodyURL)
        let response = HTTPResponseRecord(
            runID: UUID(), request: configuration, finalURL: capture.submitted.url, statusCode: 418,
            requestHeaders: capture.submitted.headers,
            responseHeaders: [HTTPField(name: "Content-Type", value: "application/octet-stream")],
            redirects: [
                HTTPRedirect(
                    statusCode: 302, url: capture.submitted.url, nextURL: capture.submitted.url,
                    method: "GET", nextMethod: "GET", requestHeaders: capture.submitted.headers,
                    responseHeaders: [HTTPField(name: "X-Response", value: "original")],
                    sensitiveRequestHeaderNames: capture.submitted.sensitiveNames,
                    secretRequestHeaderNames: capture.submitted.secretNames,
                    requestHeaderSources: capture.submitted.headerSources
                )
            ], bodyFileURL: bodyURL, bodyByteCount: Int64(body.count), duration: 0.25,
            sensitiveRequestHeaderNames: capture.submitted.sensitiveNames,
            secretRequestHeaderNames: capture.submitted.secretNames,
            requestHeaderSources: capture.submitted.headerSources, snapshotCapture: capture,
            completedAt: Date(timeIntervalSince1970: 1_792_345_678)
        )
        let source = SnapshotSource(
            identity: RequestIdentity(collectionID: UUID(), requestID: configuration.id),
            collectionName: "Original collection", requestName: configuration.name)
        return (response, source, HTTPBodyLease(token: UUID(), runID: response.runID, bodyURL: bodyURL))
    }
}

private final class SnapshotTestKeyStore: ApplicationKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storedKey: Data?

    var key: Data? { lock.withLock { storedKey } }

    func loadKey() throws -> Data? { key }

    func createKey(_ proposedKey: Data) throws -> Data {
        lock.withLock {
            if let storedKey { return storedKey }
            storedKey = proposedKey
            return proposedKey
        }
    }
}
