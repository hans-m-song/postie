import Foundation
import XCTest
@testable import PostieApp

@MainActor
final class ExternalResponseBodyExportTests: XCTestCase {
    func testPDFCopyIsExactPrivateAtomicAndRetainedForInjectedPreviewOpener() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sourceURL = workspace.appendingPathComponent("captured-response")
        let exportRoot = workspace.appendingPathComponent("exports", isDirectory: true)
        let expected = Data((0..<240_000).map { UInt8($0 % 251) })
        try expected.write(to: sourceURL)

        let exportedURL = try await ExternalResponseBodyExport.pdf(from: sourceURL, rootURL: exportRoot)
        var openedURL: URL?
        let openers = ExternalResponseBodyOpeners(
            preview: { openedURL = $0 },
            browser: { openedURL = $0 }
        )
        try await openers.preview(exportedURL)

        XCTAssertEqual(exportedURL.pathExtension, "pdf")
        XCTAssertEqual(try Data(contentsOf: exportedURL), expected)
        XCTAssertEqual(openedURL, exportedURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportedURL.path))

        let folderAttributes = try FileManager.default.attributesOfItem(
            atPath: exportedURL.deletingLastPathComponent().path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: exportedURL.path)
        XCTAssertEqual((folderAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: exportedURL.deletingLastPathComponent().path),
            ["response.pdf"])

        let secondURL = try await ExternalResponseBodyExport.pdf(from: sourceURL, rootURL: exportRoot)
        XCTAssertNotEqual(secondURL.deletingLastPathComponent(), exportedURL.deletingLastPathComponent())
        try FileManager.default.removeItem(at: sourceURL)
        XCTAssertEqual(try Data(contentsOf: exportedURL), expected)
        XCTAssertEqual(try Data(contentsOf: secondURL), expected)
    }

    func testUnreadableSourceLeavesNoPartialExport() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let exportRoot = workspace.appendingPathComponent("exports", isDirectory: true)
        do {
            _ = try await ExternalResponseBodyExport.pdf(
                from: workspace.appendingPathComponent("missing-source"), rootURL: exportRoot)
            XCTFail("An unavailable captured body must not produce an export")
        } catch {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: exportRoot.path), [])
        }
    }

    func testHTMLExportAddsCapturedBaseAfterDoctypeAndPreservesSourceAroundInsertion() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = "<!doctype html><html><head><title>captured</title></head><body>body</body></html>"
        let output = try await exportHTML(source, workspace: workspace)

        XCTAssertTrue(
            output.hasPrefix(
                "<!doctype html><html><head><base href=\"https://example.invalid/root/page?version=2\"><title>captured")
        )
        XCTAssertTrue(output.hasSuffix("</head><body>body</body></html>"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("content-security-policy"))
    }

    func testHTMLFragmentKeepsDoctypeBeforeInsertedHead() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let output = try await exportHTML("<!doctype html><p>captured fragment</p>", workspace: workspace)

        XCTAssertTrue(
            output.hasPrefix(
                "<!doctype html><head><base href=\"https://example.invalid/root/page?version=2\"></head><p>"))
    }

    func testHTMLExportResolvesRelativeExistingBaseAndLeavesAbsoluteBaseUntouched() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let relative =
            "<html><head><base target='_blank'><base href='../assets/?x=1&amp;y=2'><title>x</title></head></html>"
        let relativeOutput = try await exportHTML(relative, workspace: workspace)

        XCTAssertTrue(
            relativeOutput.contains("<base target='_blank'><base href='https://example.invalid/assets/?x=1&amp;y=2'>"))
        XCTAssertTrue(relativeOutput.contains("<title>x</title>"))

        let absolute = "<html><head><base href='https://cdn.example.invalid/assets/'><title>x</title></head></html>"
        let absoluteOutput = try await exportHTML(absolute, workspace: workspace)
        XCTAssertEqual(absoluteOutput, absolute)
    }

    func testHTMLExportIgnoresCommentScriptAndTemplateBaseTags() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source =
            "<!doctype html><!-- <base href='/comment/'> --><html><head><script>const x = '<base href=\"/script/\">';</script><template><base href='/template/'></template><title>x</title></head><body>y</body></html>"
        let output = try await exportHTML(source, workspace: workspace)

        XCTAssertTrue(
            output.hasPrefix(
                "<!doctype html><!-- <base href='/comment/'> --><html><head><base href=\"https://example.invalid/root/page?version=2\">"
            ))
        XCTAssertTrue(output.contains("<base href='/template/'>"))
        XCTAssertTrue(output.contains("const x = '<base href=\"/script/\">';"))
    }

    func testRelativeBaseEntityScanIsBoundedForLongAmpersandRuns() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let value = String(repeating: "&", count: 200_000)
        let source = "<html><head><base href='?q=\(value)'></head></html>"
        let output = try await exportHTML(source, workspace: workspace)
        let escapedValue = value.replacingOccurrences(of: "&", with: "&amp;")

        XCTAssertTrue(output.contains("<base href='https://example.invalid/root/page?q=\(escapedValue)'>"))
    }

    func testRelativeBaseRejectsUnsupportedNamedCharacterReferences() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }

        for entity in ["eacute", "Tab"] {
            do {
                _ = try await exportHTMLFile(
                    "<html><head><base href='?q=&\(entity);'></head></html>",
                    workspace: workspace
                )
                XCTFail("Expected unsupported character reference &\(entity); to fail safely.")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("character reference"))
            }
        }
    }

    func testInjectedOpenersReceiveHTMLCopyWithoutLaunchingBrowser() async throws {
        let workspace = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let exportedURL = try await exportHTMLFile(
            "<html><head></head><body>captured</body></html>", workspace: workspace)
        var openedURLs: [URL] = []
        let openers = ExternalResponseBodyOpeners(
            preview: { openedURLs.append($0) },
            browser: { openedURLs.append($0) }
        )

        try await openers.browser(exportedURL)

        XCTAssertEqual(openedURLs, [exportedURL])
        XCTAssertEqual(exportedURL.pathExtension, "html")
    }

    private func exportHTML(_ source: String, workspace: URL) async throws -> String {
        let exportURL = try await exportHTMLFile(source, workspace: workspace)
        return try String(contentsOf: exportURL, encoding: .utf8)
    }

    private func exportHTMLFile(_ source: String, workspace: URL) async throws -> URL {
        let sourceURL = workspace.appendingPathComponent("captured-response")
        let rootURL = workspace.appendingPathComponent("exports", isDirectory: true)
        try Data(source.utf8).write(to: sourceURL)
        return try await ExternalResponseBodyExport.html(
            from: sourceURL,
            baseURL: URL(string: "https://example.invalid/root/page?version=2#fragment"),
            rootURL: rootURL
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("postie-external-response-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
