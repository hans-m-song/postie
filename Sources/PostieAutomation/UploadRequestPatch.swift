import Foundation
import PostieCore

enum UploadRequestPatch {
    static func apply(_ fields: [String: AutomationJSON], to request: inout HTTPRequestConfiguration) throws {
        if let value = fields["bodyKind"] {
            guard let name = value.stringValue, let kind = RequestBodyKind(rawValue: name) else { throw invalid() }
            request.bodyKind = kind
        }
        if let value = fields["rawFile"] {
            request.rawFile = try file(value)
        }
        if let value = fields["multipartParts"] {
            guard case .array(let rows) = value, rows.count <= 4096 else { throw invalid() }
            request.multipartParts = try rows.map(part)
        }
    }

    private static func file(_ value: AutomationJSON) throws -> HTTPFileReference? {
        if case .null = value { return nil }
        guard let fields = value.objectValue else { throw invalid() }
        let arguments = try AutomationArguments(fields, allowed: ["path", "filename", "contentType"])
        guard let path = try arguments.string("path"), path.hasPrefix("/"), !path.contains("\0") else {
            throw invalid()
        }
        return HTTPFileReference(
            path: path,
            filename: try arguments.string("filename", required: false),
            contentType: try arguments.string("contentType", required: false)
        )
    }

    private static func part(_ value: AutomationJSON) throws -> HTTPMultipartPart {
        guard let fields = value.objectValue else { throw invalid() }
        let arguments = try AutomationArguments(fields, allowed: ["name", "kind", "text", "file", "isEnabled"])
        guard let name = try arguments.string("name"),
            let kindName = try arguments.string("kind"),
            let kind = MultipartPartKind(rawValue: kindName)
        else { throw invalid() }
        let enabled: Bool
        if let value = fields["isEnabled"] {
            guard let flag = value.boolValue else { throw invalid() }
            enabled = flag
        } else {
            enabled = true
        }
        return HTTPMultipartPart(
            name: name, kind: kind,
            text: try arguments.string("text", required: false) ?? "",
            file: try fields["file"].map(file) ?? nil,
            isEnabled: enabled
        )
    }

    private static func invalid() -> AutomationFailure {
        AutomationFailure(.invalidArguments, "Invalid upload fields; file paths must be absolute local paths.")
    }
}
