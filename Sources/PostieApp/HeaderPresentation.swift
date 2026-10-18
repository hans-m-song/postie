import Foundation
import PostieCore

enum HeaderPresentation {
    static func sourceLabel(for source: HTTPHeaderSource) -> String {
        switch source {
        case .request: "Request"
        case .collection: "Collection"
        case .requestAuth: "Request auth"
        case .collectionAuth: "Collection auth"
        case .automatic: "Automatic"
        }
    }

    static func sourceStatusLabel(source: String, status: String) -> String {
        switch status {
        case "Effective", "Inherited": source
        default: "\(source) · \(status)"
        }
    }

    static func authenticationHeaderName(for authentication: RequestAuthentication) -> String? {
        switch authentication.kind {
        case .none: nil
        case .basic, .bearer: "Authorization"
        case .apiKey: authentication.apiKeyHeaderName ?? ""
        }
    }

    static func authenticationRow(
        authentication: RequestAuthentication,
        source: HTTPHeaderSource,
        requestHeaders: [HTTPField],
        availableVariables: Set<String>,
        onReveal: @escaping () async throws -> String,
        onOpenSource: @escaping () -> Void
    ) -> DerivedHeaderRowPresentation? {
        guard let maskedValue = maskedAuthenticationValue(for: authentication.kind),
              let headerName = authenticationHeaderName(for: authentication) else { return nil }

        let displayName = headerName.isEmpty ? "API key header" : headerName
        let secretField = authenticationSecretField(for: authentication)
        let hasSecret = secretField.map { hasSavedSecret($0, in: authentication) } ?? false
        let canReveal = hasSecret && isHTTPToken(headerName)

        return DerivedHeaderRowPresentation(
            id: "\(source.rawValue):\(displayName)",
            name: displayName,
            maskedValue: maskedValue,
            source: source,
            status: authenticationStatus(
                headerName: headerName,
                hasSecret: hasSecret,
                requestHeaders: requestHeaders
            ),
            availableVariables: availableVariables,
            onReveal: canReveal ? onReveal : nil,
            onOpenSource: onOpenSource
        )
    }

    static func hasTemplateSyntax(in value: String) -> Bool {
        let scan = TemplateEngine.scan(value)
        return !scan.references.isEmpty || !scan.invalidRanges.isEmpty
    }

    private static func maskedAuthenticationValue(for kind: AuthenticationKind) -> String? {
        switch kind {
        case .none: nil
        case .basic: "Basic ••••••••"
        case .bearer: "Bearer ••••••••"
        case .apiKey: "••••••••"
        }
    }

    private static func authenticationSecretField(for authentication: RequestAuthentication) -> AuthenticationSecretField? {
        switch authentication.kind {
        case .none: nil
        case .basic: .password
        case .bearer: .token
        case .apiKey: .apiKey
        }
    }

    private static func hasSavedSecret(_ field: AuthenticationSecretField, in authentication: RequestAuthentication) -> Bool {
        switch field {
        case .password: authentication.password != nil
        case .token: authentication.token != nil
        case .apiKey: authentication.apiKey != nil
        }
    }

    private static func authenticationStatus(
        headerName: String,
        hasSecret: Bool,
        requestHeaders: [HTTPField]
    ) -> String {
        guard !headerName.isEmpty else { return "Pending" }
        guard isHTTPToken(headerName) else { return "Disabled" }

        let isTemplatedName = hasTemplateSyntax(in: headerName)
        let namedRequestHeaders = requestHeaders.filter {
            $0.isEnabled && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let literalMatches = namedRequestHeaders.filter {
            !isTemplatedName &&
                !hasTemplateSyntax(in: $0.name) &&
                $0.name.caseInsensitiveCompare(headerName) == .orderedSame
        }

        if !literalMatches.isEmpty { return "Overridden" }
        if isTemplatedName || namedRequestHeaders.contains(where: { hasTemplateSyntax(in: $0.name) }) {
            return "Variable dependent"
        }
        guard isHTTPToken(headerName), hasSecret else { return "Disabled" }
        return "Effective"
    }

    private static func isHTTPToken(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }

        return value.utf8.allSatisfy { byte in
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A:
                true
            case 0x21, 0x23...0x27, 0x2A, 0x2B, 0x2D...0x2E, 0x5E...0x60, 0x7C, 0x7E:
                true
            default:
                false
            }
        }
    }
}

struct DerivedHeaderRowPresentation: Identifiable {
    let id: String
    let name: String
    let maskedValue: String
    let source: HTTPHeaderSource
    let status: String
    let availableVariables: Set<String>
    let onReveal: (() async throws -> String)?
    let onOpenSource: (() -> Void)?
}

struct HeaderPreviewResetKey: Equatable {
    let identity: RequestIdentity
    let request: HTTPRequestConfiguration?
    let collectionHeaders: [HTTPField]
    let collectionAuthentication: RequestAuthentication?
    let variableContext: VariableContext
}
