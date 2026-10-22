import CoreGraphics
import Foundation
import PDFKit
import XCTest
@testable import PostieApp

@MainActor
final class PDFBodyPreviewTests: XCTestCase {
    func testAutomaticPreviewLimitIsExactlyTwentyFiveMillionBytes() {
        XCTAssertFalse(PDFBodyPreviewPolicy.requiresExplicitLoad(byteCount: 25_000_000))
        XCTAssertTrue(PDFBodyPreviewPolicy.requiresExplicitLoad(byteCount: 25_000_001))
    }

    func testLargePDFDoesNotLoadUntilExplicitlyAllowed() throws {
        let pdfURL = try makePDF()
        defer { try? FileManager.default.removeItem(at: pdfURL.deletingLastPathComponent()) }

        let resource = makeResource(url: pdfURL)
        let controller = PDFBodyPreviewController()

        controller.loadIfNeeded(resource: resource, byteCount: 25_000_001, allowsLargePreview: false)

        XCTAssertEqual(controller.state, .requiresConfirmation)
        XCTAssertNil(controller.document)

        controller.loadIfNeeded(resource: resource, byteCount: 25_000_001, allowsLargePreview: true)

        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(controller.document?.pageCount, 1)
    }

    func testSameResourceUpdateKeepsTheLoadedDocument() throws {
        let pdfURL = try makePDF()
        defer { try? FileManager.default.removeItem(at: pdfURL.deletingLastPathComponent()) }

        let resource = makeResource(url: pdfURL)
        let controller = PDFBodyPreviewController()
        controller.loadIfNeeded(resource: resource, byteCount: 100, allowsLargePreview: false)
        let initialDocument = try XCTUnwrap(controller.document)

        controller.loadIfNeeded(resource: resource, byteCount: 100, allowsLargePreview: false)

        XCTAssertTrue(controller.document === initialDocument)
    }

    func testLockedPDFRequiresAValidPassword() throws {
        let password = "synthetic-password"
        let pdfURL = try makePDF(password: password)
        defer { try? FileManager.default.removeItem(at: pdfURL.deletingLastPathComponent()) }

        let controller = PDFBodyPreviewController()
        controller.loadIfNeeded(
            resource: makeResource(url: pdfURL),
            byteCount: 100,
            allowsLargePreview: false
        )

        XCTAssertEqual(controller.state, .passwordRequired)
        XCTAssertFalse(controller.unlock(with: "wrong-password"))
        XCTAssertEqual(controller.state, .incorrectPassword)
        XCTAssertTrue(controller.unlock(with: password))
        XCTAssertEqual(controller.state, .ready)
        let reopened = PDFBodyPreviewController()
        reopened.loadIfNeeded(resource: makeResource(url: pdfURL), byteCount: 100, allowsLargePreview: false)
        XCTAssertEqual(reopened.state, .passwordRequired)
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url: pdfURL)).isLocked)
    }

    func testInvalidPDFUsesUnreadableState() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdfURL = directory.appendingPathComponent("invalid.pdf")
        try Data("not a PDF".utf8).write(to: pdfURL)

        let controller = PDFBodyPreviewController()
        controller.loadIfNeeded(
            resource: makeResource(url: pdfURL),
            byteCount: 9,
            allowsLargePreview: false
        )

        XCTAssertEqual(controller.state, .unreadable)
        XCTAssertNil(controller.document)
    }

    func testResourceInvalidationClearsPDFKitBeforeRelease() async throws {
        let pdfURL = try makePDF()
        defer { try? FileManager.default.removeItem(at: pdfURL.deletingLastPathComponent()) }

        let controller = PDFBodyPreviewController()
        let pdfView = PDFView()
        var viewWasClearedBeforeRelease = false
        let resource = ResponseBodyResource(
            url: pdfURL,
            origin: .live(UUID()),
            release: {
                viewWasClearedBeforeRelease = controller.document == nil && pdfView.document == nil
            }
        )

        controller.loadIfNeeded(resource: resource, byteCount: 100, allowsLargePreview: false)
        controller.attach(to: pdfView)
        XCTAssertNotNil(pdfView.document)

        await resource.invalidate()

        XCTAssertTrue(viewWasClearedBeforeRelease)
        XCTAssertNil(controller.document)
        XCTAssertNil(pdfView.document)
        XCTAssertEqual(controller.state, .unavailable)
    }

    private func makeResource(url: URL) -> ResponseBodyResource {
        ResponseBodyResource(url: url, origin: .live(UUID()), release: {})
    }

    private func makePDF(password: String? = nil) throws -> URL {
        let directory = try makeTemporaryDirectory()
        let pdfURL = directory.appendingPathComponent("response.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        var options: [String: Any] = [:]
        if let password {
            options[kCGPDFContextUserPassword as String] = password
            options[kCGPDFContextOwnerPassword as String] = "synthetic-owner-password"
        }

        guard let context = CGContext(pdfURL as CFURL, mediaBox: &mediaBox, options as CFDictionary) else {
            throw FixtureError.couldNotCreatePDF
        }

        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return pdfURL
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("postie-pdf-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private enum FixtureError: Error {
        case couldNotCreatePDF
    }
}
