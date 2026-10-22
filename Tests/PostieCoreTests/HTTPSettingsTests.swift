import Foundation
import XCTest
@testable import PostieCore

final class HTTPSettingsTests: XCTestCase {
    func testOverridesResolveAgainstDefaultsAndPreserveExplicitUnlimitedValues() {
        let defaults = HTTPOptions(
            followRedirects: false,
            inactivityTimeout: 17,
            overallTimeout: 23,
            maximumResponseBytes: 512
        )

        XCTAssertEqual(HTTPOptionsOverrides().resolve(against: defaults), defaults)

        let partial = HTTPOptionsOverrides(
            followRedirects: true,
            inactivityTimeout: 5,
            maximumResponseBytes: 0,
            overallTimeoutIsUnlimited: true
        )
        XCTAssertEqual(
            partial.resolve(against: defaults),
            HTTPOptions(followRedirects: true, inactivityTimeout: 5, overallTimeout: nil, maximumResponseBytes: 0)
        )

        let explicit = HTTPOptionsOverrides.explicit(
            HTTPOptions(followRedirects: true, inactivityTimeout: 9, overallTimeout: nil, maximumResponseBytes: nil)
        )
        XCTAssertEqual(
            explicit.resolve(against: defaults),
            HTTPOptions(followRedirects: true, inactivityTimeout: 9, overallTimeout: nil, maximumResponseBytes: nil)
        )
    }

    func testGlobalOptionsFallBackWhenMissingAndPersistWithUnknownData() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CollectionStore(rootURL: root)
        let globalsURL = root.appendingPathComponent("globals.json")

        var globals = try readObject(at: globalsURL)
        globals.removeValue(forKey: "httpOptions")
        globals["futureGlobalsData"] = ["retained": true]
        try writeObject(globals, to: globalsURL)

        let fallback = try await store.load()
        XCTAssertEqual(fallback.globalOptions, HTTPOptions())
        XCTAssertFalse(fallback.globalOptionsAreReadOnly)

        let saved = HTTPOptions(
            followRedirects: true, inactivityTimeout: 45.5, overallTimeout: nil, maximumResponseBytes: 0)
        try await store.saveGlobalOptions(saved)

        let loaded = try await store.load()
        XCTAssertEqual(loaded.globalOptions, saved)
        XCTAssertFalse(loaded.globalOptionsAreReadOnly)

        globals = try readObject(at: globalsURL)
        XCTAssertEqual((globals["futureGlobalsData"] as? [String: Bool])?["retained"], true)
        var options = try XCTUnwrap(globals["httpOptions"] as? [String: Any])
        options["futureOptionData"] = ["retained": true]
        globals["httpOptions"] = options
        try writeObject(globals, to: globalsURL)

        try await store.saveGlobalOptions(saved)
        globals = try readObject(at: globalsURL)
        options = try XCTUnwrap(globals["httpOptions"] as? [String: Any])
        XCTAssertTrue(options["overallTimeout"] is NSNull)
        XCTAssertEqual(options["maximumResponseBytes"] as? Int, 0)
        XCTAssertEqual((options["futureOptionData"] as? [String: Bool])?["retained"], true)
    }

    func testMalformedGlobalOptionsAreReadOnlyAndVariableSavesPreserveThem() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CollectionStore(rootURL: root)
        let globalsURL = root.appendingPathComponent("globals.json")
        let malformedOptions: [String: Any] = [
            "followRedirects": true,
            "inactivityTimeout": 0,
            "overallTimeout": NSNull(),
            "maximumResponseBytes": 40,
        ]
        var globals = try readObject(at: globalsURL)
        globals["httpOptions"] = malformedOptions
        try writeObject(globals, to: globalsURL)
        let malformedFile = try Data(contentsOf: globalsURL)

        let loaded = try await store.load()
        XCTAssertEqual(loaded.globalOptions, HTTPOptions())
        XCTAssertFalse(loaded.globalVariablesAreReadOnly)
        XCTAssertTrue(loaded.globalOptionsAreReadOnly)
        XCTAssertTrue(loaded.issues.contains { $0.id.hasPrefix("store:globals-malformed") })

        do {
            try await store.saveGlobalOptions(HTTPOptions(followRedirects: true))
            XCTFail("Malformed global HTTP settings must remain read-only")
        } catch CollectionStoreError.ioFailure {
        }
        XCTAssertEqual(try Data(contentsOf: globalsURL), malformedFile)

        try await store.saveGlobalVariables(["name": .plain("value")])
        globals = try readObject(at: globalsURL)
        let preservedOptions = try XCTUnwrap(globals["httpOptions"] as? NSDictionary)
        XCTAssertTrue(preservedOptions.isEqual(malformedOptions))
        XCTAssertEqual((globals["variables"] as? [String: String])?["name"], "value")
    }

    func testInvalidGlobalOptionsAreRejectedBeforePersistence() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CollectionStore(rootURL: root)

        let invalidOptions = [
            HTTPOptions(inactivityTimeout: 0),
            HTTPOptions(inactivityTimeout: .infinity),
            HTTPOptions(overallTimeout: .nan),
            HTTPOptions(maximumResponseBytes: -1),
        ]
        for options in invalidOptions {
            do {
                try await store.saveGlobalOptions(options)
                XCTFail("Invalid global HTTP settings must be rejected")
            } catch CollectionStoreError.ioFailure {
            }
        }
    }

    func testRequestOverridesPersistAndLegacyConcreteOptionsRemainExplicit() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CollectionStore(rootURL: root)
        let collection = try await store.createCollection(name: "Settings")
        let explicitOptions = HTTPOptions(
            followRedirects: true, inactivityTimeout: 44, overallTimeout: nil, maximumResponseBytes: 77)
        let overrides = HTTPOptionsOverrides(
            followRedirects: false,
            overallTimeout: 12,
            responseSizeIsUnlimited: true
        )
        let request = HTTPRequestConfiguration(
            name: "Legacy settings",
            url: "https://example.test/path?raw=%2F",
            query: [HTTPField(name: "added", value: "two")],
            options: explicitOptions,
            optionOverrides: overrides
        )
        try await store.createRequest(request, in: collection.id)

        let loaded = try await store.load()
        let reloaded = try XCTUnwrap(loaded.collections.first?.requests.first)
        XCTAssertEqual(reloaded.options, explicitOptions)
        XCTAssertEqual(reloaded.optionOverrides, overrides)
        XCTAssertEqual(reloaded.url, "https://example.test/path")
        XCTAssertEqual(reloaded.query.map(\.name), ["raw", "added"])
        XCTAssertEqual(reloaded.query.first?.queryEncoding?.encodedValue, "%2F")

        let stored = try readObject(at: requestURL(root, collection.id, request.id))
        let storedOverrides = try XCTUnwrap(stored["optionOverrides"] as? [String: Any])
        XCTAssertTrue(storedOverrides["inactivityTimeout"] is NSNull)
        XCTAssertTrue(storedOverrides["maximumResponseBytes"] is NSNull)

        var noOverrides = reloaded
        noOverrides.optionOverrides = nil
        noOverrides.name = "Legacy explicit settings"
        try await store.saveRequest(noOverrides, in: collection.id)
        let saved = try readObject(at: requestURL(root, collection.id, request.id))
        XCTAssertNil(saved["optionOverrides"])
        let legacyWorkspace = try await store.load()
        let legacyReload = try XCTUnwrap(legacyWorkspace.collections.first?.requests.first)
        XCTAssertNil(legacyReload.optionOverrides)
        XCTAssertEqual(legacyReload.options, explicitOptions)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PostieHTTPSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func readObject(at url: URL) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(value as? [String: Any])
    }

    private func writeObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func requestURL(_ root: URL, _ collectionID: UUID, _ requestID: UUID) -> URL {
        root.appendingPathComponent("collections", isDirectory: true)
            .appendingPathComponent(collectionID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("\(requestID.uuidString.lowercased()).json")
    }
}
