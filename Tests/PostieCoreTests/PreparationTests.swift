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

    private func headerValue(_ name: String, in request: URLRequest) -> String? {
        request.allHTTPHeaderFields?.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}
