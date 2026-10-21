import Foundation
import XCTest
@testable import PostieCore

final class SecretRedactionCaptureTests: XCTestCase {
    func testPreparationCapturesUnusedSecretWithoutChangingReferencedInputsOrHTTP() async throws {
        let configuration = HTTPRequestConfiguration(
            method: "POST", url: "https://example.invalid/response", body: "request-body", bodyEnabled: true,
            variables: ["test": .encrypted(SecretEnvelope(combined: "unused-secret"))]
        )
        let prepared = try await RequestPreparer.prepare(
            configuration, context: .init(), decryptor: RedactionCaptureDecryptor(), captureRedactionInputs: true
        )
        let capture = try XCTUnwrap(prepared.snapshotCapture)

        XCTAssertTrue(prepared.referencedInputs.isEmpty)
        XCTAssertTrue(capture.referencedInputs.isEmpty)
        XCTAssertEqual(prepared.request.url?.absoluteString, "https://example.invalid/response")
        XCTAssertEqual(prepared.request.httpMethod, "POST")
        XCTAssertEqual(prepared.request.httpBody, Data("request-body".utf8))
        XCTAssertNil(prepared.request.value(forHTTPHeaderField: "test"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(capture)) as? [String: Any])
        let redaction = try XCTUnwrap(json["redactionInputs"] as? [String: Any])
        let inputs = try XCTUnwrap(redaction["inputs"] as? [String: Any])
        let secret = try XCTUnwrap(inputs["test"] as? [String: Any])
        XCTAssertEqual(secret["value"] as? String, "freshness")
        XCTAssertEqual(secret["scope"] as? String, "request")
        XCTAssertEqual(secret["isSecret"] as? Bool, true)
        XCTAssertEqual(redaction["isComplete"] as? Bool, true)
    }

    func testCaptureUsesEffectiveSecretWinnersAndReusesReferencedDecryption() async throws {
        let decryptor = RedactionCaptureDecryptor(values: [
            "global": "global-value", "collection": "collection-value", "request": "request-value",
            "fallback": "fallback-value", "referenced": "referenced-value"
        ])
        let configuration = HTTPRequestConfiguration(
            url: "https://example.invalid/?q={{referenced}}",
            variables: ["fallback": secret("fallback"), "requestWins": secret("ignored-configuration")]
        )
        let context = VariableContext(
            global: ["globalOnly": secret("global"), "collectionWins": secret("ignored-global"),
                     "plainWinner": secret("ignored-secret")],
            collection: ["collectionWins": secret("collection"), "requestWins": secret("ignored-collection"),
                         "plainWinner": .plain("plain-value")],
            request: ["requestWins": secret("request"), "referenced": secret("referenced")]
        )

        let prepared = try await RequestPreparer.prepare(
            configuration, context: context, decryptor: decryptor, captureRedactionInputs: true
        )
        let inputs = try XCTUnwrap(prepared.snapshotCapture?.redactionInputs)
        let calls = await decryptor.calls

        XCTAssertTrue(inputs.isComplete)
        XCTAssertEqual(Set(inputs.inputs.keys), ["globalOnly", "collectionWins", "requestWins", "fallback", "referenced"])
        XCTAssertEqual(inputs.inputs["globalOnly"], SnapshotInput(value: "global-value", scope: .global, isSecret: true))
        XCTAssertEqual(inputs.inputs["collectionWins"], SnapshotInput(value: "collection-value", scope: .collection, isSecret: true))
        XCTAssertEqual(inputs.inputs["requestWins"], SnapshotInput(value: "request-value", scope: .request, isSecret: true))
        XCTAssertEqual(inputs.inputs["fallback"]?.scope, .request)
        XCTAssertEqual(Set(prepared.referencedInputs.keys), ["referenced"])
        XCTAssertEqual(Set(try XCTUnwrap(prepared.snapshotCapture).referencedInputs.keys), ["referenced"])
        XCTAssertEqual(calls.count, 5)
        XCTAssertEqual(calls.filter { $0 == "referenced" }.count, 1)
    }

    func testUnavailableUnusedSecretMarksIncompleteWithoutFailingPreparation() async throws {
        let configuration = HTTPRequestConfiguration(
            url: "https://example.invalid/", variables: ["available": secret("unused-secret"), "unavailable": secret("missing")]
        )
        let prepared = try await RequestPreparer.prepare(
            configuration, context: .init(), decryptor: RedactionCaptureDecryptor(), captureRedactionInputs: true
        )
        let capture = try XCTUnwrap(prepared.snapshotCapture?.redactionInputs)

        XCTAssertFalse(capture.isComplete)
        XCTAssertEqual(capture.inputs["available"]?.value, "freshness")
        XCTAssertNil(capture.inputs["unavailable"])
        XCTAssertTrue(prepared.referencedInputs.isEmpty)
        XCTAssertEqual(prepared.request.url?.absoluteString, configuration.url)

        let locked = try await RequestPreparer.prepare(configuration, context: .init(), decryptor: nil, captureRedactionInputs: true)
        XCTAssertEqual(locked.snapshotCapture?.redactionInputs, SnapshotRedactionCapture(inputs: [:], isComplete: false))
    }

    func testUnusedSecretCancellationPropagates() async throws {
        let configuration = HTTPRequestConfiguration(url: "https://example.invalid/", variables: ["test": secret("unused-secret")])
        do {
            _ = try await RequestPreparer.prepare(
                configuration, context: .init(), decryptor: RedactionCaptureDecryptor(cancels: true), captureRedactionInputs: true
            )
            XCTFail("Cancellation during unused secret decryption must cancel preparation")
        } catch is CancellationError {
        }
    }

    func testDisablingCaptureAvoidsUnusedSecretDecryption() async throws {
        let decryptor = RedactionCaptureDecryptor(cancels: true)
        let configuration = HTTPRequestConfiguration(url: "https://example.invalid/", variables: ["test": secret("unused-secret")])

        let prepared = try await RequestPreparer.prepare(
            configuration, context: .init(), decryptor: decryptor, captureRedactionInputs: false
        )
        let calls = await decryptor.calls

        XCTAssertNil(prepared.snapshotCapture?.redactionInputs)
        XCTAssertTrue(calls.isEmpty)
    }

    func testSecretCountLimitStopsFurtherDecryptions() async throws {
        for count in [128, 130] {
            let names = (0..<count).map { String(format: "secret-%03d", $0) }
            let variables = Dictionary(uniqueKeysWithValues: names.map { ($0, secret($0)) })
            let decryptor = RedactionCaptureDecryptor(values: Dictionary(uniqueKeysWithValues: names.map { ($0, "value") }))
            let prepared = try await RequestPreparer.prepare(
                HTTPRequestConfiguration(url: "https://example.invalid/", variables: variables),
                context: .init(), decryptor: decryptor, captureRedactionInputs: true
            )
            let capture = try XCTUnwrap(prepared.snapshotCapture?.redactionInputs)
            let calls = await decryptor.calls

            XCTAssertEqual(capture.inputs.count, 128)
            XCTAssertEqual(capture.isComplete, count == 128)
            XCTAssertEqual(calls.count, 128)
        }
    }

    func testUTF8ByteLimitStopsAfterOversizedSecret() async throws {
        let decryptor = RedactionCaptureDecryptor(values: ["large": String(repeating: "é", count: 524_288), "later": "later"])
        let prepared = try await RequestPreparer.prepare(
            HTTPRequestConfiguration(url: "https://example.invalid/", variables: ["a": secret("large"), "b": secret("later")]),
            context: .init(), decryptor: decryptor, captureRedactionInputs: true
        )
        let capture = try XCTUnwrap(prepared.snapshotCapture?.redactionInputs)
        let calls = await decryptor.calls

        XCTAssertFalse(capture.isComplete)
        XCTAssertTrue(capture.inputs.isEmpty)
        XCTAssertEqual(calls, ["large"])
    }

    func testSnapshotRoundtripPersistsUnusedSecretOnlyInEncryptedContext() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let keyStore = RedactionCaptureKeyStore()
        let vault = SecretVault(keyStore: keyStore, allowsKeyCreation: true)
        let (saved, metadata) = try await saveSnapshot(root: root, vault: vault)
        let raw = try String(contentsOf: metadata, encoding: .utf8)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let envelope = try JSONDecoder().decode(SecretEnvelope.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(json["encryptedContext"])))
        let plaintext = try await vault.decrypt(envelope)
        let encryptedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(plaintext.utf8)) as? [String: Any])

        XCTAssertFalse(raw.contains("frozen-unused-secret"))
        XCTAssertNil(json["redactionInputs"])
        XCTAssertNotNil(encryptedJSON["redactionInputs"])
        let restarted = SnapshotStore(rootURL: root.appendingPathComponent("snapshots"), vault: SecretVault(keyStore: keyStore))
        let opened = try await restarted.open(id: saved.id)
        let expected = SnapshotRedactionCapture(
            inputs: ["test": SnapshotInput(value: "frozen-unused-secret", scope: .request, isSecret: true)], isComplete: true
        )
        XCTAssertNil(opened.contextError)
        XCTAssertEqual(opened.context?.preparation.redactionInputs, expected)
        XCTAssertEqual(opened.response.snapshotCapture?.redactionInputs, expected)
        XCTAssertTrue(try XCTUnwrap(opened.context).preparation.referencedInputs.isEmpty)
    }

    func testLegacySnapshotWithoutRedactionInputsRemainsAbsent() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = SecretVault(keyStore: RedactionCaptureKeyStore(), allowsKeyCreation: true)
        let (saved, metadata) = try await saveSnapshot(root: root, vault: vault)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        let envelope = try JSONDecoder().decode(SecretEnvelope.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(json["encryptedContext"])))
        let plaintext = try await vault.decrypt(envelope)
        var encryptedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(plaintext.utf8)) as? [String: Any])
        encryptedJSON.removeValue(forKey: "redactionInputs")
        let legacyEnvelope = try await vault.encrypt(String(decoding: JSONSerialization.data(withJSONObject: encryptedJSON), as: UTF8.self))
        json["encryptedContext"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyEnvelope))
        try JSONSerialization.data(withJSONObject: json).write(to: metadata)

        let restarted = SnapshotStore(rootURL: root.appendingPathComponent("snapshots"), vault: vault)
        let opened = try await restarted.open(id: saved.id)

        XCTAssertNil(opened.contextError)
        XCTAssertNotNil(opened.context)
        XCTAssertNil(opened.context?.preparation.redactionInputs)
        XCTAssertNil(opened.response.snapshotCapture?.redactionInputs)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("postie-redaction-capture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func saveSnapshot(root: URL, vault: SecretVault) async throws -> (SavedSnapshot, URL) {
        let encrypted = try await vault.encrypt("frozen-unused-secret")
        let configuration = HTTPRequestConfiguration(url: "https://example.invalid/", variables: ["test": .encrypted(encrypted)])
        let prepared = try await RequestPreparer.prepare(configuration, context: .init(), decryptor: vault, captureRedactionInputs: true)
        let capture = try XCTUnwrap(prepared.snapshotCapture)
        let bodyURL = root.appendingPathComponent("live.body").standardizedFileURL
        try Data("response".utf8).write(to: bodyURL)
        let response = HTTPResponseRecord(
            runID: UUID(), request: configuration, finalURL: capture.submitted.url, statusCode: 200,
            requestHeaders: capture.submitted.headers, responseHeaders: [], redirects: [],
            bodyFileURL: bodyURL, bodyByteCount: 8, duration: 0, snapshotCapture: capture
        )
        let source = SnapshotSource(
            identity: RequestIdentity(collectionID: UUID(), requestID: configuration.id),
            collectionName: "Synthetic collection", requestName: "Synthetic request"
        )
        let store = SnapshotStore(rootURL: root.appendingPathComponent("snapshots"), vault: vault)
        let saved = try await store.save(
            response: response, source: source, name: "Synthetic snapshot",
            bodyLease: HTTPBodyLease(token: UUID(), runID: response.runID, bodyURL: bodyURL)
        )
        return (saved, root.appendingPathComponent("snapshots/\(saved.id.uuidString)/snapshot.json"))
    }

    private func secret(_ identifier: String) -> VariableValue {
        .encrypted(SecretEnvelope(combined: identifier))
    }
}

private actor RedactionCaptureDecryptor: SecretValueDecrypting {
    let values: [String: String]
    let cancels: Bool
    private(set) var calls: [String] = []

    init(values: [String: String] = ["unused-secret": "freshness"], cancels: Bool = false) {
        self.values = values
        self.cancels = cancels
    }

    func decrypt(_ envelope: SecretEnvelope) async throws -> String {
        calls.append(envelope.combined)
        if cancels { throw CancellationError() }
        guard let value = values[envelope.combined] else { throw SecretVaultError.missingKey }
        return value
    }
}

private final class RedactionCaptureKeyStore: ApplicationKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storedKey: Data?

    func loadKey() throws -> Data? {
        lock.withLock { storedKey }
    }

    func createKey(_ proposedKey: Data) throws -> Data {
        lock.withLock {
            if let storedKey { return storedKey }
            storedKey = proposedKey
            return proposedKey
        }
    }
}
