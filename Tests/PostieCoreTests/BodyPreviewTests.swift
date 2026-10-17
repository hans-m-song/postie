import Foundation
import XCTest
@testable import PostieCore

final class BodyPreviewTests: XCTestCase {
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
