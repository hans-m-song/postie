import Foundation
import XCTest
@testable import PostieCore

final class PreparationTests: XCTestCase {
    func testPrepareCanonicalQueryPreservesEncodedLiteralBracesWithoutResolvingThem() throws {
        let state = QueryParameters.parse(
            displayURL: "https://example.test?%7B%7Bname%7D%7D=%7b%7bmissing%7d%7d&flag&empty=")
        let configuration = HTTPRequestConfiguration(url: state.baseURL, query: state.fields)

        let request = try RequestPreparer.prepare(configuration)

        XCTAssertEqual(
            request.url?.absoluteString, "https://example.test?%7B%7Bname%7D%7D=%7b%7bmissing%7d%7d&flag&empty=")
    }

    func testPrepareRealQueryTemplatesPreservesLiteralEncodedPartsAndEncodesValuesOnce() throws {
        let state = QueryParameters.parse(
            displayURL: "https://example.test?{{name}}=%7B%7Bliteral%7D%7D%2f{{value}}+%2B&tag=a&tag=b#fragment")
        let configuration = HTTPRequestConfiguration(
            url: state.baseURL,
            query: state.fields,
            variables: ["name": .plain("q name"), "value": .plain("a+b/%?&#={{nested}}")]
        )

        let request = try RequestPreparer.prepare(configuration)

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://example.test?q%20name=%7B%7Bliteral%7D%7D%2fa%2Bb%2F%25%3F%26%23%3D%7B%7Bnested%7D%7D+%2B&tag=a&tag=b#fragment"
        )
    }

    func testPrepareLegacyURLQueryAndRowsAppendsExactlyOnce() throws {
        let configuration = HTTPRequestConfiguration(
            url: "https://example.test?tag=url%2f&flag&empty=#fragment",
            query: [
                HTTPField(name: "tag", value: "table/+"), HTTPField(name: "off", value: "ignored", isEnabled: false),
            ]
        )

        let request = try RequestPreparer.prepare(configuration)

        XCTAssertEqual(
            request.url?.absoluteString, "https://example.test?tag=url%2f&flag&empty=&tag=table%2F%2B#fragment")
    }

    func testPrepareLegacyAndCanonicalQueryProduceSameURL() throws {
        let legacy = HTTPRequestConfiguration(
            url: "https://example.test?tag=first%2f&tag=second&bare#fragment",
            query: [HTTPField(name: "tag", value: "third")]
        )
        let normalized = QueryParameters.normalize(url: legacy.url, fields: legacy.query)
        let canonical = HTTPRequestConfiguration(url: normalized.baseURL, query: normalized.fields)

        XCTAssertEqual(try RequestPreparer.prepare(legacy).url, try RequestPreparer.prepare(canonical).url)
        XCTAssertEqual(
            try RequestPreparer.prepare(canonical).url?.absoluteString,
            "https://example.test?tag=first%2f&tag=second&bare&tag=third#fragment")
    }

    func testPreparePreservesEmptyQueryAndEmptyNameComponents() throws {
        for suffix in ["?", "?=", "?&&", "?=value&&flag&"] {
            let state = QueryParameters.parse(displayURL: "https://example.test" + suffix)
            let configuration = HTTPRequestConfiguration(url: state.baseURL, query: state.fields + [HTTPField()])

            XCTAssertEqual(
                try RequestPreparer.prepare(configuration).url?.absoluteString, "https://example.test" + suffix)
        }
    }

    func testPrepareEditedQueryComponentResolvesItsNewTemplateAndPreservesOtherEncoding() throws {
        var state = QueryParameters.parse(displayURL: "https://example.test?%71=%7B%7Bliteral%7D%7D")
        state.fields[0].value = "{{replacement}}"
        let configuration = HTTPRequestConfiguration(
            url: state.baseURL,
            query: state.fields,
            variables: ["replacement": .plain("a%2F+b")]
        )

        XCTAssertEqual(
            try RequestPreparer.prepare(configuration).url?.absoluteString, "https://example.test?%71=a%252F%2Bb")
    }

    func testPrepareEscapedQueryTemplatesRemainLiteral() throws {
        let state = QueryParameters.parse(
            displayURL: "https://example.test?raw=\\{{literal}}&encoded=%7B%7Bliteral%7D%7D")
        let configuration = HTTPRequestConfiguration(url: state.baseURL, query: state.fields)

        XCTAssertEqual(
            try RequestPreparer.prepare(configuration).url?.absoluteString,
            "https://example.test?raw=%7B%7Bliteral%7D%7D&encoded=%7B%7Bliteral%7D%7D")
    }

    func testPrepareScopedQueryIgnoresEncodedAndDisabledTemplates() async throws {
        var state = QueryParameters.parse(
            displayURL: "https://example.test?literal=%7B%7Bmissing%7D%7D&actual={{value}}")
        state.fields.append(HTTPField(name: "disabled", value: "{{alsoMissing}}", isEnabled: false))
        let configuration = HTTPRequestConfiguration(url: state.baseURL, query: state.fields)

        let prepared = try await RequestPreparer.prepare(
            configuration,
            context: VariableContext(global: ["value": .plain("a&b")]),
            decryptor: nil
        )

        XCTAssertEqual(
            prepared.request.url?.absoluteString, "https://example.test?literal=%7B%7Bmissing%7D%7D&actual=a%26b")
        XCTAssertEqual(Set(prepared.referencedInputs.keys), ["value"])
    }

    func testPrepareAppendsOrderedQueryItemsAndHeaders() throws {
        let configuration = HTTPRequestConfiguration(
            method: "POST",
            url: "https://example.test/path?existing=one",
            query: [
                HTTPField(name: "tag", value: "first value"),
                HTTPField(name: "disabled", value: "ignored", isEnabled: false),
                HTTPField(name: "tag", value: "second"),
            ],
            headers: [
                HTTPField(name: "X-Sequence", value: "first"),
                HTTPField(name: "X-Sequence", value: "second"),
                HTTPField(name: "Cookie", value: "first=one"),
                HTTPField(name: "Cookie", value: "second=two"),
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
                HTTPField(name: "search", value: "a+b/c"),
            ]
        )

        let request = try RequestPreparer.prepare(configuration)
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.percentEncodedQuery, "token=a%2Bb%2Fc&x=1&search=a%2Bb%2Fc")
        XCTAssertEqual(components.queryItems?.last?.value, "a+b/c")
    }

    func testPrepareSubstitutesOnlyCompletePathSegmentsAndPreservesEncodedPathAndQuery() throws {
        let configuration = HTTPRequestConfiguration(
            url:
                "https://example.test/root%2Fpart/:id/:id/prefix:id/:id-suffix/:9id/%3Aid?existing=a%2Bb%2Fc&param=:query#fragment-:id",
            pathParameters: [
                HTTPField(name: "id", value: "a/b%?#"),
                HTTPField(name: "id", value: "disabled", isEnabled: false),
                HTTPField(name: "unused", value: ""),
                HTTPField(name: "unused", value: "duplicate"),
            ]
        )

        let request = try RequestPreparer.prepare(configuration)
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))

        XCTAssertEqual(
            components.percentEncodedPath, "/root%2Fpart/a%2Fb%25%3F%23/a%2Fb%25%3F%23/prefix:id/:id-suffix/:9id/%3Aid")
        XCTAssertEqual(components.percentEncodedQuery, "existing=a%2Bb%2Fc&param=:query")
        XCTAssertEqual(components.percentEncodedFragment, "fragment-:id")
    }

    func testPathParameterNamesAreUniqueOrderedAndWorkWithTemplatedAuthority() {
        XCTAssertEqual(
            RequestPreparer.pathParameterNames(
                in:
                    "https://{{host}}/v1/:team/:user_2/:team/prefix:id/:9id/:bad-name/%3Aid?query=:ignored#fragment-:ignored"
            ),
            ["team", "user_2"]
        )
    }

    func testPrepareRequiresOneEnabledNonEmptyValueForEveryPathParameter() {
        let configurations = [
            HTTPRequestConfiguration(url: "https://example.test/users/:id"),
            HTTPRequestConfiguration(
                url: "https://example.test/users/:id",
                pathParameters: [HTTPField(name: "id", value: "disabled", isEnabled: false)]),
            HTTPRequestConfiguration(
                url: "https://example.test/users/:id", pathParameters: [HTTPField(name: "id", value: "")]),
            HTTPRequestConfiguration(
                url: "https://example.test/users/:id",
                pathParameters: [HTTPField(name: "id", value: "first"), HTTPField(name: "id", value: "second")]),
            HTTPRequestConfiguration(
                url: "https://example.test/users/:id", pathParameters: [HTTPField(name: "id", value: "{{unresolved}}")]),
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
                HTTPField(name: "space", value: " "),
            ]
        )

        let request = try RequestPreparer.prepare(configuration)
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.percentEncodedPath, "/%3Aanother/%2E/%2E%2E/%20")
    }

    func testPrepareRejectsUnsupportedURLsMethodsAndHeaderInjection() {
        XCTAssertThrowsError(try RequestPreparer.prepare(HTTPRequestConfiguration(url: "file:///tmp/body")))
        XCTAssertThrowsError(
            try RequestPreparer.prepare(HTTPRequestConfiguration(method: "GET\nX: y", url: "https://example.test")))
        XCTAssertThrowsError(
            try RequestPreparer.prepare(
                HTTPRequestConfiguration(
                    url: "https://example.test", headers: [HTTPField(name: "Bad Name", value: "x")])))
        XCTAssertThrowsError(
            try RequestPreparer.prepare(
                HTTPRequestConfiguration(
                    url: "https://example.test", headers: [HTTPField(name: "X-Test", value: "safe\r\nInjected: yes")])))
    }

    func testPrepareRejectsUnexpandedTemplatesInSentFields() {
        let configurations = [
            HTTPRequestConfiguration(url: "https://example.test/{{path}}"),
            HTTPRequestConfiguration(url: "https://example.test", query: [HTTPField(name: "key", value: "{{value}}")]),
            HTTPRequestConfiguration(
                url: "https://example.test", headers: [HTTPField(name: "Authorization", value: "Bearer {{token}}")]),
            HTTPRequestConfiguration(url: "https://example.test", body: "{{body}}", bodyEnabled: true),
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
                HTTPField(name: "X-Literal", value: "\\{{winner}}|json}}"),
            ],
            body: "{{nested}}",
            bodyEnabled: true,
            variables: [
                "winner": .plain("request"),
                "nested": .plain("{{globalOnly}}"),
            ]
        )
        let context = VariableContext(
            global: [
                "host": .plain("api"),
                "winner": .plain("global"),
                "collectionOnly": .plain("global collection"),
                "globalOnly": .plain("global"),
            ],
            collection: [
                "winner": .plain("collection"),
                "collectionOnly": .plain("collection"),
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
            "queryValue": .plain("a+b/c%?#"),
        ])

        let prepared = try await RequestPreparer.prepare(configuration, context: context, decryptor: nil)
        let components = try XCTUnwrap(
            URLComponents(url: XCTUnwrap(prepared.request.url), resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.percentEncodedPath, "/a%2Fb%25%3F%23")
        XCTAssertEqual(components.percentEncodedQuery, "existing=a%2Fb&q%20name=a%2Bb%2Fc%25%3F%23")
    }

    func testPreparationDecryptsOnlyEffectiveSecretsAndAddsStructuredAuthorization() async throws {
        let selectedSecret = SecretEnvelope(combined: "selected-variable")
        let password = SecretEnvelope(combined: "basic-password")
        let decryptor = FakeDecryptor(values: [
            selectedSecret.combined: "used secret",
            password.combined: "pässword",
        ])
        let configuration = HTTPRequestConfiguration(
            url: "https://example.test",
            headers: [HTTPField(name: "X-Secret", value: "{{secret}}")],
            variables: ["shadowed": .encrypted(SecretEnvelope(combined: "request-shadow"))],
            authentication: RequestAuthentication(
                kind: .basic, username: "usér", password: password,
                token: SecretEnvelope(combined: "unused-inactive-token"))
        )
        let context = VariableContext(
            global: [
                "secret": .encrypted(SecretEnvelope(combined: "global-shadow")),
                "unused": .encrypted(SecretEnvelope(combined: "unused-global")),
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

    func testPreparationMarksOnlyActiveHeadersReferencingEncryptedVariablesAsSensitive() async throws {
        let privateName = SecretEnvelope(combined: "private-header-name")
        let privateValue = SecretEnvelope(combined: "private-header-value")
        let inheritedValue = SecretEnvelope(combined: "inherited-header-value")
        let disabledValue = SecretEnvelope(combined: "disabled-header-value")
        let decryptor = FakeDecryptor(values: [
            privateName.combined: "X-Name-Secret",
            privateValue.combined: "value secret",
            inheritedValue.combined: "inherited secret",
            disabledValue.combined: "disabled secret",
        ])
        let configuration = HTTPRequestConfiguration(
            url: "https://example.test",
            headers: [
                HTTPField(name: "{{privateName}}", value: "name value"),
                HTTPField(name: "X-Private-Value", value: "Bearer {{privateValue}}"),
                HTTPField(name: "X-Disabled", value: "{{disabledValue}}", isEnabled: false),
            ]
        )
        let context = VariableContext(
            collection: ["inheritedValue": .encrypted(inheritedValue)],
            request: [
                "privateName": .encrypted(privateName),
                "privateValue": .encrypted(privateValue),
                "disabledValue": .encrypted(disabledValue),
            ]
        )
        let collection = CollectionRequestDefaults(headers: [
            HTTPField(name: "X-Inherited-Private", value: "{{inheritedValue}}")
        ])

        let prepared = try await RequestPreparer.prepare(
            configuration,
            context: context,
            decryptor: decryptor,
            collection: collection
        )
        let decryptedEnvelopes = await decryptor.requestedEnvelopes()

        XCTAssertEqual(
            prepared.sensitiveRequestHeaderNames,
            [
                "authorization", "proxy-authorization", "cookie", "set-cookie", "x-name-secret", "x-private-value",
                "x-inherited-private",
            ]
        )
        XCTAssertEqual(prepared.secretRequestHeaderNames, ["x-name-secret"])
        XCTAssertEqual(
            prepared.requestHeaderSources,
            [
                "x-name-secret": .request,
                "x-private-value": .request,
                "x-inherited-private": .collection,
            ])
        XCTAssertEqual(headerValue("X-Name-Secret", in: prepared.request), "name value")
        XCTAssertEqual(headerValue("X-Private-Value", in: prepared.request), "Bearer value secret")
        XCTAssertEqual(headerValue("X-Inherited-Private", in: prepared.request), "inherited secret")
        XCTAssertNil(prepared.referencedInputs["disabledValue"])
        XCTAssertEqual(
            Set(decryptedEnvelopes), Set([privateName.combined, privateValue.combined, inheritedValue.combined]))
    }

    func testHeaderMetadataInitializersNormalizeNamesAndDefaultToEmpty() throws {
        let url = try XCTUnwrap(URL(string: "https://example.test"))
        let configuration = HTTPRequestConfiguration(url: url.absoluteString)
        let request = URLRequest(url: url)
        let sensitiveNames: Set<String> = ["X-Private", "sEt-CoOkIe"]
        let secretNames: Set<String> = ["X-Private"]
        let headerSources: [String: HTTPHeaderSource] = ["X-Private": .request, "X-Auth": .requestAuth]
        let prepared = PreparedHTTPRequest(
            configuration: configuration,
            request: request,
            referencedInputs: [:],
            sensitiveRequestHeaderNames: sensitiveNames,
            secretRequestHeaderNames: secretNames,
            requestHeaderSources: headerSources
        )
        let preparedWithoutNames = PreparedHTTPRequest(
            configuration: configuration, request: request, referencedInputs: [:])
        let redirect = HTTPRedirect(
            statusCode: 302,
            url: url,
            nextURL: url,
            method: "GET",
            nextMethod: "GET",
            requestHeaders: [],
            responseHeaders: [],
            sensitiveRequestHeaderNames: sensitiveNames,
            secretRequestHeaderNames: secretNames,
            requestHeaderSources: headerSources
        )
        let response = HTTPResponseRecord(
            runID: UUID(),
            request: configuration,
            finalURL: url,
            statusCode: 200,
            requestHeaders: [],
            responseHeaders: [],
            redirects: [],
            bodyFileURL: URL(fileURLWithPath: "/tmp/response.body"),
            bodyByteCount: 0,
            duration: 0,
            sensitiveRequestHeaderNames: sensitiveNames,
            secretRequestHeaderNames: secretNames,
            requestHeaderSources: headerSources
        )

        XCTAssertEqual(prepared.sensitiveRequestHeaderNames, ["x-private", "set-cookie"])
        XCTAssertEqual(prepared.secretRequestHeaderNames, ["x-private"])
        XCTAssertEqual(prepared.requestHeaderSources, ["x-private": .request, "x-auth": .requestAuth])
        XCTAssertEqual(preparedWithoutNames.sensitiveRequestHeaderNames, [])
        XCTAssertEqual(preparedWithoutNames.secretRequestHeaderNames, [])
        XCTAssertEqual(preparedWithoutNames.requestHeaderSources, [:])
        XCTAssertEqual(redirect.sensitiveRequestHeaderNames, ["x-private", "set-cookie"])
        XCTAssertEqual(redirect.secretRequestHeaderNames, ["x-private"])
        XCTAssertEqual(redirect.requestHeaderSources, ["x-private": .request, "x-auth": .requestAuth])
        XCTAssertEqual(response.sensitiveRequestHeaderNames, ["x-private", "set-cookie"])
        XCTAssertEqual(response.secretRequestHeaderNames, ["x-private"])
        XCTAssertEqual(response.requestHeaderSources, ["x-private": .request, "x-auth": .requestAuth])
    }

    func testManualAuthorizationHeaderOverridesStructuredAuthWithoutDecryptingIt() async throws {
        let configuration = HTTPRequestConfiguration(
            url: "https://example.test",
            headers: [HTTPField(name: "{{headerName}}", value: "manual")],
            authentication: RequestAuthentication(kind: .bearer, token: SecretEnvelope(combined: "bearer-token"))
        )
        let context = VariableContext(request: ["headerName": .plain("authorization")])
        let decryptor = FakeDecryptor(values: ["bearer-token": "token-value"])

        let prepared = try await RequestPreparer.prepare(configuration, context: context, decryptor: decryptor)
        let decryptedEnvelopes = await decryptor.requestedEnvelopes()

        XCTAssertEqual(headerValue("Authorization", in: prepared.request), "manual")
        XCTAssertEqual(prepared.requestHeaderSources, ["authorization": .request])
        XCTAssertTrue(decryptedEnvelopes.isEmpty)
    }

    func testAPIKeyAuthenticationUsesInheritedSecretTemplateVerbatimAndMasksCustomHeader() async throws {
        let requestKey = SecretEnvelope(combined: "request-api-key")
        let collectionKey = SecretEnvelope(combined: "collection-api-key")
        let configuration = HTTPRequestConfiguration(
            url: "https://example.test",
            variables: ["suffix": .plain("request value")],
            authentication: RequestAuthentication(
                kind: .apiKey,
                apiKeyHeaderName: "X-Request-Key",
                apiKey: requestKey
            ),
            inheritsCollectionAuthentication: true
        )
        let collection = CollectionRequestDefaults(
            headers: [HTTPField(name: "{{headerName}}", value: "{{missingCollectionValue}}")],
            authentication: RequestAuthentication(
                kind: .apiKey,
                apiKeyHeaderName: "X-Service-Key",
                apiKey: collectionKey
            )
        )
        let context = VariableContext(
            collection: ["suffix": .plain("collection value")],
            request: ["headerName": .plain("x-service-key")]
        )
        let decryptor = FakeDecryptor(values: [
            requestKey.combined: "unused request key",
            collectionKey.combined: "raw/{{suffix}}+ /=",
        ])

        let prepared = try await RequestPreparer.prepare(
            configuration,
            context: context,
            decryptor: decryptor,
            collection: collection
        )
        let decryptedEnvelopes = await decryptor.requestedEnvelopes()

        XCTAssertEqual(headerValue("X-Service-Key", in: prepared.request), "raw/request value+ /=")
        XCTAssertEqual(Set(decryptedEnvelopes), [collectionKey.combined])
        XCTAssertEqual(prepared.referencedInputs["suffix"]?.value, "request value")
        XCTAssertNil(prepared.referencedInputs["missingCollectionValue"])
        XCTAssertEqual(
            prepared.sensitiveRequestHeaderNames,
            ["authorization", "proxy-authorization", "cookie", "set-cookie", "x-service-key"])
        XCTAssertEqual(prepared.secretRequestHeaderNames, [])
        XCTAssertEqual(prepared.requestHeaderSources, ["x-service-key": .collectionAuth])
    }

    func testManualRequestHeaderOverridesAPIKeyAndSkipsMissingCredentialTemplates() async throws {
        let apiKey = SecretEnvelope(combined: "shadowed-api-key")
        let configuration = HTTPRequestConfiguration(
            url: "https://example.test",
            headers: [HTTPField(name: "{{manualName}}", value: "manual value")],
            authentication: RequestAuthentication(kind: .apiKey, apiKeyHeaderName: "X-Service-Key", apiKey: apiKey)
        )
        let context = VariableContext(request: ["manualName": .plain("x-service-key")])
        let decryptor = FakeDecryptor(values: [apiKey.combined: "{{missingApiKeyVariable}}"])

        let prepared = try await RequestPreparer.prepare(configuration, context: context, decryptor: decryptor)
        let decryptedEnvelopes = await decryptor.requestedEnvelopes()

        XCTAssertEqual(headerValue("X-Service-Key", in: prepared.request), "manual value")
        XCTAssertTrue(decryptedEnvelopes.isEmpty)
        XCTAssertNil(prepared.referencedInputs["missingApiKeyVariable"])
        XCTAssertEqual(
            prepared.sensitiveRequestHeaderNames,
            ["authorization", "proxy-authorization", "cookie", "set-cookie", "x-service-key"])
        XCTAssertEqual(prepared.secretRequestHeaderNames, [])
        XCTAssertEqual(prepared.requestHeaderSources, ["x-service-key": .request])
    }

    func testManualRequestHeaderCanShadowMissingAPIKeyCredential() async throws {
        let configuration = HTTPRequestConfiguration(
            url: "https://example.test",
            headers: [HTTPField(name: "X-Service-Key", value: "manual value")],
            inheritsCollectionAuthentication: true
        )
        let collection = CollectionRequestDefaults(
            authentication: RequestAuthentication(kind: .apiKey, apiKeyHeaderName: "x-service-key")
        )

        let prepared = try await RequestPreparer.prepare(
            configuration, context: VariableContext(), decryptor: nil, collection: collection)

        XCTAssertEqual(headerValue("X-Service-Key", in: prepared.request), "manual value")
    }

    func testAPIKeyAuthenticationRejectsInvalidHeaderNamesAndValues() async throws {
        for headerName in ["", "X Service Key", "X:Service-Key", "{{headerName}}"] {
            let configuration = HTTPRequestConfiguration(
                url: "https://example.test",
                authentication: RequestAuthentication(
                    kind: .apiKey,
                    apiKeyHeaderName: headerName,
                    apiKey: SecretEnvelope(combined: "valid-key")
                )
            )

            do {
                _ = try await RequestPreparer.prepare(
                    configuration, context: VariableContext(), decryptor: FakeDecryptor(values: ["valid-key": "key"]))
                XCTFail("Expected invalid API key header name '\(headerName)' to fail.")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("header name"))
            }
        }

        for (combined, value) in [("empty-key", ""), ("control-key", "key\r\nvalue")] {
            let configuration = HTTPRequestConfiguration(
                url: "https://example.test",
                authentication: RequestAuthentication(
                    kind: .apiKey,
                    apiKeyHeaderName: "X-Service-Key",
                    apiKey: SecretEnvelope(combined: combined)
                )
            )

            do {
                _ = try await RequestPreparer.prepare(
                    configuration, context: VariableContext(), decryptor: FakeDecryptor(values: [combined: value]))
                XCTFail("Expected invalid API key value to fail.")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("API key"))
            }
        }
    }

    func testDisabledRequestHeaderDoesNotOverrideSelectedAPIKeyAuthentication() async throws {
        let apiKey = SecretEnvelope(combined: "selected-api-key")
        let configuration = HTTPRequestConfiguration(
            url: "https://example.test",
            headers: [HTTPField(name: "x-service-key", value: "disabled manual value", isEnabled: false)],
            authentication: RequestAuthentication(kind: .apiKey, apiKeyHeaderName: "X-Service-Key", apiKey: apiKey)
        )
        let decryptor = FakeDecryptor(values: [apiKey.combined: "selected API key value"])

        let prepared = try await RequestPreparer.prepare(
            configuration, context: VariableContext(), decryptor: decryptor)
        let decryptedEnvelopes = await decryptor.requestedEnvelopes()

        XCTAssertEqual(headerValue("X-Service-Key", in: prepared.request), "selected API key value")
        XCTAssertEqual(Set(decryptedEnvelopes), [apiKey.combined])
    }

    func testManualAuthorizationSkipsBasicUsernameAndPasswordResolution() async throws {
        let password = SecretEnvelope(combined: "unused-basic-password")
        let configuration = HTTPRequestConfiguration(
            url: "https://example.test",
            headers: [HTTPField(name: "aUtHoRiZaTiOn", value: "manual authorization")],
            authentication: RequestAuthentication(kind: .basic, username: "{{missingUsername}}", password: password)
        )
        let decryptor = FakeDecryptor(values: [:])

        let prepared = try await RequestPreparer.prepare(
            configuration, context: VariableContext(), decryptor: decryptor)
        let decryptedEnvelopes = await decryptor.requestedEnvelopes()

        XCTAssertEqual(headerValue("Authorization", in: prepared.request), "manual authorization")
        XCTAssertTrue(decryptedEnvelopes.isEmpty)
        XCTAssertNil(prepared.referencedInputs["missingUsername"])
    }

    func testExplicitNoneDoesNotInheritCollectionAPIKey() async throws {
        let collectionKey = SecretEnvelope(combined: "collection-api-key")
        let collection = CollectionRequestDefaults(
            authentication: RequestAuthentication(
                kind: .apiKey,
                apiKeyHeaderName: "X-Service-Key",
                apiKey: collectionKey
            ))
        let inheritedConfiguration = HTTPRequestConfiguration(
            url: "https://example.test", inheritsCollectionAuthentication: true)
        let inheritedDecryptor = FakeDecryptor(values: [collectionKey.combined: "collection api key"])

        let inherited = try await RequestPreparer.prepare(
            inheritedConfiguration,
            context: VariableContext(),
            decryptor: inheritedDecryptor,
            collection: collection
        )
        let inheritedEnvelopes = await inheritedDecryptor.requestedEnvelopes()

        XCTAssertEqual(headerValue("X-Service-Key", in: inherited.request), "collection api key")
        XCTAssertEqual(Set(inheritedEnvelopes), [collectionKey.combined])

        let explicitNoneConfiguration = HTTPRequestConfiguration(
            url: "https://example.test",
            authentication: RequestAuthentication(kind: .none),
            inheritsCollectionAuthentication: false
        )
        let explicitNoneDecryptor = FakeDecryptor(values: [collectionKey.combined: "collection api key"])
        let explicitNone = try await RequestPreparer.prepare(
            explicitNoneConfiguration,
            context: VariableContext(),
            decryptor: explicitNoneDecryptor,
            collection: collection
        )
        let explicitNoneEnvelopes = await explicitNoneDecryptor.requestedEnvelopes()

        XCTAssertNil(headerValue("X-Service-Key", in: explicitNone.request))
        XCTAssertTrue(explicitNoneEnvelopes.isEmpty)
        XCTAssertEqual(explicitNone.configuration.authentication.kind, .none)
        XCTAssertFalse(explicitNone.configuration.inheritsCollectionAuthentication)
    }

    func testCollectionHeadersUseScopePrecedenceAndSuppressInheritedNamesCaseInsensitively() async throws {
        let configuration = HTTPRequestConfiguration(
            url: "https://example.test",
            headers: [
                HTTPField(name: "X-Override", value: "first"),
                HTTPField(name: "x-override", value: "second"),
                HTTPField(name: "x-disabled", value: "unused", isEnabled: false),
            ]
        )
        let collection = CollectionRequestDefaults(headers: [
            HTTPField(name: "X-Override", value: "inherited"),
            HTTPField(name: "X-Collection", value: "{{winner}}"),
            HTTPField(name: "X-Disabled", value: "must be suppressed"),
        ])
        let context = VariableContext(
            global: ["winner": .plain("global")],
            collection: ["winner": .plain("collection")],
            request: ["winner": .plain("request")]
        )

        let prepared = try await RequestPreparer.prepare(
            configuration, context: context, decryptor: nil, collection: collection)

        XCTAssertEqual(headerValue("X-Override", in: prepared.request), "first,second")
        XCTAssertEqual(headerValue("X-Collection", in: prepared.request), "request")
        XCTAssertNil(headerValue("X-Disabled", in: prepared.request))
    }

    func testDisabledRequestNameSuppressesInheritedSecretWithoutResolvingEitherValue() async throws {
        let configuration = HTTPRequestConfiguration(
            url: "https://example.test",
            headers: [HTTPField(name: "{{suppressedName}}", value: "{{missingDisabledValue}}", isEnabled: false)]
        )
        let collection = CollectionRequestDefaults(headers: [
            HTTPField(name: "X-Private", value: "{{collectionSecret}}")
        ])
        let context = VariableContext(
            collection: ["collectionSecret": .encrypted(SecretEnvelope(combined: "inactive-collection-header"))],
            request: ["suppressedName": .plain("x-private")]
        )
        let decryptor = FakeDecryptor(values: [:])

        let prepared = try await RequestPreparer.prepare(
            configuration, context: context, decryptor: decryptor, collection: collection)
        let decryptedEnvelopes = await decryptor.requestedEnvelopes()

        XCTAssertNil(headerValue("X-Private", in: prepared.request))
        XCTAssertTrue(decryptedEnvelopes.isEmpty)
        XCTAssertNil(prepared.referencedInputs["missingDisabledValue"])
        XCTAssertEqual(
            prepared.sensitiveRequestHeaderNames,
            ["authorization", "proxy-authorization", "cookie", "set-cookie"]
        )
        XCTAssertEqual(prepared.secretRequestHeaderNames, [])
    }

    func testCollectionAuthenticationInheritanceUsesOnlyTheSelectedCredential() async throws {
        let requestToken = SecretEnvelope(combined: "request-token")
        let collectionToken = SecretEnvelope(combined: "collection-token")
        let configuration = HTTPRequestConfiguration(
            url: "https://example.test",
            authentication: RequestAuthentication(kind: .bearer, token: requestToken),
            inheritsCollectionAuthentication: true
        )
        let defaults = CollectionRequestDefaults(
            authentication: RequestAuthentication(kind: .bearer, token: collectionToken)
        )
        let collectionDecryptor = FakeDecryptor(values: [collectionToken.combined: "collection-secret"])

        let inherited = try await RequestPreparer.prepare(
            configuration, context: VariableContext(), decryptor: collectionDecryptor, collection: defaults)
        let inheritedEnvelopes = await collectionDecryptor.requestedEnvelopes()

        XCTAssertEqual(headerValue("Authorization", in: inherited.request), "Bearer collection-secret")
        XCTAssertEqual(inherited.requestHeaderSources, ["authorization": .collectionAuth])
        XCTAssertEqual(Set(inheritedEnvelopes), Set([collectionToken.combined]))
        XCTAssertEqual(inherited.configuration, configuration)
        XCTAssertThrowsError(try RequestPreparer.prepare(configuration))

        var explicitConfiguration = configuration
        explicitConfiguration.inheritsCollectionAuthentication = false
        let requestDecryptor = FakeDecryptor(values: [requestToken.combined: "request-secret"])
        let explicit = try await RequestPreparer.prepare(
            explicitConfiguration, context: VariableContext(), decryptor: requestDecryptor, collection: defaults)
        let explicitEnvelopes = await requestDecryptor.requestedEnvelopes()

        XCTAssertEqual(headerValue("Authorization", in: explicit.request), "Bearer request-secret")
        XCTAssertEqual(explicit.requestHeaderSources, ["authorization": .requestAuth])
        XCTAssertEqual(Set(explicitEnvelopes), Set([requestToken.combined]))
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
