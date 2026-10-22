import Foundation

enum HTMLBodyPreviewPolicy {
    static let maximumCapturedHTMLBytes = 5 * 1024 * 1024

    static func acceptsBaseURL(_ url: URL?) -> URL? {
        guard let url,
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host != nil,
            url.user == nil,
            url.password == nil
        else {
            return nil
        }

        return url
    }

    static func contentRuleListJSON(allowsExternalResources: Bool) throws -> String {
        var resourceTypes = ["child-document", "script", "popup", "media", "raw", "svg-document"]
        if !allowsExternalResources {
            resourceTypes.append(contentsOf: ["image", "style-sheet", "font"])
        }

        let rule = ContentRule(
            trigger: Trigger(urlFilter: "^https?://", resourceType: resourceTypes),
            action: Action(type: "block")
        )
        let data = try JSONEncoder().encode([rule])
        return String(decoding: data, as: UTF8.self)
    }

    static func contentSecurityPolicy(allowsExternalResources: Bool) -> String {
        let externalSources = allowsExternalResources ? " http: https:" : ""
        return [
            "default-src 'none'",
            "img-src data:\(externalSources)",
            "style-src 'unsafe-inline'\(externalSources)",
            "font-src data:\(externalSources)",
            "script-src 'none'",
            "frame-src 'none'",
            "child-src 'none'",
            "connect-src 'none'",
            "media-src 'none'",
            "object-src 'none'",
            "form-action 'none'",
            "base-uri 'none'",
            "worker-src 'none'",
            "manifest-src 'none'",
        ].joined(separator: "; ")
    }

    private struct ContentRule: Encodable {
        let trigger: Trigger
        let action: Action
    }

    private struct Trigger: Encodable {
        let urlFilter: String
        let resourceType: [String]

        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case resourceType = "resource-type"
        }
    }

    private struct Action: Encodable {
        let type: String
    }
}
