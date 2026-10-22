import Foundation

public enum BodyMediaType {
    public static func contentType(for headers: [HTTPField]) -> String? {
        guard
            let header = headers.first(where: {
                $0.isEnabled
                    && $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        .caseInsensitiveCompare("content-type") == .orderedSame
            })
        else { return nil }
        let value = header.value.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.isEmpty ? nil : value
    }

    public static func syntax(for headers: [HTTPField]) -> BodySyntax {
        guard let type = contentType(for: headers) else { return .none }
        if type == "application/json" || type == "text/json" || type.hasSuffix("+json") { return .json }
        if type == "text/html" { return .html }
        if type == "text/xml" || type == "application/xml" || type.hasSuffix("+xml") { return .xml }
        return .none
    }
}
