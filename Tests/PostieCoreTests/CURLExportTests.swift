import Foundation
import XCTest
@testable import PostieCore

private struct ParsedCURLToken {
    let value: String
    let hasQuotedSegment: Bool
    let hasUnquotedContent: Bool
}

final class CURLExportTests: XCTestCase {
    func testTextBodyAndHeadersBecomeShellQuotedLiteralArguments() throws {
        let body = "@literal 'quoted' $HOME `touch marker`\nline two \\literal café"
        let header = "O'Reilly $HOME `echo` café"
        let configuration = HTTPRequestConfiguration(
            method: "GET",
            url: "https://example.test/items/[1]",
            headers: [HTTPField(name: "X-Trace", value: header), HTTPField(name: "X-Empty", value: "")],
            body: body,
            bodyEnabled: true,
            options: HTTPOptions(followRedirects: true, inactivityTimeout: 7.5, overallTimeout: 42.25)
        )
        let request = makeRequest(
            url: "https://example.test/items/[1]",
            method: "GET",
            headers: ["X-Trace": header, "X-Empty": ""],
            body: Data(body.utf8)
        )
        let prepared = makePrepared(configuration: configuration, request: request)

        let arguments = try parseCommand(CURLExport.command(for: prepared, configuration: configuration))

        XCTAssertEqual(arguments.first, "curl")
        XCTAssertTrue(arguments.contains("--disable"))
        XCTAssertTrue(arguments.contains("--globoff"))
        XCTAssertEqual(value(after: "--request", in: arguments), "GET")
        XCTAssertEqual(value(after: "--data-raw", in: arguments), body)
        XCTAssertEqual(value(after: "--header", matching: "X-Trace:", in: arguments), "X-Trace: \(header)")
        XCTAssertEqual(value(after: "--header", matching: "X-Empty", in: arguments), "X-Empty;")
        XCTAssertEqual(value(after: "--header", matching: "Content-Type:", in: arguments), "Content-Type:")
        XCTAssertTrue(arguments.contains("--location"))
        XCTAssertEqual(value(after: "--max-redirs", in: arguments), "10")
        XCTAssertEqual(value(after: "--proto-redir", in: arguments), "=http,https")
        XCTAssertEqual(value(after: "--max-time", in: arguments), "42.25")
        XCTAssertEqual(value(after: "--connect-timeout", in: arguments), "7.5")
        XCTAssertEqual(value(after: "--speed-time", in: arguments), "8")
        XCTAssertEqual(value(after: "--url", in: arguments), request.url?.absoluteString)
    }

    func testCommandUsesReadableOptionLinesAndQuotesOnlyValues() throws {
        let configuration = HTTPRequestConfiguration(method: "GET", url: "https://example.test")
        let request = makeRequest(url: "https://example.test", method: "GET")
        let prepared = makePrepared(configuration: configuration, request: request)

        let command = try CURLExport.command(for: prepared, configuration: configuration)
        let lines = command.components(separatedBy: "\n")

        XCTAssertEqual(lines.first, "curl \\")
        XCTAssertTrue(lines.dropFirst().allSatisfy { $0.hasPrefix("  --") })
        XCTAssertTrue(lines.dropLast().allSatisfy { $0.hasSuffix("\\") })
        XCTAssertTrue(lines.dropFirst().dropLast().allSatisfy { $0.hasSuffix(" \\") })
        XCTAssertFalse(lines.last?.hasSuffix("\\") ?? true)
        XCTAssertTrue(command.contains("  --disable \\\n"))
        XCTAssertTrue(command.contains("  --proto '=http,https' \\\n"))
        XCTAssertTrue(command.contains("  --request 'GET' \\\n"))
        XCTAssertFalse(command.contains("'curl'"))
        XCTAssertFalse(command.contains("'--disable'"))
    }

    func testParameterStartingWithOptionPrefixRemainsAQuotedValue() throws {
        let configuration = HTTPRequestConfiguration(
            method: "POST",
            url: "https://example.test",
            body: "--url",
            bodyEnabled: true
        )
        let request = makeRequest(
            url: "https://example.test",
            method: "POST",
            body: Data("--url".utf8)
        )
        let prepared = makePrepared(configuration: configuration, request: request)

        let command = try CURLExport.command(for: prepared, configuration: configuration)
        let arguments = try parseCommand(command)

        XCTAssertTrue(command.contains("  --data-raw '--url' \\\n"))
        XCTAssertEqual(value(after: "--data-raw", in: arguments), "--url")
        XCTAssertEqual(
            value(after: "--url", matching: "https://example.test", in: arguments), request.url?.absoluteString
        )
    }

    func testDisabledBodyDoesNotExportPreparedBodyData() throws {
        let configuration = HTTPRequestConfiguration(
            method: "POST",
            url: "https://example.test",
            body: "ignored configuration body",
            bodyEnabled: false
        )
        let request = makeRequest(
            url: "https://example.test",
            method: "POST",
            body: Data("stale prepared data".utf8)
        )
        let prepared = makePrepared(configuration: configuration, request: request)

        let arguments = try parseCommand(CURLExport.command(for: prepared, configuration: configuration))

        XCTAssertEqual(value(after: "--request", in: arguments), "POST")
        XCTAssertFalse(arguments.contains("--data-raw"))
        XCTAssertFalse(arguments.contains("--data-binary"))
        XCTAssertFalse(arguments.contains("--form"))
        XCTAssertFalse(arguments.contains("--form-string"))
        XCTAssertFalse(arguments.contains("stale prepared data"))
    }

    func testEnabledEmptyTextBodyRemainsPresent() throws {
        let configuration = HTTPRequestConfiguration(
            method: "GET",
            url: "https://example.test",
            bodyEnabled: true
        )
        let request = makeRequest(url: "https://example.test", method: "GET", body: Data())
        let prepared = makePrepared(configuration: configuration, request: request)

        let arguments = try parseCommand(CURLExport.command(for: prepared, configuration: configuration))

        XCTAssertEqual(value(after: "--request", in: arguments), "GET")
        XCTAssertEqual(value(after: "--data-raw", in: arguments), "")
    }

    func testHeadRequestUsesHeaderOnlyModeAndRejectsEnabledBody() throws {
        let configuration = HTTPRequestConfiguration(method: "HEAD", url: "https://example.test")
        let request = makeRequest(url: "https://example.test", method: "HEAD")
        let prepared = makePrepared(configuration: configuration, request: request)

        let arguments = try parseCommand(CURLExport.command(for: prepared, configuration: configuration))

        XCTAssertEqual(value(after: "--request", in: arguments), "HEAD")
        XCTAssertTrue(arguments.contains("--head"))

        var bodyConfiguration = configuration
        bodyConfiguration.bodyEnabled = true
        XCTAssertThrowsError(try CURLExport.command(for: prepared, configuration: bodyConfiguration))
    }

    func testInheritedAuthenticationUsesResolvedPreparedHeader() async throws {
        let envelope = SecretEnvelope(combined: "synthetic-envelope")
        let token = "synthetic'key'$HOME`echo`"
        let configuration = HTTPRequestConfiguration(
            method: "GET",
            url: "https://example.test/private",
            inheritsCollectionAuthentication: true
        )
        let defaults = CollectionRequestDefaults(
            authentication: RequestAuthentication(kind: .bearer, token: envelope)
        )
        let prepared = try await RequestPreparer.prepare(
            configuration,
            context: VariableContext(),
            decryptor: FixedDecryptor(value: token),
            collection: defaults
        )

        let arguments = try parseCommand(CURLExport.command(for: prepared, configuration: configuration))

        XCTAssertEqual(
            value(after: "--header", matching: "Authorization:", in: arguments), "Authorization: Bearer \(token)"
        )
        XCTAssertEqual(prepared.requestHeaderSources["authorization"], .collectionAuth)
    }

    func testRawFileBodyKeepsTheOriginalAbsolutePath() async throws {
        let fileURL = try makeTemporaryFile(named: "raw, upload; 'quoted' $HOME.bin")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let configuration = HTTPRequestConfiguration(
            method: "PUT",
            url: "https://example.test/upload",
            bodyEnabled: true,
            bodyKind: .rawFile,
            rawFile: HTTPFileReference(path: fileURL.path)
        )
        let prepared = try await RequestPreparer.prepare(configuration, context: .init(), decryptor: nil)

        let arguments = try parseCommand(CURLExport.command(for: prepared, configuration: configuration))

        XCTAssertEqual(value(after: "--request", in: arguments), "PUT")
        XCTAssertEqual(value(after: "--data-binary", in: arguments), "@\(fileURL.path)")
        XCTAssertTrue(arguments.contains("Content-Type: application/octet-stream"))
    }

    func testMultipartUsesPreparedTextAndQuotesFileSyntax() async throws {
        let fileURL = try makeTemporaryFile(named: "upload, part; 'quoted' \"slash\\name.bin")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let textID = UUID()
        let fileID = UUID()
        let filename = "final,;\"quoted\"\\name.bin"
        let text = "@literal <body>;type=application/json"
        let configuration = HTTPRequestConfiguration(
            method: "POST",
            url: "https://example.test/upload",
            bodyEnabled: true,
            bodyKind: .multipart,
            multipartParts: [
                HTTPMultipartPart(id: textID, name: "note", kind: .text, text: text),
                HTTPMultipartPart(
                    id: fileID,
                    name: "upload",
                    kind: .file,
                    file: HTTPFileReference(
                        path: fileURL.path,
                        filename: filename,
                        contentType: "text/plain; charset=utf-8"
                    )
                ),
            ]
        )
        let prepared = try await RequestPreparer.prepare(configuration, context: .init(), decryptor: nil)

        let arguments = try parseCommand(CURLExport.command(for: prepared, configuration: configuration))

        XCTAssertEqual(value(after: "--form-string", in: arguments), "note=\(text)")
        let fileForm = try XCTUnwrap(value(after: "--form", matching: "upload=@", in: arguments))
        XCTAssertEqual(
            fileForm,
            "upload=@\"\(escapeFormValue(fileURL.path))\";filename=\"\(escapeFormValue(filename))\";"
                + "type=text/plain; charset=utf-8"
        )
        XCTAssertFalse(arguments.contains { $0.hasPrefix("Content-Type: multipart/form-data; boundary=") })
        XCTAssertFalse(arguments.contains { $0.hasPrefix("Content-Length:") })
        XCTAssertFalse(arguments.contains(prepared.uploadBody!.contentType))
    }

    func testMultipartRejectsExplicitContentTypeBecauseCurlOwnsItsBoundary() async throws {
        let configuration = HTTPRequestConfiguration(
            method: "POST",
            url: "https://example.test/upload",
            headers: [HTTPField(name: "Content-Type", value: "multipart/form-data; boundary=postie-boundary")],
            bodyEnabled: true,
            bodyKind: .multipart,
            multipartParts: [HTTPMultipartPart(name: "note", kind: .text, text: "body")]
        )
        let prepared = try await RequestPreparer.prepare(configuration, context: .init(), decryptor: nil)

        XCTAssertThrowsError(try CURLExport.command(for: prepared, configuration: configuration)) {
            XCTAssertEqual(
                $0.localizedDescription,
                "Explicit multipart Content-Type or Content-Length cannot be preserved with cURL's generated body."
            )
        }
    }

    func testMultipartRejectsCurlFormAttributeInjectionInFileContentType() async throws {
        let fileURL = try makeTemporaryFile(named: "synthetic upload.bin")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        var configuration = HTTPRequestConfiguration(
            method: "POST",
            url: "https://example.test/upload",
            bodyEnabled: true,
            bodyKind: .multipart,
            multipartParts: [
                HTTPMultipartPart(
                    name: "upload",
                    kind: .file,
                    file: HTTPFileReference(path: fileURL.path, contentType: "text/plain; filename=other.bin")
                )
            ]
        )
        for attribute in ["filename=other.bin", "headers=other", "encoder=base64", "type=other"] {
            configuration.multipartParts[0].file?.contentType = "text/plain; \(attribute)"
            let prepared = try await RequestPreparer.prepare(configuration, context: .init(), decryptor: nil)
            XCTAssertThrowsError(try CURLExport.command(for: prepared, configuration: configuration)) {
                XCTAssertEqual(
                    $0.localizedDescription,
                    "A multipart file Content-Type cannot be represented safely in cURL form syntax."
                )
            }
        }
    }

    func testCommandParserRejectsUnquotedShellSyntax() {
        for command in [
            "curl --url 'https://example.test'; touch marker",
            "curl --url $(touch marker)",
            "curl --url 'https://example.test' && echo unsafe",
        ] {
            XCTAssertThrowsError(try parseCommand(command), command)
        }
    }

    func testNulInPreparedTextBodyIsRejected() {
        let configuration = HTTPRequestConfiguration(
            method: "POST",
            url: "https://example.test",
            bodyEnabled: true
        )
        let request = makeRequest(
            url: "https://example.test",
            method: "POST",
            body: Data([0x61, 0x00, 0x62])
        )
        let prepared = makePrepared(configuration: configuration, request: request)

        XCTAssertThrowsError(try CURLExport.command(for: prepared, configuration: configuration))
    }

    private func makeRequest(
        url: String,
        method: String,
        headers: [String: String] = [:],
        body: Data? = nil
    ) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = body
        return request
    }

    private func makePrepared(
        configuration: HTTPRequestConfiguration,
        request: URLRequest
    ) -> PreparedHTTPRequest {
        PreparedHTTPRequest(configuration: configuration, request: request, referencedInputs: [:])
    }

    private func makeTemporaryFile(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("postie-curl-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent(name)
        try Data("synthetic upload bytes".utf8).write(to: file)
        return file
    }

    private func value(after option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private func value(after option: String, matching prefix: String, in arguments: [String]) -> String? {
        for index in arguments.indices where arguments[index] == option {
            guard arguments.indices.contains(index + 1) else { continue }
            if arguments[index + 1].hasPrefix(prefix) { return arguments[index + 1] }
        }
        return nil
    }

    private func escapeFormValue(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func parseCommand(_ command: String) throws -> [String] {
        enum ParseError: Error { case malformedQuoting, unsafeUnquotedCharacter }

        let flags: Set<String> = ["--disable", "--globoff", "--head", "--location"]
        let optionsWithValues: Set<String> = [
            "--connect-timeout", "--data-binary", "--data-raw", "--form", "--form-string", "--header",
            "--max-redirs", "--max-time", "--proto", "--proto-redir", "--request", "--speed-limit",
            "--speed-time", "--url",
        ]
        var tokens: [ParsedCURLToken] = []
        var argument = ""
        var inSingleQuotes = false
        var hasArgument = false
        var hasQuotedSegment = false
        var hasUnquotedContent = false
        var afterSeparator = false
        var lastSeparatorWasSpace = false
        let characters = Array(command)
        var index = 0

        func finishArgument() throws {
            guard hasArgument else { throw ParseError.malformedQuoting }
            tokens.append(
                ParsedCURLToken(
                    value: argument,
                    hasQuotedSegment: hasQuotedSegment,
                    hasUnquotedContent: hasUnquotedContent
                )
            )
            argument = ""
            hasArgument = false
            hasQuotedSegment = false
            hasUnquotedContent = false
        }

        while index < characters.count {
            let character = characters[index]
            if inSingleQuotes {
                if character == "'" {
                    inSingleQuotes = false
                } else {
                    argument.append(character)
                }
            } else if character == "'" {
                inSingleQuotes = true
                hasArgument = true
                hasQuotedSegment = true
                afterSeparator = false
                lastSeparatorWasSpace = false
            } else if character == " " {
                try finishArgument()
                afterSeparator = true
                lastSeparatorWasSpace = true
            } else if character == "\\" {
                guard characters.indices.contains(index + 1) else {
                    throw ParseError.unsafeUnquotedCharacter
                }
                if characters[index + 1] == "\n" {
                    guard lastSeparatorWasSpace else { throw ParseError.malformedQuoting }
                    index += 2
                    let indentationStart = index
                    while characters.indices.contains(index), characters[index] == " " {
                        index += 1
                    }
                    guard index - indentationStart == 2 else { throw ParseError.malformedQuoting }
                    afterSeparator = true
                    lastSeparatorWasSpace = false
                    continue
                }
                guard characters[index + 1] == "'" else { throw ParseError.unsafeUnquotedCharacter }
                index += 1
                argument.append(characters[index])
                hasArgument = true
                afterSeparator = false
                lastSeparatorWasSpace = false
            } else {
                argument.append(character)
                hasArgument = true
                hasUnquotedContent = true
                afterSeparator = false
                lastSeparatorWasSpace = false
            }
            index += 1
        }

        guard !inSingleQuotes, hasArgument, !afterSeparator else { throw ParseError.malformedQuoting }
        try finishArgument()
        guard let commandToken = tokens.first,
            commandToken.value == "curl",
            !commandToken.hasQuotedSegment,
            commandToken.hasUnquotedContent
        else {
            throw ParseError.unsafeUnquotedCharacter
        }

        var tokenIndex = 1
        while tokenIndex < tokens.count {
            let option = tokens[tokenIndex]
            guard !option.hasQuotedSegment, option.hasUnquotedContent else {
                throw ParseError.unsafeUnquotedCharacter
            }
            if flags.contains(option.value) {
                tokenIndex += 1
                continue
            }
            guard optionsWithValues.contains(option.value), tokens.indices.contains(tokenIndex + 1),
                tokens[tokenIndex + 1].hasQuotedSegment,
                !tokens[tokenIndex + 1].hasUnquotedContent
            else {
                throw ParseError.unsafeUnquotedCharacter
            }
            tokenIndex += 2
        }

        return tokens.map(\.value)
    }
}

private struct FixedDecryptor: SecretValueDecrypting {
    let value: String

    func decrypt(_ envelope: SecretEnvelope) async throws -> String {
        value
    }
}
