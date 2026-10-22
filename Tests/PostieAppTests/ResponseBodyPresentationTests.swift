import Foundation
import XCTest
import PostieCore
@testable import PostieApp

final class ResponseBodyPresentationTests: XCTestCase {
    func testPDFDefaultsToPDFAndKeepsTextAvailable() {
        let contentType = BodyMediaType.contentType(for: [HTTPField(name: "Content-Type", value: "application/pdf")])

        XCTAssertEqual(ResponseBodyPresentationPolicy.defaultMode(for: contentType), .pdf)
        XCTAssertEqual(ResponseBodyPresentationPolicy.modes(for: contentType), [.text, .pdf])
    }

    func testHTMLOffersRenderedAsAnExplicitMode() {
        let contentType = BodyMediaType.contentType(for: [
            HTTPField(name: "Content-Type", value: "TEXT/HTML; charset=utf-8")
        ])

        XCTAssertEqual(ResponseBodyPresentationPolicy.defaultMode(for: contentType), .text)
        XCTAssertEqual(ResponseBodyPresentationPolicy.modes(for: contentType), [.text, .renderedHTML])
    }

    func testHTMLBaseURLUsesOnlyCapturedHTTPURLsWithoutUserInfo() throws {
        let captured = try XCTUnwrap(URL(string: "https://user:password@example.invalid/path/page?version=2#fragment"))
        let baseURL = try XCTUnwrap(ResponseBodyPresentationPolicy.htmlBaseURL(for: captured))
        let components = try XCTUnwrap(URLComponents(url: baseURL, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "example.invalid")
        XCTAssertEqual(components.path, "/path/page")
        XCTAssertEqual(components.query, "version=2")
        XCTAssertNil(components.user)
        XCTAssertNil(components.password)
        XCTAssertNil(components.fragment)
        XCTAssertNil(ResponseBodyPresentationPolicy.htmlBaseURL(for: URL(fileURLWithPath: "/tmp/page.html")))
        let relativeHTTPURL = try XCTUnwrap(URL(string: "http:/relative"))
        XCTAssertNil(ResponseBodyPresentationPolicy.htmlBaseURL(for: relativeHTTPURL))
    }

    func testCompleteHTMLSourceAcceptsExactLimitAndPreservesUTF8() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("response.html")
        let text = "é" + String(repeating: "a", count: CompleteHTMLSource.maximumBytes - 2)
        try Data(text.utf8).write(to: sourceURL)

        XCTAssertEqual(try CompleteHTMLSource.read(at: sourceURL), text)
    }

    func testCompleteHTMLSourceRejectsOversizeAndInvalidUTF8() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("response.html")

        try Data(repeating: 0x61, count: CompleteHTMLSource.maximumBytes + 1).write(to: sourceURL)
        XCTAssertThrowsError(try CompleteHTMLSource.read(at: sourceURL))

        try Data([0x3C, 0xFF, 0x3E]).write(to: sourceURL)
        XCTAssertThrowsError(try CompleteHTMLSource.read(at: sourceURL))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("postie-rendered-html-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
