import Foundation
import XCTest
@testable import PostieCore

final class EncryptedDocumentTests: XCTestCase {
    func testGlobalsRewriteOnlyEncryptedVariableValuesAndPreserveUnknownData() throws {
        let keyID = UUID()
        let originalEnvelope: [String: Any] = [
            "version": 1,
            "combined": ciphertext("old-global-ciphertext"),
            "extension": ["preserved": true],
        ]
        let unknownEnvelope = try envelopeObject(SecretEnvelope(combined: ciphertext("unchanged nested ciphertext")))
        let input = try documentData([
            "formatVersion": 1,
            "variables": [
                "plain": "{{value}}",
                "secret": originalEnvelope,
            ],
            "httpOptions": ["extension": ["token": unknownEnvelope]],
            "futureField": ["retained": [1, "two", false]],
        ])

        XCTAssertEqual(
            try EncryptedDocument.envelopes(in: input, kind: .globals),
            [SecretEnvelope(combined: ciphertext("old-global-ciphertext"))]
        )
        let rewritten = try EncryptedDocument.replacingEnvelopes(
            in: input,
            kind: .globals,
            with: [SecretEnvelope(version: 2, combined: ciphertext("new-global-ciphertext"), keyID: keyID)]
        )
        let result = try documentObject(rewritten)
        let variables = try XCTUnwrap(result["variables"] as? [String: Any])
        let secret = try XCTUnwrap(variables["secret"] as? [String: Any])
        let options = try XCTUnwrap(result["httpOptions"] as? [String: Any])

        XCTAssertEqual(variables["plain"] as? String, "{{value}}")
        XCTAssertEqual(secret["version"] as? Int, 2)
        XCTAssertEqual(secret["combined"] as? String, ciphertext("new-global-ciphertext"))
        XCTAssertEqual(secret["keyID"] as? String, keyID.uuidString)
        try assertJSONEqual(secret["extension"], to: ["preserved": true])
        try assertJSONEqual(options, to: ["extension": ["token": unknownEnvelope]])
        try assertJSONEqual(result["futureField"], to: ["retained": [1, "two", false]])
    }

    func testVersionTwoEnvelopeRequiresAndReturnsItsUUIDKeyID() throws {
        let keyID = UUID()
        let input = try documentData([
            "formatVersion": 1,
            "variables": [
                "secret": [
                    "version": 2,
                    "keyID": keyID.uuidString,
                    "combined": ciphertext("version-two-ciphertext"),
                ]
            ],
        ])

        XCTAssertEqual(
            try EncryptedDocument.envelopes(in: input, kind: .globals),
            [SecretEnvelope(version: 2, combined: ciphertext("version-two-ciphertext"), keyID: keyID)]
        )
    }

    func testCollectionRewritesVariablesAndStructuredAuthenticationOnly() throws {
        let input = try documentData([
            "formatVersion": 1,
            "name": "Collection",
            "requests": [],
            "variables": [
                "zeta": ["version": 1, "combined": ciphertext("zeta-ciphertext")],
                "alpha": ["version": 1, "combined": ciphertext("alpha-ciphertext")],
            ],
            "authentication": [
                "kind": "apiKey",
                "password": ["version": 1, "combined": ciphertext("password-ciphertext")],
                "token": ["version": 1, "combined": ciphertext("token-ciphertext")],
                "apiKey": ["version": 1, "combined": ciphertext("api-key-ciphertext")],
                "extension": [
                    "token": ["version": 1, "combined": ciphertext("untouched-auth-extension")]
                ],
            ],
            "headers": [["name": "Authorization", "value": ["combined": ciphertext("untouched-header")]]],
        ])

        XCTAssertEqual(
            try EncryptedDocument.envelopes(in: input, kind: .collection).map(\.combined),
            [
                ciphertext("alpha-ciphertext"),
                ciphertext("zeta-ciphertext"),
                ciphertext("password-ciphertext"),
                ciphertext("token-ciphertext"),
                ciphertext("api-key-ciphertext"),
            ]
        )
        let replacements = ["alpha", "zeta", "password", "token", "api-key"].map {
            SecretEnvelope(combined: ciphertext("replacement-\($0)"))
        }
        let rewritten = try EncryptedDocument.replacingEnvelopes(in: input, kind: .collection, with: replacements)
        let result = try documentObject(rewritten)
        let variables = try XCTUnwrap(result["variables"] as? [String: Any])
        let authentication = try XCTUnwrap(result["authentication"] as? [String: Any])

        XCTAssertEqual(
            (variables["alpha"] as? [String: Any])?["combined"] as? String,
            ciphertext("replacement-alpha")
        )
        XCTAssertEqual(
            (variables["zeta"] as? [String: Any])?["combined"] as? String,
            ciphertext("replacement-zeta")
        )
        XCTAssertEqual(
            (authentication["password"] as? [String: Any])?["combined"] as? String,
            ciphertext("replacement-password")
        )
        XCTAssertEqual(
            (authentication["token"] as? [String: Any])?["combined"] as? String,
            ciphertext("replacement-token")
        )
        XCTAssertEqual(
            (authentication["apiKey"] as? [String: Any])?["combined"] as? String,
            ciphertext("replacement-api-key")
        )
        try assertJSONEqual(
            authentication["extension"],
            to: ["token": ["version": 1, "combined": ciphertext("untouched-auth-extension")]]
        )
        try assertJSONEqual(
            result["headers"],
            to: [["name": "Authorization", "value": ["combined": ciphertext("untouched-header")]]]
        )
    }

    func testRequestDoesNotRewriteBodyOrUnknownNestedEnvelopeLikeObjects() throws {
        let unknownEnvelope = try envelopeObject(SecretEnvelope(combined: ciphertext("untouched-unknown")))
        let input = try documentData([
            "formatVersion": 2,
            "variables": ["requestSecret": "plain"],
            "authentication": [
                "kind": "bearer",
                "token": ["version": 1, "combined": ciphertext("request-token")],
            ],
            "body": "{\"authentication\":{\"token\":\"body-literal\"}}",
            "options": ["extension": unknownEnvelope],
            "multipartParts": [["body": unknownEnvelope]],
        ])

        let rewritten = try EncryptedDocument.replacingEnvelopes(
            in: input,
            kind: .request,
            with: [SecretEnvelope(combined: ciphertext("replacement-request-token"))]
        )
        let result = try documentObject(rewritten)
        let authentication = try XCTUnwrap(result["authentication"] as? [String: Any])
        let options = try XCTUnwrap(result["options"] as? [String: Any])
        let multipart = try XCTUnwrap((result["multipartParts"] as? [[String: Any]])?.first)

        XCTAssertEqual(
            (authentication["token"] as? [String: Any])?["combined"] as? String,
            ciphertext("replacement-request-token")
        )
        XCTAssertEqual(result["body"] as? String, "{\"authentication\":{\"token\":\"body-literal\"}}")
        try assertJSONEqual(options["extension"], to: unknownEnvelope)
        try assertJSONEqual(multipart["body"], to: unknownEnvelope)
    }

    func testSnapshotRewritesOnlyEncryptedContextAndLeavesTemplateAuthenticationAlone() throws {
        let templateEnvelope = try envelopeObject(SecretEnvelope(combined: ciphertext("template-authentication")))
        let input = try documentData([
            "version": 2,
            "preparationVersion": 2,
            "encryptedContext": ["version": 1, "combined": ciphertext("snapshot-context")],
            "template": ["authentication": ["token": templateEnvelope]],
            "response": ["bodyByteCount": 0],
        ])

        XCTAssertEqual(
            try EncryptedDocument.envelopes(in: input, kind: .snapshot),
            [SecretEnvelope(combined: ciphertext("snapshot-context"))]
        )
        let rewritten = try EncryptedDocument.replacingEnvelopes(
            in: input,
            kind: .snapshot,
            with: [SecretEnvelope(combined: ciphertext("replacement-snapshot-context"))]
        )
        let result = try documentObject(rewritten)
        let template = try XCTUnwrap(result["template"] as? [String: Any])

        XCTAssertEqual(
            (result["encryptedContext"] as? [String: Any])?["combined"] as? String,
            ciphertext("replacement-snapshot-context")
        )
        try assertJSONEqual(template, to: ["authentication": ["token": templateEnvelope]])
        try assertJSONEqual(result["response"], to: ["bodyByteCount": 0])
    }

    func testAutomationRewritesOnlyTopLevelToken() throws {
        let input = try documentData([
            "formatVersion": 1,
            "token": ["version": 1, "combined": ciphertext("automation-token")],
            "metadata": ["token": ["version": 1, "combined": ciphertext("untouched-metadata")]],
        ])

        let rewritten = try EncryptedDocument.replacingEnvelopes(
            in: input,
            kind: .automation,
            with: [SecretEnvelope(combined: ciphertext("replacement-automation-token"))]
        )
        let result = try documentObject(rewritten)
        let metadata = try XCTUnwrap(result["metadata"] as? [String: Any])

        XCTAssertEqual(
            (result["token"] as? [String: Any])?["combined"] as? String,
            ciphertext("replacement-automation-token")
        )
        try assertJSONEqual(
            metadata,
            to: ["token": ["version": 1, "combined": ciphertext("untouched-metadata")]]
        )
    }

    func testMalformedShapesAndUnsupportedVersionsAreRejected() throws {
        XCTAssertThrowsError(try EncryptedDocument.envelopes(in: Data("{".utf8), kind: .globals)) {
            XCTAssertEqual($0 as? EncryptedDocumentError, .invalidJSON)
        }

        let unsupportedDocument = try documentData(["formatVersion": 3, "variables": [:]])
        XCTAssertThrowsError(try EncryptedDocument.envelopes(in: unsupportedDocument, kind: .globals)) {
            XCTAssertEqual($0 as? EncryptedDocumentError, .unsupportedDocumentVersion(3))
        }

        let malformedVariables = try documentData(["formatVersion": 1, "variables": ["secret": 42]])
        XCTAssertThrowsError(try EncryptedDocument.envelopes(in: malformedVariables, kind: .globals)) {
            XCTAssertEqual($0 as? EncryptedDocumentError, .malformedEnvelope)
        }

        let unsupportedEnvelope = try documentData([
            "formatVersion": 1,
            "variables": ["secret": ["version": 3, "combined": "future"]],
        ])
        XCTAssertThrowsError(try EncryptedDocument.envelopes(in: unsupportedEnvelope, kind: .globals)) {
            XCTAssertEqual($0 as? EncryptedDocumentError, .unsupportedEnvelopeVersion(3))
        }

        let malformedV2 = try documentData([
            "formatVersion": 1,
            "variables": ["secret": ["version": 2, "combined": "missing-key-id"]],
        ])
        XCTAssertThrowsError(try EncryptedDocument.envelopes(in: malformedV2, kind: .globals)) {
            XCTAssertEqual($0 as? EncryptedDocumentError, .malformedEnvelope)
        }

        let malformedCiphertext = try documentData([
            "formatVersion": 1,
            "variables": ["secret": ["version": 1, "combined": "not-base64"]],
        ])
        XCTAssertThrowsError(try EncryptedDocument.envelopes(in: malformedCiphertext, kind: .globals)) {
            XCTAssertEqual($0 as? EncryptedDocumentError, .malformedEnvelope)
        }

        let noncanonicalKeyID = try documentData([
            "formatVersion": 1,
            "variables": [
                "secret": [
                    "version": 2,
                    "keyID": UUID().uuidString.lowercased(),
                    "combined": ciphertext("valid-ciphertext"),
                ]
            ],
        ])
        XCTAssertThrowsError(try EncryptedDocument.envelopes(in: noncanonicalKeyID, kind: .globals)) {
            XCTAssertEqual($0 as? EncryptedDocumentError, .malformedEnvelope)
        }

        let inconsistentSnapshotVersion = try documentData([
            "version": 2,
            "preparationVersion": 1,
            "encryptedContext": ["version": 1, "combined": ciphertext("context")],
        ])
        XCTAssertThrowsError(try EncryptedDocument.envelopes(in: inconsistentSnapshotVersion, kind: .snapshot)) {
            XCTAssertEqual($0 as? EncryptedDocumentError, .malformedDocument)
        }

        let replacementCountMismatch = try documentData([
            "version": 1,
            "preparationVersion": 1,
            "encryptedContext": ["version": 1, "combined": ciphertext("context")],
        ])
        XCTAssertThrowsError(
            try EncryptedDocument.replacingEnvelopes(in: replacementCountMismatch, kind: .snapshot, with: [])
        ) {
            XCTAssertEqual($0 as? EncryptedDocumentError, .replacementCountMismatch(expected: 1, actual: 0))
        }
    }

    private func envelopeObject(_ envelope: SecretEnvelope) throws -> [String: Any] {
        let data = try JSONEncoder().encode(envelope)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func documentData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func ciphertext(_ label: String) -> String {
        var bytes = Array(label.utf8)
        if bytes.count < 28 {
            bytes.append(contentsOf: repeatElement(0, count: 28 - bytes.count))
        }
        return Data(bytes).base64EncodedString()
    }

    private func documentObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func assertJSONEqual(
        _ actual: Any?,
        to expected: Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let actualData = try JSONSerialization.data(
            withJSONObject: XCTUnwrap(actual),
            options: [.sortedKeys]
        )
        let expectedData = try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys])

        XCTAssertEqual(actualData, expectedData, file: file, line: line)
    }
}
