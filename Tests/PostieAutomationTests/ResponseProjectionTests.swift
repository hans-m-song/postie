import Foundation
import XCTest
import PostieAutomation
import PostieCore

final class ResponseProjectionTests: XCTestCase {
    func testUnusedFrozenSecretIsRedactedFromBodyAndHeaders() throws {
        let original = capture(secret: "referenced-secret")
        var document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        let input = SnapshotInput(value: "freshness", scope: .request, isSecret: true)
        let encodedInput = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input))
        document["redactionInputs"] = ["inputs": ["test": encodedInput], "isComplete": true]
        let frozen = try JSONDecoder().decode(
            SnapshotPreparationCapture.self, from: JSONSerialization.data(withJSONObject: document))
        let sanitizer = SecretRetemplating(capture: frozen)

        XCTAssertEqual(sanitizer.sanitize("freshness"), "{{test}}")
        XCTAssertNil(frozen.referencedInputs["test"])
        let data = Data("{\"freshness\":true}".utf8)
        let file = try bodyFile(data)
        defer { try? FileManager.default.removeItem(at: file) }
        let response = responseRecord(
            headers: [HTTPField(name: "X-Echo", value: "freshness")],
            bodyByteCount: Int64(data.count), capture: frozen
        )
        let projection = object(ResponseProjection.mcpAllowed(response: response, bodyURL: file))
        XCTAssertEqual(string(object(projection["body"])["content"]), "{\"{{test}}\":true}")
        XCTAssertEqual(headerFields(projection["headers"])["x-echo"], "{{test}}")
    }

    func testIncompleteUnusedSecretCaptureWithholdsRedactedBodyAndHeaders() throws {
        let original = capture(secret: "referenced-secret")
        var document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        document["redactionInputs"] = ["inputs": [:], "isComplete": false]
        let frozen = try JSONDecoder().decode(
            SnapshotPreparationCapture.self, from: JSONSerialization.data(withJSONObject: document))
        let data = Data("freshness".utf8)
        let file = try bodyFile(data)
        defer { try? FileManager.default.removeItem(at: file) }
        let response = responseRecord(
            headers: [HTTPField(name: "X-Echo", value: "freshness")],
            bodyByteCount: Int64(data.count), capture: frozen
        )

        let redacted = object(ResponseProjection.mcpAllowed(response: response, bodyURL: file))
        XCTAssertEqual(redacted["body"], .null)
        XCTAssertEqual(bool(redacted["bodyWithheld"]), true)
        XCTAssertTrue(headerFields(redacted["headers"]).isEmpty)
        let raw = object(ResponseProjection.mcpUnredacted(response: response, bodyURL: file))
        XCTAssertEqual(string(object(raw["body"])["content"]), "freshness")
    }

    func testReferencedSecretReplacementWinsOverUnusedAlias() {
        let original = capture(secret: "same-secret")
        let frozen = SnapshotPreparationCapture(
            template: original.template,
            referencedInputs: original.referencedInputs,
            authentication: original.authentication,
            submitted: original.submitted,
            redactionInputs: SnapshotRedactionCapture(
                inputs: ["alias": SnapshotInput(value: "same-secret", scope: .request, isSecret: true)],
                isComplete: true
            )
        )
        XCTAssertEqual(SecretRetemplating(capture: frozen).sanitize("same-secret"), "{{token}}")
    }

    func testAutomationJSONUsesOrdinaryJSONValues() throws {
        let value: AutomationJSON = .object([
            "object": .object(["enabled": .bool(true)]),
            "array": .array([.number(Decimal(string: "2.5")!), .null]),
            "string": .string("text"),
        ])

        let encoded = try JSONEncoder().encode(value)
        let decodedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let nested = try XCTUnwrap(decodedObject["object"] as? [String: Any])
        XCTAssertEqual(nested["enabled"] as? Bool, true)
        let array = try XCTUnwrap(decodedObject["array"] as? [Any])
        XCTAssertEqual(array.count, 2)
        XCTAssertEqual(array.first as? Double, 2.5)
        XCTAssertNotNil(array.last as? NSNull)
        XCTAssertEqual(decodedObject["string"] as? String, "text")
        XCTAssertEqual(try JSONDecoder().decode(AutomationJSON.self, from: encoded), value)
    }

    func testBlockedProjectionReturnsNormalizedMetadataAndSanitizedRedirectLocations() throws {
        let context = capture(secret: "echo-token")
        let requestURL = try XCTUnwrap(URL(string: "https://example.test/start"))
        let redirect = HTTPRedirect(
            statusCode: 302,
            url: requestURL,
            nextURL: try XCTUnwrap(URL(string: "https://other.test/next")),
            method: "POST",
            nextMethod: "GET",
            requestHeaders: [],
            responseHeaders: [
                HTTPField(name: "Location", value: "../next?key=echo-token"),
                HTTPField(name: "Set-Cookie", value: "session=echo-token"),
            ]
        )
        let response = responseRecord(
            url: requestURL,
            statusCode: 200,
            headers: [
                HTTPField(name: "Content-Type", value: "Application/JSON; charset=\"UTF-8\""),
                HTTPField(name: "Content-Length", value: "007"),
                HTTPField(name: "Cache-Control", value: "max-age=00030, vendor=echo-token"),
                HTTPField(name: "Location", value: "https://user:password@example.test/final?key=echo-token"),
                HTTPField(name: "Set-Cookie", value: "session=echo-token"),
            ],
            redirects: [redirect],
            bodyByteCount: 456,
            duration: 1.25,
            capture: context
        )

        let projection = object(ResponseProjection.mcpBlocked(response: response))
        let headers = headerFields(projection["headers"])
        let hops = array(projection["redirects"])
        let hop = object(try XCTUnwrap(hops.first))
        let redirectHeaders = headerFields(hop["headers"])

        XCTAssertEqual(string(projection["state"]), "completed")
        XCTAssertEqual(integer(projection["statusCode"]), 200)
        XCTAssertEqual(integer(projection["bodyByteCount"]), 456)
        XCTAssertEqual(bool(projection["bodyWithheld"]), true)
        XCTAssertEqual(projection["body"], AutomationJSON.null)
        XCTAssertEqual(headers["Content-Type"], "application/json; charset=utf-8")
        XCTAssertEqual(headers["Content-Length"], "7")
        XCTAssertEqual(headers["Cache-Control"], "max-age=30")
        XCTAssertEqual(headers["Location"], "https://example.test/final?key={{token}}")
        XCTAssertNil(headers["Set-Cookie"])
        XCTAssertEqual(integer(hop["index"]), 0)
        XCTAssertEqual(integer(hop["statusCode"]), 302)
        XCTAssertEqual(string(hop["method"]), "POST")
        XCTAssertEqual(string(hop["nextMethod"]), "GET")
        XCTAssertEqual(bool(hop["originChanged"]), true)
        XCTAssertEqual(redirectHeaders["Location"], "../next?key={{token}}")
        XCTAssertNil(redirectHeaders["Set-Cookie"])
    }

    func testOngoingRedirectProjectionSeparatesBlockedAllowedAndRawViews() throws {
        let context = capture(secret: "echo-token")
        let redirect = HTTPRedirect(
            statusCode: 302,
            url: try XCTUnwrap(URL(string: "https://user:password@example.test/start?token=echo-token")),
            nextURL: try XCTUnwrap(URL(string: "https://other.test/next?token=echo-token")),
            method: "POST",
            nextMethod: "GET",
            requestHeaders: [],
            responseHeaders: [
                HTTPField(name: "Content-Type", value: "Application/JSON; charset=\"UTF-8\""),
                HTTPField(name: "X-Echo", value: "echo-token"),
                HTTPField(name: "Location", value: "https://user:password@example.test/final?key=echo-token"),
            ]
        )

        let blocked = object(try XCTUnwrap(array(ResponseProjection.mcpRedirects([redirect], context: context)).first))
        let allowed = object(
            try XCTUnwrap(array(ResponseProjection.mcpRedirects([redirect], context: context, allowed: true)).first))
        let unredacted = object(
            try XCTUnwrap(array(ResponseProjection.mcpRedirects([redirect], context: context, mode: .unredacted)).first)
        )
        let raw = object(try XCTUnwrap(array(ResponseProjection.cliRedirects([redirect])).first))

        XCTAssertEqual(
            headerFields(blocked["headers"]),
            [
                "Content-Type": "application/json; charset=utf-8",
                "Location": "https://example.test/final?key={{token}}",
            ])
        XCTAssertEqual(
            headerFields(allowed["headers"]),
            [
                "content-type": "Application/JSON; charset=\"UTF-8\"",
                "x-echo": "{{token}}",
                "Location": "https://example.test/final?key={{token}}",
            ])
        XCTAssertEqual(
            headerFields(raw["headers"]),
            [
                "Content-Type": "Application/JSON; charset=\"UTF-8\"",
                "X-Echo": "echo-token",
                "Location": "https://user:password@example.test/final?key=echo-token",
            ])
        XCTAssertEqual(string(unredacted["url"]), "https://user:password@example.test/start?token=echo-token")
        XCTAssertEqual(string(unredacted["nextURL"]), "https://other.test/next?token=echo-token")
        XCTAssertEqual(
            headerFields(unredacted["headers"])["Location"], "https://user:password@example.test/final?key=echo-token")
    }

    func testAllowProjectionRetemplatesKnownURLAndJSONEscapes() throws {
        let secret = "secret/value"
        let body = #"json="secret\/value" url=secret%2fvalue"#
        let file = try bodyFile(Data(body.utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        let response = responseRecord(
            headers: [HTTPField(name: "X-Echo", value: "secret%2Fvalue")],
            bodyByteCount: Int64(body.utf8.count),
            capture: capture(secret: secret)
        )

        let projection = object(ResponseProjection.mcpAllowed(response: response, bodyURL: file))
        let bodyObject = object(projection["body"])

        XCTAssertEqual(bool(projection["bodyWithheld"]), false)
        XCTAssertEqual(string(bodyObject["encoding"]), "utf-8")
        XCTAssertEqual(string(bodyObject["content"]), #"json="{{token}}" url={{token}}"#)
        XCTAssertEqual(headerFields(projection["headers"])["x-echo"], "{{token}}")
    }

    func testOverlappingSecretsReplaceTheirCompleteUnion() {
        let base = capture(secret: "abc")
        let context = SnapshotPreparationCapture(
            template: base.template,
            referencedInputs: [
                "first": SnapshotInput(value: "abc", scope: .request, isSecret: true),
                "second": SnapshotInput(value: "bcde", scope: .request, isSecret: true),
            ],
            authentication: base.authentication,
            submitted: base.submitted
        )

        XCTAssertEqual(SecretRetemplating(capture: context).sanitize("abcde"), "{{second}}")
    }

    func testDenseSecretMatchesFailClosedAtBoundedWorkLimit() {
        let sanitizer = SecretRetemplating(capture: capture(secret: "x"))
        let denseText = String(repeating: "x", count: 65_537)

        XCTAssertEqual(sanitizer.sanitize(denseText), SecretRetemplating.redaction)
    }

    func testSanitizedOutputExpansionFailsClosedAtOneMiB() {
        let base = capture(secret: "x")
        let longName = String(repeating: "a", count: 1_048_573)
        let context = SnapshotPreparationCapture(
            template: base.template,
            referencedInputs: [longName: SnapshotInput(value: "x", scope: .request, isSecret: true)],
            authentication: base.authentication,
            submitted: base.submitted
        )

        XCTAssertEqual(SecretRetemplating(capture: context).sanitize("x"), SecretRetemplating.redaction)
    }

    func testMissingFrozenContextWithholdsAllowedBodyAndDoesNotUseResponseFallback() throws {
        let body = "echo secret"
        let file = try bodyFile(Data(body.utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        let url = try XCTUnwrap(URL(string: "https://example.test/start"))
        let redirect = HTTPRedirect(
            statusCode: 307,
            url: url,
            nextURL: try XCTUnwrap(URL(string: "https://example.test/next")),
            method: "POST",
            nextMethod: "POST",
            requestHeaders: [],
            responseHeaders: []
        )
        let response = responseRecord(
            url: url,
            headers: [
                HTTPField(name: "X-Echo", value: "secret"),
                HTTPField(name: "Location", value: "https://user:password@example.test/secret"),
            ],
            redirects: [redirect],
            bodyByteCount: Int64(body.utf8.count),
            capture: capture(secret: "secret")
        )

        let projection = object(ResponseProjection.mcpAllowed(response: response, bodyURL: file, context: nil))
        let hop = object(try XCTUnwrap(array(projection["redirects"]).first))

        XCTAssertEqual(bool(projection["bodyWithheld"]), true)
        XCTAssertEqual(projection["body"], AutomationJSON.null)
        XCTAssertTrue(array(projection["headers"]).isEmpty)
        XCTAssertEqual(string(hop["method"]), "POST")
        XCTAssertEqual(string(hop["nextMethod"]), "POST")

        let blocked = object(ResponseProjection.mcpBlocked(response: response, context: nil))
        XCTAssertNil(headerFields(blocked["headers"])["Location"])
    }

    func testTruncatedAllowedBodyDropsTrailingKnownSecretPrefix() throws {
        let previewLimit = ResponseProjection.maximumBodyPreviewBytes
        let body = String(repeating: "x", count: previewLimit - 3) + "sec"
        let file = try bodyFile(Data(body.utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        let response = responseRecord(
            bodyByteCount: Int64(previewLimit + 10),
            capture: capture(secret: "secret-token")
        )

        let projection = object(ResponseProjection.mcpAllowed(response: response, bodyURL: file))
        let bodyObject = object(projection["body"])
        let content = try XCTUnwrap(string(bodyObject["content"]))

        XCTAssertEqual(bool(bodyObject["truncated"]), true)
        XCTAssertEqual(content.utf8.count, previewLimit - 3)
        XCTAssertFalse(content.hasSuffix("sec"))
    }

    func testCompleteTextPreservesTrailingKnownSecretPrefix() {
        let sanitizer = SecretRetemplating(capture: capture(secret: "echo-token"))

        XCTAssertEqual(sanitizer.sanitizeBounded("Content-Type", maximumUTF8Bytes: 1_024), "Content-Type")
        XCTAssertEqual(
            sanitizer.sanitizePreview("Content-Type", maximumUTF8Bytes: 1_024),
            "Content-Type"
        )
        XCTAssertEqual(
            sanitizer.sanitizePreview("Content-Type", maximumUTF8Bytes: 1_024, isTruncated: true),
            "Content-Typ"
        )
    }

    func testBinaryAllowProjectionWithholdsWhileCLIProvidesBoundedRawBase64() throws {
        let bytes = Data(repeating: 0xFF, count: ResponseProjection.maximumBodyPreviewBytes + 128)
        let preview = Data(bytes.prefix(ResponseProjection.maximumBodyPreviewBytes))
        let file = try bodyFile(bytes)
        defer { try? FileManager.default.removeItem(at: file) }
        let response = responseRecord(
            headers: [HTTPField(name: "X-Echo", value: "secret")],
            bodyByteCount: Int64(bytes.count),
            capture: capture(secret: "secret")
        )

        let allowed = object(ResponseProjection.mcpAllowed(response: response, bodyURL: file))
        let raw = object(ResponseProjection.cliRaw(response: response, bodyURL: file))
        let rawBody = object(raw["body"])

        XCTAssertEqual(bool(allowed["bodyWithheld"]), true)
        XCTAssertEqual(allowed["body"], AutomationJSON.null)
        XCTAssertEqual(string(rawBody["encoding"]), "base64")
        XCTAssertEqual(string(rawBody["content"]), preview.base64EncodedString())
        XCTAssertEqual(integer(rawBody["byteCount"]), Int64(bytes.count))
        XCTAssertEqual(integer(rawBody["previewByteCount"]), Int64(preview.base64EncodedString().utf8.count))
        XCTAssertEqual(bool(rawBody["truncated"]), true)
        XCTAssertEqual(headerFields(raw["headers"])["X-Echo"], "secret")
    }

    func testFailureProjectionSanitizesKnownFrozenSecrets() {
        let projection = object(
            ResponseProjection.mcpFailure(
                "Request failed after echoing secret-token",
                context: capture(secret: "secret-token")
            ))

        XCTAssertEqual(string(projection["state"]), "failed")
        XCTAssertEqual(string(projection["error"]), "Request failed after echoing {{token}}")
    }

    func testCLIRawProjectionSkipsMCPSecretRedaction() throws {
        let body = "echo secret"
        let file = try bodyFile(Data(body.utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        let response = responseRecord(
            headers: [HTTPField(name: "X-Echo", value: "secret")],
            bodyByteCount: Int64(body.utf8.count),
            capture: capture(secret: "secret")
        )

        let projection = object(ResponseProjection.cliRaw(response: response, bodyURL: file))
        let bodyObject = object(projection["body"])

        XCTAssertEqual(string(bodyObject["content"]), body)
        XCTAssertEqual(headerFields(projection["headers"])["X-Echo"], "secret")
    }

    func testMCPUnredactedProjectionIncludesRawURLsAndHeadersWithBoundedBodyPreview() throws {
        let previewLimit = ResponseProjection.maximumBodyPreviewBytes
        let body = "echo-token" + String(repeating: "x", count: previewLimit + 32)
        let file = try bodyFile(Data(body.utf8))
        defer { try? FileManager.default.removeItem(at: file) }

        let finalURL = try XCTUnwrap(URL(string: "https://user:password@example.test/final?token=echo-token"))
        let redirect = HTTPRedirect(
            statusCode: 302,
            url: try XCTUnwrap(URL(string: "https://user:password@example.test/start?token=echo-token")),
            nextURL: try XCTUnwrap(URL(string: "https://other.test/next?token=echo-token")),
            method: "POST",
            nextMethod: "GET",
            requestHeaders: [],
            responseHeaders: [HTTPField(name: "Location", value: "https://other.test/next?token=echo-token")]
        )
        let response = responseRecord(
            url: finalURL,
            headers: [
                HTTPField(name: "X-Echo", value: "echo-token"),
                HTTPField(name: "Location", value: "https://user:password@example.test/final?token=echo-token"),
            ],
            redirects: [redirect],
            bodyByteCount: Int64(body.utf8.count),
            capture: capture(secret: "echo-token")
        )

        let projection = object(ResponseProjection.mcpUnredacted(response: response, bodyURL: file))
        let bodyObject = object(projection["body"])
        let hop = object(try XCTUnwrap(array(projection["redirects"]).first))

        XCTAssertEqual(string(projection["finalURL"]), finalURL.absoluteString)
        XCTAssertEqual(headerFields(projection["headers"])["X-Echo"], "echo-token")
        XCTAssertEqual(
            headerFields(projection["headers"])["Location"],
            "https://user:password@example.test/final?token=echo-token"
        )
        XCTAssertEqual(string(hop["url"]), "https://user:password@example.test/start?token=echo-token")
        XCTAssertEqual(string(hop["nextURL"]), "https://other.test/next?token=echo-token")
        XCTAssertEqual(headerFields(hop["headers"])["Location"], "https://other.test/next?token=echo-token")
        XCTAssertEqual(string(bodyObject["content"]), String(body.prefix(previewLimit)))
        XCTAssertEqual(integer(bodyObject["byteCount"]), Int64(body.utf8.count))
        XCTAssertEqual(integer(bodyObject["previewByteCount"]), Int64(previewLimit))
        XCTAssertEqual(bool(bodyObject["truncated"]), true)
        XCTAssertEqual(bool(projection["bodyWithheld"]), false)
    }

    func testAPIKeyAuthorizationCompositeRetainsKnownVariableReference() throws {
        let body = "ApiKey secret-token"
        let file = try bodyFile(Data(body.utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        let response = responseRecord(
            headers: [HTTPField(name: "Authorization", value: body)],
            bodyByteCount: Int64(body.utf8.count),
            capture: apiKeyCapture(secret: "secret-token")
        )

        let projection = object(ResponseProjection.mcpAllowed(response: response, bodyURL: file))
        let bodyObject = object(projection["body"])

        XCTAssertEqual(string(bodyObject["content"]), "ApiKey {{token}}")
        XCTAssertEqual(headerFields(projection["headers"])["authorization"], "ApiKey {{token}}")
    }

    func testBasicAndBearerCredentialCompositesRetemplateKnownValues() {
        let bearerCapture = authenticationCapture(kind: .bearer, secret: "bearer-secret")
        let basicCapture = authenticationCapture(kind: .basic, secret: "basic-secret", username: "alice")
        let basicHeader = "Basic " + Data("alice:basic-secret".utf8).base64EncodedString()

        XCTAssertEqual(
            SecretRetemplating(capture: bearerCapture).sanitize("Bearer bearer-secret"),
            "Bearer {{token}}"
        )
        XCTAssertEqual(
            SecretRetemplating(capture: basicCapture).sanitize(basicHeader),
            "Basic {{token}}"
        )
    }

    func testManualAuthorizationHeadersSanitizeRecognizedBearerAndBasicPayloads() {
        let basicEncoded = Data("alice:manual-password".utf8).base64EncodedString()
        let capture = manualSensitiveHeaderCapture([
            HTTPField(name: "Authorization", value: "Bearer manual-bearer-token"),
            HTTPField(name: "Proxy-Authorization", value: "Basic \(basicEncoded)"),
        ])
        let sanitizer = SecretRetemplating(capture: capture)

        XCTAssertTrue(sanitizer.isComplete)
        XCTAssertEqual(
            sanitizer.sanitize("manual-bearer-token manual-password alice:manual-password \(basicEncoded)"),
            "[redacted] [redacted] [redacted] [redacted]"
        )
    }

    func testCookieValuesArePatternsAndAmbiguousCookiesWithholdAllText() {
        let capture = manualSensitiveHeaderCapture([
            HTTPField(name: "Cookie", value: "session=manual-cookie; theme=dark")
        ])
        let sanitizer = SecretRetemplating(capture: capture)

        XCTAssertTrue(sanitizer.isComplete)
        XCTAssertEqual(sanitizer.sanitize("manual-cookie dark"), "[redacted] [redacted]")

        let ambiguousCapture = manualSensitiveHeaderCapture([
            HTTPField(name: "Cookie", value: "session=\"manual-cookie\"; broken")
        ])
        let ambiguousSanitizer = SecretRetemplating(capture: ambiguousCapture)

        XCTAssertFalse(ambiguousSanitizer.isComplete)
        XCTAssertEqual(ambiguousSanitizer.sanitize("response body may echo a cookie"), "[redacted]")
    }

    private func capture(secret: String) -> SnapshotPreparationCapture {
        let configuration = HTTPRequestConfiguration(url: "https://example.test")
        let url = URL(string: configuration.url)!
        return SnapshotPreparationCapture(
            template: SnapshotRequestTemplate(configuration: configuration),
            referencedInputs: ["token": SnapshotInput(value: secret, scope: .request, isSecret: true)],
            authentication: SnapshotAuthenticationInput(kind: .none),
            submitted: SnapshotTransportRequest(method: "GET", url: url, headers: [])
        )
    }

    private func apiKeyCapture(secret: String) -> SnapshotPreparationCapture {
        authenticationCapture(kind: .apiKey, secret: secret)
    }

    private func authenticationCapture(
        kind: AuthenticationKind,
        secret: String,
        username: String = ""
    ) -> SnapshotPreparationCapture {
        let configuration = HTTPRequestConfiguration(url: "https://example.test")
        let url = URL(string: configuration.url)!
        let headerValue: String
        switch kind {
        case .basic:
            headerValue = "Basic " + Data("\(username):\(secret)".utf8).base64EncodedString()
        case .bearer:
            headerValue = "Bearer \(secret)"
        case .apiKey:
            headerValue = "ApiKey \(secret)"
        case .none:
            headerValue = secret
        }
        return SnapshotPreparationCapture(
            template: SnapshotRequestTemplate(configuration: configuration),
            referencedInputs: ["token": SnapshotInput(value: secret, scope: .request, isSecret: true)],
            authentication: SnapshotAuthenticationInput(
                kind: kind,
                username: username,
                secretTemplate: "{{token}}",
                resolvedSecret: secret,
                apiKeyHeaderName: kind == .apiKey ? "Authorization" : nil
            ),
            submitted: SnapshotTransportRequest(
                method: "GET",
                url: url,
                headers: [HTTPField(name: "Authorization", value: headerValue)],
                sensitiveNames: ["authorization"],
                secretNames: ["authorization"]
            )
        )
    }

    private func manualSensitiveHeaderCapture(_ headers: [HTTPField]) -> SnapshotPreparationCapture {
        let configuration = HTTPRequestConfiguration(url: "https://example.test")
        let url = URL(string: configuration.url)!
        let sensitiveNames = Set(headers.map { $0.name.lowercased() })
        return SnapshotPreparationCapture(
            template: SnapshotRequestTemplate(configuration: configuration),
            referencedInputs: [:],
            authentication: SnapshotAuthenticationInput(kind: .none),
            submitted: SnapshotTransportRequest(
                method: "GET",
                url: url,
                headers: headers,
                sensitiveNames: sensitiveNames,
                secretNames: sensitiveNames
            )
        )
    }

    private func responseRecord(
        url: URL = URL(string: "https://example.test/response")!,
        statusCode: Int = 200,
        headers: [HTTPField] = [],
        redirects: [HTTPRedirect] = [],
        bodyByteCount: Int64 = 0,
        duration: TimeInterval = 0.5,
        capture: SnapshotPreparationCapture? = nil
    ) -> HTTPResponseRecord {
        HTTPResponseRecord(
            runID: UUID(),
            request: HTTPRequestConfiguration(url: url.absoluteString),
            finalURL: url,
            statusCode: statusCode,
            requestHeaders: [],
            responseHeaders: headers,
            redirects: redirects,
            bodyFileURL: url,
            bodyByteCount: bodyByteCount,
            duration: duration,
            snapshotCapture: capture
        )
    }

    private func bodyFile(_ data: Data) throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("postie-projection-\(UUID().uuidString)")
        try data.write(to: file, options: .atomic)
        return file
    }

    private func object(_ value: AutomationJSON?) -> [String: AutomationJSON] {
        guard case .object(let result)? = value else { return [:] }
        return result
    }

    private func array(_ value: AutomationJSON?) -> [AutomationJSON] {
        guard case .array(let result)? = value else { return [] }
        return result
    }

    private func string(_ value: AutomationJSON?) -> String? {
        guard case .string(let result)? = value else { return nil }
        return result
    }

    private func integer(_ value: AutomationJSON?) -> Int64? {
        guard case .number(let result)? = value else { return nil }
        return NSDecimalNumber(decimal: result).int64Value
    }

    private func bool(_ value: AutomationJSON?) -> Bool? {
        guard case .bool(let result)? = value else { return nil }
        return result
    }

    private func headerFields(_ value: AutomationJSON?) -> [String: String] {
        array(value).reduce(into: [:]) { result, item in
            let field = object(item)
            guard let name = string(field["name"]), let value = string(field["value"]) else { return }
            result[name] = value
        }
    }
}
