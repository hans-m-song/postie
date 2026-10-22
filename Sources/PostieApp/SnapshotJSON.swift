import Foundation
import PostieCore

enum SnapshotJSONExporter {
    static let maximumBodyPreviewBytes = 1_048_576

    static func encode(_ snapshot: OpenedSnapshot) throws -> String {
        let preview = try responseBodyPreview(for: snapshot.response)
        let context = snapshot.context

        var capturedContext: [String: Any] = ["available": context != nil]
        var request: [String: Any]
        var observedRequest: [String: Any]

        if let context {
            capturedContext["preparationVersion"] = context.preparation.preparationVersion
            capturedContext["referencedInputs"] = context.preparation.referencedInputs.keys.sorted().reduce(
                into: [String: Any]()
            ) {
                result, name in
                guard let input = context.preparation.referencedInputs[name] else { return }
                result[name] = [
                    "value": input.value,
                    "scope": input.scope.rawValue,
                    "isSecret": input.isSecret,
                ]
            }
            capturedContext["authentication"] = authentication(context.preparation.authentication)
            request = transport(context.preparation.submitted)
            observedRequest = transport(context.observedTransport)
        } else {
            let reason = snapshot.contextError ?? "Captured request context is unavailable."
            capturedContext["error"] = reason
            request = ["available": false, "unavailableReason": reason]
            observedRequest = ["available": false, "unavailableReason": reason]
        }

        var response: [String: Any] = [
            "statusCode": snapshot.response.statusCode,
            "durationSeconds": snapshot.response.duration,
            "redirectLimitReached": snapshot.response.redirectLimitReached,
            "headers": snapshot.response.responseHeaders.map { header($0) },
            "redirects": snapshot.response.redirects.map { redirect($0, requestDetailsAvailable: context != nil) },
            "body": preview,
        ]

        if let context {
            response["finalURL"] = context.observedTransport.url.absoluteString
            response["method"] = context.observedTransport.method
        }

        let document: [String: Any] = [
            "snapshot": summary(snapshot.summary),
            "capturedContext": capturedContext,
            "request": request,
            "observedRequest": observedRequest,
            "response": response,
        ]

        do {
            let data = try JSONSerialization.data(
                withJSONObject: document,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            guard let string = String(data: data, encoding: .utf8) else {
                throw SnapshotJSONExportError.encodingFailed
            }
            return string
        } catch let error as SnapshotJSONExportError {
            throw error
        } catch {
            throw SnapshotJSONExportError.encodingFailed
        }
    }

    private static func summary(_ snapshot: SavedSnapshot) -> [String: Any] {
        [
            "id": snapshot.id.uuidString,
            "name": snapshot.name,
            "capturedAt": ISO8601DateFormatter().string(from: snapshot.capturedAt),
            "source": [
                "collectionId": snapshot.source.identity.collectionID.uuidString,
                "requestId": snapshot.source.identity.requestID.uuidString,
                "collectionName": snapshot.source.collectionName,
                "requestName": snapshot.source.requestName,
            ],
        ]
    }

    private static func authentication(_ authentication: SnapshotAuthenticationInput) -> [String: Any] {
        var value: [String: Any] = [
            "kind": authentication.kind.rawValue,
            "username": authentication.username,
        ]
        if let apiKeyHeaderName = authentication.apiKeyHeaderName {
            value["apiKeyHeaderName"] = apiKeyHeaderName
        }
        if let resolvedSecret = authentication.resolvedSecret {
            value["resolvedSecret"] = resolvedSecret
        }
        return value
    }

    private static func transport(_ request: SnapshotTransportRequest) -> [String: Any] {
        var result: [String: Any] = [
            "available": true,
            "method": request.method,
            "url": request.url.absoluteString,
            "headers": request.headers.map {
                header(
                    $0,
                    source: request.headerSources[$0.name.lowercased()],
                    isSensitive: request.sensitiveNames.contains($0.name.lowercased()),
                    isSecret: request.secretNames.contains($0.name.lowercased())
                )
            },
            "body": request.body as Any? ?? NSNull(),
        ]
        if let upload = request.uploadBody {
            result["uploadBody"] = [
                "kind": upload.kind.rawValue, "contentType": upload.contentType,
                "byteCount": upload.byteCount, "binaryOmitted": upload.binaryOmitted,
                "selfContainedReplayAvailable": false,
                "files": upload.files.map { file -> [String: Any] in
                    var value: [String: Any] = [
                        "filename": file.filename, "contentType": file.contentType, "byteCount": file.byteCount,
                    ]
                    if let name = file.partName { value["partName"] = name }
                    if let hash = file.sha256 { value["sha256"] = hash }
                    return value
                },
            ]
            if let parts = upload.parts, var body = result["uploadBody"] as? [String: Any] {
                body["parts"] = parts.map { part -> [String: Any] in
                    var value: [String: Any] = [
                        "id": part.id.uuidString, "name": part.name, "kind": part.kind.rawValue,
                    ]
                    if let text = part.text { value["text"] = text }
                    if let index = part.fileIndex { value["fileIndex"] = index }
                    return value
                }
                result["uploadBody"] = body
            }
        }
        return result
    }

    private static func header(
        _ field: HTTPField,
        source: HTTPHeaderSource? = nil,
        isSensitive: Bool = false,
        isSecret: Bool = false
    ) -> [String: Any] {
        var value: [String: Any] = ["name": field.name, "value": field.value]
        if let source { value["source"] = source.rawValue }
        if isSensitive { value["sensitive"] = true }
        if isSecret { value["secret"] = true }
        return value
    }

    private static func redirect(_ redirect: HTTPRedirect, requestDetailsAvailable: Bool) -> [String: Any] {
        var value: [String: Any] = [
            "id": redirect.id.uuidString,
            "statusCode": redirect.statusCode,
            "method": redirect.method,
            "nextMethod": redirect.nextMethod,
            "requestDetailsAvailable": requestDetailsAvailable,
            "responseHeaders": redirect.responseHeaders.map { header($0) },
        ]

        if requestDetailsAvailable {
            value["url"] = redirect.url.absoluteString
            value["nextURL"] = redirect.nextURL.absoluteString
            value["requestHeaders"] = redirect.requestHeaders.map {
                header(
                    $0,
                    source: redirect.requestHeaderSources[$0.name.lowercased()],
                    isSensitive: redirect.sensitiveRequestHeaderNames.contains($0.name.lowercased()),
                    isSecret: redirect.secretRequestHeaderNames.contains($0.name.lowercased())
                )
            }
        }

        return value
    }

    private static func responseBodyPreview(for response: HTTPResponseRecord) throws -> [String: Any] {
        guard response.bodyByteCount >= 0 else {
            throw SnapshotJSONExportError.invalidBodySize
        }

        let sample: Data
        do {
            let file = try FileHandle(forReadingFrom: response.bodyFileURL)
            defer { try? file.close() }
            sample = try file.read(upToCount: maximumBodyPreviewBytes + 1) ?? Data()
        } catch {
            throw SnapshotJSONExportError.bodyReadFailed
        }

        let expectedPreviewBytes = min(response.bodyByteCount, Int64(maximumBodyPreviewBytes))
        guard Int64(sample.count) >= expectedPreviewBytes,
            response.bodyByteCount > Int64(maximumBodyPreviewBytes) || Int64(sample.count) == response.bodyByteCount
        else {
            throw SnapshotJSONExportError.bodySizeMismatch
        }

        let data = Data(sample.prefix(maximumBodyPreviewBytes))
        let truncated = response.bodyByteCount > Int64(data.count)
        let common: [String: Any] = [
            "byteCount": response.bodyByteCount,
            "previewByteCount": data.count,
            "truncated": truncated,
        ]

        if let text = decodeText(data, isTruncated: truncated), isTextual(text) {
            return common.merging(["encoding": "utf-8", "content": text]) { _, new in new }
        }

        return common.merging(["encoding": "base64", "content": data.base64EncodedString()]) { _, new in new }
    }

    private static func decodeText(_ data: Data, isTruncated: Bool) -> String? {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }

        guard isTruncated else { return nil }
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return "" }

        var continuationCount = 0
        var index = bytes.count - 1
        while index >= 0, bytes[index] & 0xC0 == 0x80, continuationCount < 3 {
            continuationCount += 1
            if index == 0 { break }
            index -= 1
        }

        let leadIndex = index
        let lead = bytes[leadIndex]
        let expectedLength: Int
        switch lead {
        case 0xC2...0xDF: expectedLength = 2
        case 0xE0...0xEF: expectedLength = 3
        case 0xF0...0xF4: expectedLength = 4
        default: expectedLength = 1
        }

        guard expectedLength > bytes.count - leadIndex else { return nil }
        return String(data: Data(bytes.prefix(leadIndex)), encoding: .utf8)
    }

    private static func isTextual(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            let codePoint = scalar.value
            if codePoint == 0x09 || codePoint == 0x0A || codePoint == 0x0C || codePoint == 0x0D {
                return true
            }
            return !CharacterSet.controlCharacters.contains(scalar)
        }
    }
}

private enum SnapshotJSONExportError: LocalizedError {
    case invalidBodySize
    case bodyReadFailed
    case bodySizeMismatch
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidBodySize:
            "The saved response body has an invalid recorded size."
        case .bodyReadFailed:
            "The saved response body could not be read."
        case .bodySizeMismatch:
            "The saved response body does not match its recorded size."
        case .encodingFailed:
            "The snapshot could not be encoded as JSON."
        }
    }
}
