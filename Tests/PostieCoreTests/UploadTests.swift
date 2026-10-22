import CryptoKit
import Darwin
import Dispatch
import Foundation
import XCTest
@testable import PostieCore

final class UploadTests: XCTestCase {
    func testRawStreamPreservesBinaryBytesAndHashesOnlyCompletedRead() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data((0...255).map(UInt8.init)) + Data("{{untouched}}\r\n".utf8)
        let source = root.appendingPathComponent("literal-{{filename}}.bin")
        try bytes.write(to: source)
        let prepared = try await prepare(source: source)
        let upload = try XCTUnwrap(prepared.uploadBody)
        XCTAssertNil(prepared.request.httpBody)
        XCTAssertEqual(upload.byteCount, Int64(bytes.count))
        XCTAssertNil(upload.snapshotMetadata.files.first?.sha256)
        let partial = try upload.makeInputStream()
        partial.open()
        var scratch = [UInt8](repeating: 0, count: 3)
        XCTAssertEqual(partial.read(&scratch, maxLength: scratch.count), 3)
        partial.close()
        XCTAssertNil(upload.snapshotMetadata.files.first?.sha256)
        XCTAssertEqual(try read(try upload.makeInputStream()), bytes)
        XCTAssertEqual(upload.snapshotMetadata.files.first?.sha256, digest(bytes))
        let capture = try XCTUnwrap(prepared.snapshotCapture).freezingUpload(upload.snapshotMetadata)
        let encoded = try JSONEncoder().encode(capture)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(json.contains(source.path))
        XCTAssertFalse(json.contains("untouched"))
        XCTAssertNil(capture.submitted.body)
        XCTAssertTrue(try XCTUnwrap(capture.submitted.uploadBody).binaryOmitted)
        XCTAssertEqual(capture.preparationVersion, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [source.lastPathComponent])
    }

    func testMultipartTemplatesOnlyTextAndUsesManualBoundary() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("{{literal}}.bin")
        let bytes = Data([0, 255, 13, 10])
        try bytes.write(to: source)
        let configuration = HTTPRequestConfiguration(
            method: "POST", url: "http://127.0.0.1/unused",
            headers: [HTTPField(name: "Content-Type", value: "multipart/form-data; boundary=fixture-boundary")],
            body: "{{unused}}", bodyEnabled: true, bodyKind: .multipart,
            multipartParts: [
                HTTPMultipartPart(name: "text", text: "{{value}}"),
                HTTPMultipartPart(name: "file", kind: .file, file: HTTPFileReference(path: source.path)),
                HTTPMultipartPart(name: "ignored\r\n", kind: .file, isEnabled: false),
            ])
        let prepared = try await RequestPreparer.prepare(
            configuration, context: VariableContext(request: ["value": .plain("resolved")]), decryptor: nil)
        let upload = try XCTUnwrap(prepared.uploadBody)
        let expected =
            Data(
                ("--fixture-boundary\r\nContent-Disposition: form-data; name=\"text\"\r\n\r\nresolved\r\n"
                    + "--fixture-boundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{{literal}}.bin\"\r\n"
                    + "Content-Type: application/octet-stream\r\n\r\n").utf8)
            + bytes + Data("\r\n--fixture-boundary--\r\n".utf8)
        XCTAssertEqual(try read(try upload.makeInputStream()), expected)
        XCTAssertEqual(prepared.request.value(forHTTPHeaderField: "Content-Length"), String(expected.count))
        XCTAssertEqual(prepared.request.value(forHTTPHeaderField: "Content-Type"), configuration.headers[0].value)
        XCTAssertEqual(Set(prepared.referencedInputs.keys), ["value"])
        XCTAssertEqual(prepared.snapshotCapture?.submitted.uploadBody?.parts?.first?.text, "resolved")
        XCTAssertEqual(prepared.snapshotCapture?.template.multipartTemplateParts?.first?.text, "{{value}}")
        XCTAssertNil(prepared.snapshotCapture?.template.uploadBody?.parts)
        let frozen = try XCTUnwrap(prepared.snapshotCapture).freezingUpload(upload.snapshotMetadata)
        XCTAssertEqual(frozen.template.multipartTemplateParts?.first?.text, "{{value}}")
        XCTAssertNil(frozen.template.uploadBody?.parts)
        let templateJSON = String(decoding: try JSONEncoder().encode(frozen.template), as: UTF8.self)
        XCTAssertFalse(templateJSON.contains("resolved"))
    }

    func testMissingChangedNonregularAndInjectedSourcesFailOnSend() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.bin")
        try Data([1, 2, 3]).write(to: source)
        let prepared = try await prepare(source: source)
        let upload = try XCTUnwrap(prepared.uploadBody)
        try Data([1, 2, 3, 4]).write(to: source)
        XCTAssertThrowsError(try upload.makeInputStream())
        try FileManager.default.removeItem(at: source)
        XCTAssertThrowsError(try upload.makeInputStream())
        XCTAssertThrowsError(
            try RequestPreparer.prepare(
                HTTPRequestConfiguration(
                    method: "POST", url: "http://127.0.0.1/unused", bodyEnabled: true, bodyKind: .rawFile,
                    rawFile: HTTPFileReference(path: root.path))))
        try Data([1]).write(to: source)
        XCTAssertThrowsError(
            try RequestPreparer.prepare(
                HTTPRequestConfiguration(
                    method: "POST", url: "http://127.0.0.1/unused", bodyEnabled: true, bodyKind: .rawFile,
                    rawFile: HTTPFileReference(path: source.path, filename: "bad\r\nInjected: yes"))))
        XCTAssertThrowsError(
            try RequestPreparer.prepare(
                HTTPRequestConfiguration(
                    method: "POST", url: "http://127.0.0.1/unused",
                    headers: [HTTPField(name: "Content-Type", value: "application/json")],
                    bodyEnabled: true, bodyKind: .multipart)))
        XCTAssertThrowsError(
            try RequestPreparer.prepare(
                HTTPRequestConfiguration(
                    method: "POST", url: "http://127.0.0.1/unused",
                    headers: [HTTPField(name: "Content-Length", value: "999")],
                    bodyEnabled: true, bodyKind: .rawFile, rawFile: HTTPFileReference(path: source.path))))
    }

    func testConfigurationRoundTripUsesVersionTwoWithoutReadingMissingFile() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CollectionStore(rootURL: root)
        let collection = try await store.createCollection(name: "Synthetic uploads")
        let request = HTTPRequestConfiguration(
            method: "POST", url: "http://127.0.0.1/unused", bodyEnabled: true, bodyKind: .rawFile,
            rawFile: HTTPFileReference(path: root.appendingPathComponent("missing.bin").path))
        try await store.createRequest(request, in: collection.id)
        let loaded = try await store.load()
        XCTAssertEqual(loaded.collections.first?.requests.first, request)
        let path = root.appendingPathComponent(
            "collections/\(collection.id.uuidString.lowercased())/\(request.id.uuidString.lowercased()).json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        XCTAssertEqual(object["formatVersion"] as? Int, 2)
        var text = request
        text.bodyKind = .text
        text.rawFile = nil
        text.body = "legacy text"
        try await store.saveRequest(text, in: collection.id)
        let reloaded = try await store.load()
        XCTAssertEqual(reloaded.collections.first?.requests.first, text)
        let updated = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        XCTAssertEqual(updated["formatVersion"] as? Int, 1)
        XCTAssertNil(updated["rawFile"])
    }

    func testLoopbackRawMultipartAndRedirectReplayPreserveUploadedBytes() async throws {
        let fixture = try UploadFixture()
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("binary.bin")
        let bytes = Data((0...255).map(UInt8.init)) + Data(repeating: 0xFE, count: 131_072)
        try bytes.write(to: source)
        let manager = try HTTPExecutionManager(bodyDirectory: root.appendingPathComponent("responses"))
        for status in [0, 307, 308, 303] {
            let url =
                status == 0
                ? fixture.baseURL + "/upload-echo"
                : fixture.baseURL + "/redirect?status=\(status)&to=%2Fupload-echo"
            let prepared = try await prepare(source: source, url: url, follow: true)
            let response = try await complete(manager, prepared: prepared)
            XCTAssertEqual(try Data(contentsOf: response.bodyFileURL), status == 303 ? Data() : bytes)
            XCTAssertEqual(response.effectiveMethod, status == 303 ? "GET" : "POST")
            if status != 303 {
                XCTAssertEqual(response.snapshotCapture?.submitted.uploadBody?.files.first?.sha256, digest(bytes))
            }
            try await manager.discardBody(at: response.bodyFileURL)
        }
        var multipart = HTTPRequestConfiguration(
            method: "POST", url: fixture.baseURL + "/upload-echo", bodyEnabled: true, bodyKind: .multipart,
            multipartParts: [
                HTTPMultipartPart(name: "payload", kind: .file, file: HTTPFileReference(path: source.path))
            ])
        multipart.headers = [HTTPField(name: "Content-Type", value: "multipart/form-data; boundary=wire-test")]
        let prepared = try await RequestPreparer.prepare(multipart, context: .init(), decryptor: nil)
        let expected = try read(try XCTUnwrap(prepared.uploadBody).makeInputStream())
        let response = try await complete(manager, prepared: prepared)
        XCTAssertEqual(try Data(contentsOf: response.bodyFileURL), expected)
        await manager.shutdown()
    }

    func testManualReplayRejectsChangedSourceAndCancellationCleansResponse() async throws {
        let fixture = try UploadFixture()
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("binary.bin")
        try Data(repeating: 0xAB, count: 65_536).write(to: source)
        let manager = try HTTPExecutionManager(bodyDirectory: root.appendingPathComponent("responses"))
        let counter = UUID().uuidString
        let target = fixture.baseURL + "/upload-echo?upload_counter=\(counter)"
        let prepared = try await prepare(source: source, url: try fixture.redirect(status: 307, to: target))
        let identity = RequestIdentity(collectionID: UUID(), requestID: prepared.configuration.id)
        let stopped = try await complete(manager, prepared: prepared, identity: identity)
        try Data([1]).write(to: source)
        do {
            _ = try await manager.followRedirect(identity: identity, response: stopped)
            XCTFail("Changed original must not be replayed")
        } catch {
            guard case UploadError.sourceChanged = error else {
                XCTFail("Expected sourceChanged; received \(error)")
                return
            }
        }
        let counterRequest = try await RequestPreparer.prepare(
            HTTPRequestConfiguration(url: fixture.baseURL + "/upload-count?upload_counter=\(counter)"),
            context: .init(), decryptor: nil)
        let countResponse = try await complete(manager, prepared: counterRequest)
        XCTAssertEqual(try String(contentsOf: countResponse.bodyFileURL, encoding: .utf8), "0")
        let probe = try await RequestPreparer.prepare(
            HTTPRequestConfiguration(url: target), context: .init(), decryptor: nil)
        _ = try await complete(manager, prepared: probe)
        let verifiedCounterResponse = try await complete(manager, prepared: counterRequest)
        XCTAssertEqual(try String(contentsOf: verifiedCounterResponse.bodyFileURL, encoding: .utf8), "1")
        let cancellationPrepared = try await prepare(source: source, url: fixture.baseURL + "/delay?seconds=2")
        let cancellationIdentity = RequestIdentity(
            collectionID: UUID(), requestID: cancellationPrepared.configuration.id)
        let run = try await manager.start(identity: cancellationIdentity, prepared: cancellationPrepared)
        await manager.cancel(identity: cancellationIdentity, runID: run.id)
        var cancelled = false
        for await event in run.events { if case .cancelled = event { cancelled = true } }
        XCTAssertTrue(cancelled)
        await manager.shutdown()
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testBodyDroppingRedirectNeverRestoresUploadAcrossAutomaticOrManualChain() async throws {
        let fixture = try UploadFixture()
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("never-restore.bin")
        let bytes = Data([0, 255, 13, 10])
        let manager = try HTTPExecutionManager(bodyDirectory: root.appendingPathComponent("responses"))
        for status in [307, 308] {
            let secondURL = try fixture.redirect(status: status, to: fixture.baseURL + "/upload-echo")
            let firstURL = try fixture.redirect(status: 303, to: secondURL)
            for automatic in [true, false] {
                try bytes.write(to: source)
                let prepared = try await prepare(source: source, url: firstURL, follow: automatic)
                let identity = RequestIdentity(collectionID: UUID(), requestID: prepared.configuration.id)
                var response = try await complete(manager, prepared: prepared, identity: identity)
                if !automatic {
                    XCTAssertEqual(response.statusCode, 303)
                    try FileManager.default.removeItem(at: source)
                    let secondRun = try await manager.followRedirect(identity: identity, response: response)
                    response = try await completedResponse(from: secondRun)
                    XCTAssertEqual(response.statusCode, status)
                    let finalRun = try await manager.followRedirect(identity: identity, response: response)
                    response = try await completedResponse(from: finalRun)
                }
                XCTAssertEqual(response.effectiveMethod, "GET")
                XCTAssertEqual(response.finalURL.path, "/upload-echo")
                XCTAssertEqual(try Data(contentsOf: response.bodyFileURL), Data())
                XCTAssertFalse(
                    response.requestHeaders.contains { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame })
                XCTAssertEqual(response.snapshotCapture?.submitted.uploadBody?.files.first?.sha256, digest(bytes))
            }
        }
        await manager.shutdown()
    }

    func testReplacementTruncationGrowthAndMidStreamMutationAreDetected() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.bin")
        for mutation in 0..<4 {
            try Data(repeating: 0xAB, count: 131_072).write(to: source)
            let prepared = try await prepare(source: source)
            let upload = try XCTUnwrap(prepared.uploadBody)
            let stream = try upload.makeInputStream()
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            XCTAssertEqual(stream.read(&buffer, maxLength: buffer.count), buffer.count)
            switch mutation {
            case 0:
                let replacement = root.appendingPathComponent("replacement.bin")
                try Data(repeating: 0xCD, count: 131_072).write(to: replacement)
                XCTAssertEqual(Darwin.rename(replacement.path, source.path), 0)
            case 1:
                let handle = try FileHandle(forWritingTo: source)
                try handle.truncate(atOffset: 10)
                try handle.close()
            case 2:
                let handle = try FileHandle(forWritingTo: source)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([1]))
                try handle.close()
            default:
                let handle = try FileHandle(forWritingTo: source)
                try handle.seek(toOffset: 8000)
                try handle.write(contentsOf: Data([0]))
                try handle.close()
            }
            XCTAssertThrowsError(try read(stream))
            XCTAssertNil(upload.snapshotMetadata.files.first?.sha256)
            XCTAssertThrowsError(try upload.makeInputStream())
        }
    }

    func testSavedSnapshotRetainsMetadataWithoutOriginalFileOrUploadSidecar() async throws {
        let fixture = try UploadFixture()
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("snapshot-source.bin")
        let payload = Data("synthetic-upload-body-not-retained".utf8)
        try payload.write(to: source)
        let manager = try HTTPExecutionManager(bodyDirectory: root.appendingPathComponent("responses"))
        let vault = SecretVault(keyStore: UploadTestKeyStore())
        let envelope = try await vault.encrypt("resolved-sensitive-form-value")
        let prepared = try await RequestPreparer.prepare(
            HTTPRequestConfiguration(
                method: "POST", url: fixture.baseURL + "/large?bytes=1", bodyEnabled: true, bodyKind: .multipart,
                multipartParts: [
                    HTTPMultipartPart(name: "templated", text: "{{value}}"),
                    HTTPMultipartPart(name: "literal", text: "literal form value"),
                    HTTPMultipartPart(name: "file", kind: .file, file: HTTPFileReference(path: source.path)),
                ], variables: ["value": .encrypted(envelope)]),
            context: .init(), decryptor: vault)
        let identity = RequestIdentity(collectionID: UUID(), requestID: prepared.configuration.id)
        let response = try await complete(manager, prepared: prepared, identity: identity)
        let lease = try await manager.acquireBodyLease(for: response)
        let snapshots = root.appendingPathComponent("snapshots")
        let store = SnapshotStore(rootURL: snapshots, vault: vault)
        let summary = try await store.save(
            response: response,
            source: SnapshotSource(identity: identity, collectionName: "Synthetic", requestName: "Upload"),
            name: "Metadata only", bodyLease: lease)
        try FileManager.default.removeItem(at: source)
        let reopened = try await store.open(id: summary.id)
        XCTAssertNil(reopened.contextError)
        XCTAssertEqual(reopened.template.bodyKind, .multipart)
        XCTAssertEqual(reopened.template.uploadBody?.files.first?.sha256, digest(payload))
        XCTAssertNil(reopened.context?.preparation.submitted.body)
        XCTAssertTrue(try XCTUnwrap(reopened.context?.preparation.submitted.uploadBody).binaryOmitted)
        XCTAssertEqual(
            reopened.context?.preparation.submitted.uploadBody?.parts?.first?.text, "resolved-sensitive-form-value")
        XCTAssertEqual(
            reopened.context?.preparation.submitted.uploadBody?.parts?.dropFirst().first?.text, "literal form value")
        XCTAssertEqual(reopened.context?.preparation.submitted.uploadBody?.parts?.last?.fileIndex, 0)
        XCTAssertEqual(reopened.template.multipartTemplateParts?.first?.text, "{{value}}")
        XCTAssertNil(reopened.template.uploadBody?.parts)
        let directory = snapshots.appendingPathComponent(summary.id.uuidString)
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
            ["snapshot.json", "response.body"])
        let context = try JSONEncoder().encode(try XCTUnwrap(reopened.context))
        XCTAssertFalse(String(decoding: context, as: UTF8.self).contains(source.path))
        XCTAssertFalse(String(decoding: context, as: UTF8.self).contains("synthetic-upload-body-not-retained"))
        let documentData = try Data(contentsOf: directory.appendingPathComponent("snapshot.json"))
        XCTAssertFalse(String(decoding: documentData, as: UTF8.self).contains("resolved-sensitive-form-value"))
        XCTAssertFalse(String(decoding: documentData, as: UTF8.self).contains(source.path))
        XCTAssertFalse(String(decoding: documentData, as: UTF8.self).contains("synthetic-upload-body-not-retained"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: documentData) as? [String: Any])
        XCTAssertEqual(document["version"] as? Int, 2)
        await manager.releaseBodyLease(lease)
        await manager.shutdown()
    }

    private func prepare(source: URL, url: String = "http://127.0.0.1/unused", follow: Bool = false) async throws
        -> PreparedHTTPRequest
    {
        try await RequestPreparer.prepare(
            HTTPRequestConfiguration(
                method: "POST", url: url, bodyEnabled: true, bodyKind: .rawFile,
                rawFile: HTTPFileReference(path: source.path), options: HTTPOptions(followRedirects: follow)),
            context: .init(), decryptor: nil)
    }

    private func complete(
        _ manager: HTTPExecutionManager, prepared: PreparedHTTPRequest, identity: RequestIdentity? = nil
    ) async throws -> HTTPResponseRecord {
        let run = try await manager.start(
            identity: identity ?? RequestIdentity(collectionID: UUID(), requestID: prepared.configuration.id),
            prepared: prepared)
        return try await completedResponse(from: run)
    }

    private func completedResponse(from run: HTTPRun) async throws -> HTTPResponseRecord {
        for await event in run.events {
            if case .completed(let response) = event { return response }
            if case .failed(let message) = event {
                throw NSError(domain: "UploadTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        throw NSError(domain: "UploadTests", code: 2)
    }

    private func read(_ stream: InputStream) throws -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? UploadError.readFailed }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "postie-upload-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private struct UploadTestKeyStore: ApplicationKeyStore {
    func loadKey() throws -> Data? { Data(repeating: 0x42, count: 32) }
    func createKey(_ proposedKey: Data) throws -> Data { proposedKey }
}

private final class UploadFixture {
    private let process: Process
    private let termination = DispatchSemaphore(value: 0)
    let baseURL: String

    init() throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = Bundle(for: UploadTests.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("PostieHTTPFixture")
        process.arguments = ["--port", "0"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let termination = self.termination
        process.terminationHandler = { _ in termination.signal() }
        self.process = process
        try process.run()
        var line = Data()
        while let byte = try pipe.fileHandleForReading.read(upToCount: 1)?.first, byte != 10 { line.append(byte) }
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Int])
        baseURL = "http://127.0.0.1:\(try XCTUnwrap(value["port"]))"
    }

    func redirect(status: Int, to destination: String) throws -> String {
        var components = try XCTUnwrap(URLComponents(string: baseURL + "/redirect"))
        components.queryItems = [
            URLQueryItem(name: "status", value: String(status)), URLQueryItem(name: "to", value: destination),
        ]
        return try XCTUnwrap(components.url?.absoluteString)
    }

    deinit {
        if process.isRunning { process.terminate() }
        if termination.wait(timeout: .now() + .seconds(2)) == .timedOut, process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            _ = termination.wait(timeout: .now() + .seconds(2))
        }
    }
}
