import Foundation
import XCTest
@testable import PostieCore

final class BodyPreviewTests: XCTestCase {
    func testPrettyJSONPreservesLexemesAndSourceAndBoundsExpansion() throws {
        let source = Data(#"{"a":1e2,"a":"é\\\"","empty":[],"nested":{"ok":true}}"#.utf8)
        let file = try bodyFile(source)
        defer { try? FileManager.default.removeItem(at: file) }
        let pretty = try JSONPresentation.pretty(at: file)
        XCTAssertTrue(pretty.contains("1e2"))
        XCTAssertEqual(pretty.components(separatedBy: "\"a\"").count, 3)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(pretty.utf8)))
        XCTAssertEqual(try Data(contentsOf: file), source)
        XCTAssertThrowsError(try JSONPresentation.pretty(source, maximumBytes: source.count))
        XCTAssertThrowsError(try JSONPresentation.pretty(Data("{invalid".utf8)))
    }

    func testPreviewReadsBoundedUTF8PrefixAndMarksTruncation() throws {
        let file = try bodyFile(Data("hello world".utf8))
        defer { try? FileManager.default.removeItem(at: file) }

        let preview = try ResponseBodyReader.preview(at: file, maximumBytes: 5)

        XCTAssertEqual(preview.text, "hello")
        XCTAssertTrue(preview.isTruncated)
        XCTAssertFalse(preview.isBinary)
    }

    func testPreviewTrimsPartialUTF8AtLimit() throws {
        let file = try bodyFile(Data("abé".utf8))
        defer { try? FileManager.default.removeItem(at: file) }

        let preview = try ResponseBodyReader.preview(at: file, maximumBytes: 3)

        XCTAssertEqual(preview.text, "ab")
        XCTAssertTrue(preview.isTruncated)
        XCTAssertFalse(preview.isBinary)
    }

    func testPreviewLeavesBinaryDataUnavailableAndPreservesTruncation() throws {
        let file = try bodyFile(Data([0x00, 0x01, 0xFE, 0xAB]))
        defer { try? FileManager.default.removeItem(at: file) }

        let preview = try ResponseBodyReader.preview(at: file, maximumBytes: 3)

        XCTAssertEqual(preview.text, "")
        XCTAssertTrue(preview.isTruncated)
        XCTAssertTrue(preview.isBinary)
    }

    func testPreviewClassifiesUnicodeControlCharactersAsBinary() throws {
        let file = try bodyFile(Data("\u{0085}".utf8))
        defer { try? FileManager.default.removeItem(at: file) }

        let preview = try ResponseBodyReader.preview(at: file)

        XCTAssertEqual(preview.text, "")
        XCTAssertTrue(preview.isBinary)
    }

    func testPreviewSupportsZeroLimitAndRejectsNegativeLimit() throws {
        let file = try bodyFile(Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: file) }

        let preview = try ResponseBodyReader.preview(at: file, maximumBytes: 0)
        XCTAssertEqual(preview.text, "")
        XCTAssertTrue(preview.isTruncated)
        XCTAssertFalse(preview.isBinary)
        XCTAssertThrowsError(try ResponseBodyReader.preview(at: file, maximumBytes: -1))
    }

    private func bodyFile(_ data: Data) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("postie-body-\(UUID().uuidString)")
        try data.write(to: file, options: .atomic)
        return file
    }
}
