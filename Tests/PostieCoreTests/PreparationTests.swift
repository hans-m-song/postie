import Foundation
import XCTest
@testable import PostieCore

final class PreparationTests: XCTestCase {
    func testPrepareAppendsOrderedQueryItemsAndHeaders() throws {
        let configuration = HTTPRequestConfiguration(
            method: "POST",
            url: "https://example.test/path?existing=one",
            query: [
                HTTPField(name: "tag", value: "first value"),
                HTTPField(name: "disabled", value: "ignored", isEnabled: false),
                HTTPField(name: "tag", value: "second")
            ],
            headers: [
                HTTPField(name: "X-Sequence", value: "first"),
                HTTPField(name: "X-Sequence", value: "second"),
                HTTPField(name: "Cookie", value: "first=one"),
                HTTPField(name: "Cookie", value: "second=two")
            ],
            body: "payload",
            bodyEnabled: true
        )

        let request = try RequestPreparer.prepare(configuration)
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.queryItems?.map(\.name), ["existing", "tag", "tag"])
        XCTAssertEqual(components.queryItems?.map(\.value), ["one", "first value", "second"])
        XCTAssertEqual(headerValue("X-Sequence", in: request), "first,second")
        XCTAssertEqual(headerValue("Cookie", in: request), "first=one; second=two")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.httpBody, Data("payload".utf8))
    }

    func testPreparePreservesExistingPercentEncodingAndEscapesAddedPlus() throws {
        let configuration = HTTPRequestConfiguration(
            url: "https://example.test/path?token=a%2Bb%2Fc",
            query: [
                HTTPField(name: "x", value: "1"),
                HTTPField(name: "search", value: "a+b/c")
            ]
        )

        let request = try RequestPreparer.prepare(configuration)
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.percentEncodedQuery, "token=a%2Bb%2Fc&x=1&search=a%2Bb%2Fc")
        XCTAssertEqual(components.queryItems?.last?.value, "a+b/c")
    }

    func testPrepareSubstitutesOnlyCompletePathSegmentsAndPreservesEncodedPathAndQuery() throws {
        let configuration = HTTPRequestConfiguration(
            url: "https://example.test/root%2Fpart/:id/:id/prefix:id/:id-suffix/:9id/%3Aid?existing=a%2Bb%2Fc&param=:query#fragment-:id",
            pathParameters: [
                HTTPField(name: "id", value: "a/b%?#"),
                HTTPField(name: "id", value: "disabled", isEnabled: false),
                HTTPField(name: "unused", value: ""),
                HTTPField(name: "unused", value: "duplicate")
            ]
        )

        let request = try RequestPreparer.prepare(configuration)
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.percentEncodedPath, "/root%2Fpart/a%2Fb%25%3F%23/a%2Fb%25%3F%23/prefix:id/:id-suffix/:9id/%3Aid")
        XCTAssertEqual(components.percentEncodedQuery, "existing=a%2Bb%2Fc&param=:query")
        XCTAssertEqual(components.percentEncodedFragment, "fragment-:id")
    }

    func testPathParameterNamesAreUniqueOrderedAndWorkWithTemplatedAuthority() {
        XCTAssertEqual(
            RequestPreparer.pathParameterNames(in: "https://{{host}}/v1/:team/:user_2/:team/prefix:id/:9id/:bad-name/%3Aid?query=:ignored#fragment-:ignored"),
            ["team", "user_2"]
        )
    }

    func testPrepareRequiresOneEnabledNonEmptyValueForEveryPathParameter() {
        let configurations = [
            HTTPRequestConfiguration(url: "https://example.test/users/:id"),
            HTTPRequestConfiguration(url: "https://example.test/users/:id", pathParameters: [HTTPField(name: "id", value: "disabled", isEnabled: false)]),
            HTTPRequestConfiguration(url: "https://example.test/users/:id", pathParameters: [HTTPField(name: "id", value: "")]),
            HTTPRequestConfiguration(url: "https://example.test/users/:id", pathParameters: [HTTPField(name: "id", value: "first"), HTTPField(name: "id", value: "second")]),
            HTTPRequestConfiguration(url: "https://example.test/users/:id", pathParameters: [HTTPField(name: "id", value: "{{unresolved}}")])
        ]

        for configuration in configurations {
            XCTAssertThrowsError(try RequestPreparer.prepare(configuration))
        }
    }

    func testPathParameterValuesAreLiteralSegmentsIncludingDotAndWhitespaceValues() throws {
        let configuration = HTTPRequestConfiguration(
            url: "https://example.test/:literal/:dot/:dots/:space",
            pathParameters: [
                HTTPField(name: "literal", value: ":another"),
                HTTPField(name: "another", value: "expanded"),
                HTTPField(name: "dot", value: "."),
                HTTPField(name: "dots", value: ".."),
                HTTPField(name: "space", value: " ")
            ]
        )

        let request = try RequestPreparer.prepare(configuration)
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.percentEncodedPath, "/%3Aanother/%2E/%2E%2E/%20")
    }

    func testPrepareRejectsUnsupportedURLsMethodsAndHeaderInjection() {
        XCTAssertThrowsError(try RequestPreparer.prepare(HTTPRequestConfiguration(url: "file:///tmp/body")))
        XCTAssertThrowsError(try RequestPreparer.prepare(HTTPRequestConfiguration(method: "GET\nX: y", url: "https://example.test")))
        XCTAssertThrowsError(try RequestPreparer.prepare(HTTPRequestConfiguration(url: "https://example.test", headers: [HTTPField(name: "Bad Name", value: "x")])))
        XCTAssertThrowsError(try RequestPreparer.prepare(HTTPRequestConfiguration(url: "https://example.test", headers: [HTTPField(name: "X-Test", value: "safe\r\nInjected: yes")])))
    }

    func testPrepareRejectsUnexpandedTemplatesInSentFields() {
        let configurations = [
            HTTPRequestConfiguration(url: "https://example.test/{{path}}"),
            HTTPRequestConfiguration(url: "https://example.test", query: [HTTPField(name: "key", value: "{{value}}")]),
            HTTPRequestConfiguration(url: "https://example.test", headers: [HTTPField(name: "Authorization", value: "Bearer {{token}}")]),
            HTTPRequestConfiguration(url: "https://example.test", body: "{{body}}", bodyEnabled: true)
        ]

        for configuration in configurations {
            XCTAssertThrowsError(try RequestPreparer.prepare(configuration))
        }
    }

    func testPrepareRequiresPositiveFiniteTimeoutsAndNonnegativeLimit() {
        var configuration = HTTPRequestConfiguration(url: "https://example.test")
        configuration.options.inactivityTimeout = 0
        XCTAssertThrowsError(try RequestPreparer.prepare(configuration))

        configuration.options.inactivityTimeout = 1
        configuration.options.overallTimeout = .infinity
        XCTAssertThrowsError(try RequestPreparer.prepare(configuration))

        configuration.options.overallTimeout = nil
        configuration.options.maximumResponseBytes = -1
        XCTAssertThrowsError(try RequestPreparer.prepare(configuration))
    }

    func testTemplateEngineScansEscapesAndUsesWholePathSegments() throws {
        let scan = TemplateEngine.scan("{{valid_2}} \\{{literal}} }} {{bad-name}} {{unclosed")

        XCTAssertEqual(scan.references.map(\.name), ["valid_2"])
        XCTAssertEqual(scan.invalidRanges.count, 2)
        XCTAssertTrue(TemplateEngine.isValidVariableName("_valid2"))
        XCTAssertFalse(TemplateEngine.isValidVariableName("2invalid"))

        let url = "https://{{host}}/v/:team/:id?query=:ignored#fragment-:ignored"
        let pathReferences = TemplateEngine.pathReferences(in: url)
        XCTAssertEqual(pathReferences.map(\.name), ["team", "id"])
        XCTAssertEqual(pathReferences.map { (url as NSString).substring(with: $0.range) }, [":team", ":id"])

        XCTAssertEqual(try TemplateEngine.substitute("\\{{literal}} }}", values: [:]), "{{literal}} }}")
    }

    func testScopedPreparationUsesPrecedenceWithoutRecursiveExpansion() async throws {
        let configuration = HTTPRequestConfiguration(
            url: "https://{{host}}.test/",
            headers: [
                HTTPField(name: "X-Values", value: "{{winner}}|{{collectionOnly}}|{{globalOnly}}|{{nested}}"),
                HTTPField(name: "X-Literal", value: "\\{{winner}}|json}}")
            ],
            body: "{{nested}}",
            bodyEnabled: true,
            variables: [
                "winner": .plain("request"),
                "nested": .plain("{{globalOnly}}")
            ]
        )
        let context = VariableContext(
            global: [
                "host": .plain("api"),
                "winner": .plain("global"),
                "collectionOnly": .plain("global collection"),
                "globalOnly": .plain("global")
            ],
            collection: [
                "winner": .plain("collection"),
                "collectionOnly": .plain("collection")
            ]
        )

        let prepared = try await RequestPreparer.prepare(configuration, context: context, decryptor: nil)

        XCTAssertEqual(prepared.configuration, configuration)
        XCTAssertEqual(prepared.request.url?.host, "api.test")
        XCTAssertEqual(headerValue("X-Values", in: prepared.request), "request|collection|global|{{globalOnly}}")
        XCTAssertEqual(headerValue("X-Literal", in: prepared.request), "{{winner}}|json}}")
        XCTAssertEqual(prepared.request.httpBody, Data("{{globalOnly}}".utf8))
        XCTAssertEqual(prepared.referencedInputs["winner"]?.scope.rawValue, VariableScope.request.rawValue)
        XCTAssertEqual(prepared.referencedInputs["collectionOnly"]?.scope.rawValue, VariableScope.collection.rawValue)
        XCTAssertEqual(prepared.referencedInputs["globalOnly"]?.scope.rawValue, VariableScope.global.rawValue)
    }

    func testPreparationRejectsMissingAndMalformedActiveTemplates() async {
        let missing = HTTPRequestConfiguration(
            url: "https://example.test",
            headers: [HTTPField(name: "X-Missing", value: "{{missing}}")]
        )
        let malformed = HTTPRequestConfiguration(
            url: "https://example.test",
            body: "{{bad-name}}",
            bodyEnabled: true
        )

        do {
            _ = try await RequestPreparer.prepare(missing, context: VariableContext(), decryptor: nil)
            XCTFail("A missing referenced variable must prevent preparation.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("missing"))
        }

        do {
            _ = try await RequestPreparer.prepare(malformed, context: VariableContext(), decryptor: nil)
            XCTFail("A malformed active template must prevent preparation.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("template"))
        }
    }

    func testPreparationEncodesResolvedQueryAndPathValuesOnce() async throws {
        let configuration = HTTPRequestConfiguration(
            url: "https://example.test/:id?existing=a%2Fb",
            pathParameters: [HTTPField(name: "id", value: "{{segment}}")],
            query: [HTTPField(name: "{{queryName}}", value: "{{queryValue}}")]
        )
        let context = VariableContext(request: [
            "segment": .plain("a/b%?#"),
            "queryName": .plain("q name"),
            "queryValue": .plain("a+b/c%?#")
        ])

        let prepared = try await RequestPreparer.prepare(configuration, context: context, decryptor: nil)
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(prepared.request.url), resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.percentEncodedPath, "/a%2Fb%25%3F%23")
        XCTAssertEqual(components.percentEncodedQuery, "existing=a%2Fb&q%20name=a%2Bb%2Fc%25%3F%23")
    }

    func testPreparationDecryptsOnlyEffectiveSecretsAndAddsStructuredAuthorization() async throws {
        let selectedSecret = SecretEnvelope(combined: "selected-variable")
        let password = SecretEnvelope(combined: "basic-password")
        let decryptor = FakeDecryptor(values: [
            selectedSecret.combined: "used secret",
            password.combined: "pässword"
        ])
        let configuration = HTTPRequestConfiguration(
            url: "https://example.test",
            headers: [HTTPField(name: "X-Secret", value: "{{secret}}")],
            variables: ["shadowed": .encrypted(SecretEnvelope(combined: "request-shadow"))],
            authentication: RequestAuthentication(kind: .basic, username: "usér", password: password,
                                                  token: SecretEnvelope(combined: "unused-inactive-token"))
        )
        let context = VariableContext(
            global: [
                "secret": .encrypted(SecretEnvelope(combined: "global-shadow")),
                "unused": .encrypted(SecretEnvelope(combined: "unused-global"))
            ],
            collection: ["secret": .plain("collection shadow")],
            request: ["secret": .encrypted(selectedSecret)]
        )

        let prepared = try await RequestPreparer.prepare(configuration, context: context, decryptor: decryptor)
        let expectedBasic = Data("usér:pässword".utf8).base64EncodedString()
        let decryptedEnvelopes = await decryptor.requestedEnvelopes()

        XCTAssertEqual(headerValue("X-Secret", in: prepared.request), "used secret")
        XCTAssertEqual(headerValue("Authorization", in: prepared.request), "Basic \(expectedBasic)")
        XCTAssertEqual(Set(decryptedEnvelopes), Set([selectedSecret.combined, password.combined]))
        XCTAssertEqual(prepared.referencedInputs["secret"]?.isSecret, true)
    }

    func testPreparationRejectsResolvedAuthorizationHeaderWithStructuredAuth() async throws {
        let configuration = HTTPRequestConfiguration(
            url: "https://example.test",
            headers: [HTTPField(name: "{{headerName}}", value: "manual")],
            authentication: RequestAuthentication(kind: .bearer, token: SecretEnvelope(combined: "bearer-token"))
        )
        let context = VariableContext(request: ["headerName": .plain("authorization")])
        let decryptor = FakeDecryptor(values: ["bearer-token": "token-value"])

        do {
            _ = try await RequestPreparer.prepare(configuration, context: context, decryptor: decryptor)
            XCTFail("A resolved enabled Authorization field must conflict with structured authentication.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Authorization"))
        }
    }

    private func headerValue(_ name: String, in request: URLRequest) -> String? {
        request.allHTTPHeaderFields?.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

private actor FakeDecryptor: SecretValueDecrypting {
    private let values: [String: String]
    private var requested: [String] = []

    init(values: [String: String]) {
        self.values = values
    }

    func decrypt(_ envelope: SecretEnvelope) async throws -> String {
        requested.append(envelope.combined)
        guard let value = values[envelope.combined] else {
            throw FakeDecryptorError.unknownEnvelope
        }
        return value
    }

    func requestedEnvelopes() -> [String] {
        requested
    }
}

private enum FakeDecryptorError: Error {
    case unknownEnvelope
}
