import PostieCore
import SwiftUI

enum ReadOnlyHTTPFieldPresentation {
    private static let standardSensitiveHeaderNames: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "cookie2", "set-cookie",
    ]

    static func normalizedNames(_ names: Set<String>) -> Set<String> {
        Set(names.map { $0.lowercased() })
    }

    static func sensitiveNames(_ names: Set<String>, includesStandardHeaderNames: Bool) -> Set<String> {
        let normalized = normalizedNames(names)
        guard includesStandardHeaderNames else { return normalized }
        return normalized.union(standardSensitiveHeaderNames)
    }

    static func hasSensitiveFields(
        _ fields: [HTTPField], sensitiveNames: Set<String>, secretNames: Set<String>, includesStandardHeaderNames: Bool
    ) -> Bool {
        let sensitiveNames = self.sensitiveNames(
            sensitiveNames, includesStandardHeaderNames: includesStandardHeaderNames)
        let secretNames = normalizedNames(secretNames)
        return fields.contains { field in
            let name = field.name.lowercased()
            return sensitiveNames.contains(name) || secretNames.contains(name)
        }
    }

    static func bulkText(
        _ fields: [HTTPField],
        sensitiveNames: Set<String> = [],
        secretNames: Set<String> = [],
        includesStandardHeaderNames: Bool = false,
        hidesSecretFieldNames: Bool = false,
        revealingSensitive: Bool = false
    ) -> String {
        let safeFields = maskedFields(
            fields,
            sensitiveNames: sensitiveNames,
            secretNames: secretNames,
            includesStandardHeaderNames: includesStandardHeaderNames,
            hidesSecretFieldNames: hidesSecretFieldNames,
            revealingSensitive: revealingSensitive
        )
        return HTTPFieldBulkText.encode(safeFields)
    }

    static func isRevealed(
        revealedKey: ReadOnlyHTTPFieldRevealKey?, currentKey: ReadOnlyHTTPFieldRevealKey
    ) -> Bool {
        revealedKey == currentKey
    }

    private static func maskedFields(
        _ fields: [HTTPField],
        sensitiveNames: Set<String>,
        secretNames: Set<String>,
        includesStandardHeaderNames: Bool,
        hidesSecretFieldNames: Bool,
        revealingSensitive: Bool
    ) -> [HTTPField] {
        let sensitiveNames = self.sensitiveNames(
            sensitiveNames, includesStandardHeaderNames: includesStandardHeaderNames)
        let secretNames = normalizedNames(secretNames)

        return fields.map { field in
            let name = field.name.lowercased()
            let nameIsSecret = secretNames.contains(name)
            let valueIsSensitive = sensitiveNames.contains(name) || nameIsSecret
            let safeName = hidesSecretFieldNames && nameIsSecret && !revealingSensitive ? "Secret header" : field.name
            let safeValue = valueIsSensitive && !revealingSensitive ? "••••••••" : field.value

            return HTTPField(
                id: field.id,
                name: safeName,
                value: safeValue,
                isEnabled: field.isEnabled,
                queryEncoding: field.queryEncoding
            )
        }
    }
}

struct ReadOnlyHTTPFieldRevealKey: Equatable {
    let fields: [HTTPField]
    let sensitiveNames: Set<String>
    let secretNames: Set<String>
    let sources: [String: HTTPHeaderSource]
    let masksStandardHeaderNames: Bool
    let hidesSecretFieldNames: Bool
    let isBulkMode: Bool
}

struct ReadOnlyHTTPFieldsView<TableContent: View>: View {
    let fields: [HTTPField]
    @Binding var mode: HTTPFieldDisplayMode
    let sensitiveNames: Set<String>
    let secretNames: Set<String>
    let sources: [String: HTTPHeaderSource]
    let masksStandardHeaderNames: Bool
    let hidesSecretFieldNames: Bool
    let sensitiveItemTitle: String

    private let tableContent: (Set<String>, Set<String>) -> TableContent
    @State private var revealedKey: ReadOnlyHTTPFieldRevealKey?

    init(
        fields: [HTTPField],
        mode: Binding<HTTPFieldDisplayMode>,
        sensitiveNames: Set<String> = [],
        secretNames: Set<String> = [],
        sources: [String: HTTPHeaderSource] = [:],
        masksStandardHeaderNames: Bool = false,
        hidesSecretFieldNames: Bool = false,
        sensitiveItemTitle: String = "fields",
        @ViewBuilder tableContent: @escaping (Set<String>, Set<String>) -> TableContent
    ) {
        self.fields = fields
        self._mode = mode
        self.sensitiveNames = sensitiveNames
        self.secretNames = secretNames
        self.sources = sources
        self.masksStandardHeaderNames = masksStandardHeaderNames
        self.hidesSecretFieldNames = hidesSecretFieldNames
        self.sensitiveItemTitle = sensitiveItemTitle
        self.tableContent = tableContent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !fields.isEmpty && mode == .bulk && hasSensitiveFields {
                HStack(spacing: 8) {
                    Button(
                        isRevealed
                            ? "Hide sensitive \(sensitiveItemTitle)" : "Reveal sensitive \(sensitiveItemTitle)"
                    ) {
                        revealedKey = isRevealed ? nil : revealKey
                    }
                    .buttonStyle(.borderless)

                    Spacer(minLength: 0)
                }
            }

            if fields.isEmpty || mode == .table {
                tableContent(effectiveSensitiveNames, normalizedSecretNames)
            } else {
                Text(
                    ReadOnlyHTTPFieldPresentation.bulkText(
                        fields,
                        sensitiveNames: sensitiveNames,
                        secretNames: secretNames,
                        includesStandardHeaderNames: masksStandardHeaderNames,
                        hidesSecretFieldNames: hidesSecretFieldNames,
                        revealingSensitive: isRevealed
                    )
                )
                .font(.system(.callout, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: revealKey) { _, _ in revealedKey = nil }
        .onChange(of: mode) { _, _ in revealedKey = nil }
        .onDisappear { revealedKey = nil }
    }

    private var effectiveSensitiveNames: Set<String> {
        ReadOnlyHTTPFieldPresentation.sensitiveNames(
            sensitiveNames, includesStandardHeaderNames: masksStandardHeaderNames)
    }

    private var normalizedSecretNames: Set<String> {
        ReadOnlyHTTPFieldPresentation.normalizedNames(secretNames)
    }

    private var hasSensitiveFields: Bool {
        ReadOnlyHTTPFieldPresentation.hasSensitiveFields(
            fields,
            sensitiveNames: sensitiveNames,
            secretNames: secretNames,
            includesStandardHeaderNames: masksStandardHeaderNames
        )
    }

    private var revealKey: ReadOnlyHTTPFieldRevealKey {
        ReadOnlyHTTPFieldRevealKey(
            fields: fields,
            sensitiveNames: sensitiveNames,
            secretNames: secretNames,
            sources: sources,
            masksStandardHeaderNames: masksStandardHeaderNames,
            hidesSecretFieldNames: hidesSecretFieldNames,
            isBulkMode: mode == .bulk
        )
    }

    private var isRevealed: Bool {
        ReadOnlyHTTPFieldPresentation.isRevealed(revealedKey: revealedKey, currentKey: revealKey)
    }
}
