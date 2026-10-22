import Foundation
import PostieCore

public enum RequestDiscovery {
    public static func matches(_ request: HTTPRequestConfiguration, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return request.name.range(of: query, options: .caseInsensitive) != nil
            || savedPath(request.url).range(of: query, options: .caseInsensitive) != nil
    }

    private static func savedPath(_ template: String) -> String {
        let base = template.prefix { $0 != "?" && $0 != "#" }
        let authorityStart: String.Index
        if let scheme = base.range(of: "://"), !base[..<scheme.lowerBound].contains("/") {
            authorityStart = scheme.upperBound
        } else if base.hasPrefix("//") {
            authorityStart = base.index(base.startIndex, offsetBy: 2)
        } else if base.hasPrefix("{{"), let variableEnd = base.range(of: "}}") {
            authorityStart = variableEnd.upperBound
        } else {
            return String(base)
        }
        guard let pathStart = base[authorityStart...].firstIndex(of: "/") else { return "" }
        return String(base[pathStart...])
    }
}
