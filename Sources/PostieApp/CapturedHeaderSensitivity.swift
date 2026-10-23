import PostieCore

struct CapturedHeaderSensitivity {
    let sensitiveNames: Set<String>
    let secretNames: Set<String>

    static func resolve(
        fields: [HTTPField],
        inputs: [String: SnapshotInput]?,
        sensitiveNames: Set<String>,
        secretNames: Set<String>
    ) -> CapturedHeaderSensitivity {
        var sensitive = ReadOnlyHTTPFieldPresentation.sensitiveNames(
            sensitiveNames, includesStandardHeaderNames: true)
        var secret = ReadOnlyHTTPFieldPresentation.normalizedNames(secretNames)
        let values = inputs?.mapValues(\.value)
        for field in fields {
            let templateName = field.name.lowercased()
            guard let values else {
                sensitive.insert(templateName)
                continue
            }
            let references = TemplateEngine.scan(field.name).references
            if references.contains(where: { inputs?[$0.name]?.isSecret == true }) {
                secret.insert(templateName)
            }
            guard let resolved = try? TemplateEngine.substitute(field.name, values: values) else {
                sensitive.insert(templateName)
                continue
            }
            let resolvedName = resolved.lowercased()
            if sensitive.contains(resolvedName) || secret.contains(resolvedName) {
                sensitive.insert(templateName)
            }
            if secret.contains(resolvedName) { secret.insert(templateName) }
        }
        return CapturedHeaderSensitivity(sensitiveNames: sensitive, secretNames: secret)
    }
}
