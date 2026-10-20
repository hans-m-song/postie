import Foundation
import SwiftUI
import PostieCore

struct GlobalSettingsPage: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(AppTheme.preferenceKey) private var theme = AppTheme.system

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.title3.weight(.semibold))
                .padding(18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Appearance")
                            .font(.headline)
                        Picker("Theme", selection: $theme) {
                            ForEach(AppTheme.allCases, id: \.self) { theme in
                                Text(theme.title).tag(theme)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    Divider()

                    EncryptionSettingsView()

                    Divider()

                    if let error = model.variableSaveErrors[.global] {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Settings were not saved")
                                .font(.callout.weight(.semibold))
                            Text(error)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(.red)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }

                    HTTPSettingsEditor(
                        globalOptions: model.globalOptions,
                        isReadOnly: model.globalOptionsAreReadOnly
                    ) { options in
                        model.updateGlobalOptions(options)
                    }
                }
                .padding(18)
                .frame(maxWidth: 700, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct HTTPSettingsEditor: View {
    private enum Scope {
        case global(HTTPOptions, (HTTPOptions) -> Void)
        case request(HTTPOptionsOverrides, HTTPOptions, (HTTPOptionsOverrides) -> Void)
    }

    private let scope: Scope
    private let isReadOnly: Bool
    @State private var responseSizeUnit = ResponseSizeUnit.megabytes
    @State private var resetRevision = 0

    init(
        globalOptions: HTTPOptions,
        isReadOnly: Bool,
        onChange: @escaping (HTTPOptions) -> Void
    ) {
        scope = .global(globalOptions, onChange)
        self.isReadOnly = isReadOnly
    }

    init(
        overrides: HTTPOptionsOverrides,
        globalOptions: HTTPOptions,
        isReadOnly: Bool,
        onChange: @escaping (HTTPOptionsOverrides) -> Void
    ) {
        scope = .request(overrides, globalOptions, onChange)
        self.isReadOnly = isReadOnly
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            editorHeading

            VStack(alignment: .leading, spacing: 12) {
                Text("Request behavior")
                    .font(.headline)
                followRedirectsRow
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("Timeouts")
                    .font(.headline)
                inactivityTimeoutRow
                overallTimeoutRow
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("Response size")
                    .font(.headline)
                responseSizeRow
            }
        }
        .id(resetRevision)
        .disabled(isReadOnly)
    }

    @ViewBuilder
    private var editorHeading: some View {
        switch scope {
        case let .global(_, update):
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Global HTTP defaults")
                        .font(.title3.weight(.semibold))
                    Text("Requests inherit these values unless they override them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset to Defaults") {
                    update(HTTPOptions())
                    resetRevision &+= 1
                }
                .disabled(isReadOnly)
            }
        case let .request(_, _, update):
            VStack(alignment: .leading, spacing: 4) {
                Text("Request overrides")
                    .font(.title3.weight(.semibold))
                Text("Leave a value empty to use the global setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reset to Global Defaults") {
                    update(HTTPOptionsOverrides())
                    resetRevision &+= 1
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private var followRedirectsRow: some View {
        switch scope {
        case let .global(options, update):
            settingRow("Follow redirects") {
                Picker("Follow redirects", selection: Binding(
                    get: { options.followRedirects },
                    set: { value in
                        var next = options
                        next.followRedirects = value
                        update(next)
                    }
                )) {
                    Text("Yes").tag(true)
                    Text("No").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
            }
        case let .request(overrides, global, update):
            settingRow("Follow redirects") {
                Picker("Follow redirects", selection: Binding<Bool?>(
                    get: { overrides.followRedirects },
                    set: { value in
                        var next = overrides
                        next.followRedirects = value
                        update(next)
                    }
                )) {
                    Text("Use global (\(global.followRedirects ? "Yes" : "No"))")
                        .tag(Optional<Bool>.none)
                    Text("Yes").tag(Optional(true))
                    Text("No").tag(Optional(false))
                }
                .labelsHidden()
                .frame(width: 230)
            }
        }
    }

    @ViewBuilder
    private var inactivityTimeoutRow: some View {
        switch scope {
        case let .global(options, update):
            settingRow("Inactivity timeout") {
                DecimalNumberField(
                    value: options.inactivityTimeout,
                    placeholder: "Seconds",
                    allowsClearing: false,
                    accessibilityLabel: "Inactivity timeout in seconds"
                ) { value in
                    guard let value else { return }
                    var next = options
                    next.inactivityTimeout = value
                    update(next)
                }
                .frame(width: 126)
                Text("seconds")
                    .foregroundStyle(.secondary)
            }
        case let .request(overrides, global, update):
            settingRow("Inactivity timeout") {
                DecimalNumberField(
                    value: overrides.inactivityTimeout,
                    placeholder: Self.format(global.inactivityTimeout),
                    allowsClearing: true,
                    accessibilityLabel: "Inactivity timeout in seconds"
                ) { value in
                    var next = overrides
                    next.inactivityTimeout = value
                    update(next)
                }
                .frame(width: 126)
                Text("seconds")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var overallTimeoutRow: some View {
        switch scope {
        case let .global(options, update):
            settingRow("Overall timeout") {
                if let value = options.overallTimeout {
                    DecimalNumberField(
                        value: value,
                        placeholder: "Seconds",
                        allowsClearing: false,
                        accessibilityLabel: "Overall timeout in seconds"
                    ) { value in
                        guard let value else { return }
                        var next = options
                        next.overallTimeout = value
                        update(next)
                    }
                    .frame(width: 126)
                    Text("seconds")
                        .foregroundStyle(.secondary)
                }
                Toggle("Unlimited", isOn: Binding(
                    get: { options.overallTimeout == nil },
                    set: { isUnlimited in
                        var next = options
                        next.overallTimeout = isUnlimited ? nil : HTTPOptions().overallTimeout
                        update(next)
                    }
                ))
                .toggleStyle(.checkbox)
            }
        case let .request(overrides, global, update):
            settingRow("Overall timeout") {
                if !overrides.overallTimeoutIsUnlimited {
                    DecimalNumberField(
                        value: overrides.overallTimeout,
                        placeholder: global.overallTimeout.map(Self.format) ?? "Unlimited",
                        allowsClearing: true,
                        accessibilityLabel: "Overall timeout in seconds"
                    ) { value in
                        var next = overrides
                        next.overallTimeout = value
                        next.overallTimeoutIsUnlimited = false
                        update(next)
                    }
                    .frame(width: 126)
                    Text("seconds")
                        .foregroundStyle(.secondary)
                }
                Toggle("Unlimited", isOn: Binding(
                    get: { overrides.overallTimeoutIsUnlimited },
                    set: { isUnlimited in
                        var next = overrides
                        next.overallTimeoutIsUnlimited = isUnlimited
                        if isUnlimited { next.overallTimeout = nil }
                        update(next)
                    }
                ))
                .toggleStyle(.checkbox)
            }
        }
    }

    @ViewBuilder
    private var responseSizeRow: some View {
        switch scope {
        case let .global(options, update):
            settingRow("Maximum response size") {
                if let bytes = options.maximumResponseBytes {
                    ResponseSizeField(
                        bytes: bytes,
                        unit: responseSizeUnit,
                        placeholder: "Size",
                        allowsClearing: false,
                        accessibilityLabel: "Maximum response size"
                    ) { value in
                        guard let value else { return }
                        var next = options
                        next.maximumResponseBytes = value
                        update(next)
                    }
                    .frame(minWidth: 70, idealWidth: 120, maxWidth: 150)
                }
                Picker("Response size unit", selection: $responseSizeUnit) {
                    ForEach(ResponseSizeUnit.allCases) { unit in
                        Text(unit.label).tag(unit)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 80)
                Toggle("Unlimited", isOn: Binding(
                    get: { options.maximumResponseBytes == nil },
                    set: { isUnlimited in
                        var next = options
                        next.maximumResponseBytes = isUnlimited ? nil : HTTPOptions().maximumResponseBytes
                        update(next)
                    }
                ))
                .toggleStyle(.checkbox)
            }
        case let .request(overrides, global, update):
            settingRow("Maximum response size") {
                if !overrides.responseSizeIsUnlimited {
                    ResponseSizeField(
                        bytes: overrides.maximumResponseBytes,
                        unit: responseSizeUnit,
                        placeholder: Self.formatSize(global.maximumResponseBytes, unit: responseSizeUnit),
                        allowsClearing: true,
                        accessibilityLabel: "Maximum response size"
                    ) { value in
                        var next = overrides
                        next.maximumResponseBytes = value
                        next.responseSizeIsUnlimited = false
                        update(next)
                    }
                    .frame(minWidth: 70, idealWidth: 120, maxWidth: 150)
                }
                Picker("Response size unit", selection: $responseSizeUnit) {
                    ForEach(ResponseSizeUnit.allCases) { unit in
                        Text(unit.label).tag(unit)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 80)
                Toggle("Unlimited", isOn: Binding(
                    get: { overrides.responseSizeIsUnlimited },
                    set: { isUnlimited in
                        var next = overrides
                        next.responseSizeIsUnlimited = isUnlimited
                        if isUnlimited { next.maximumResponseBytes = nil }
                        update(next)
                    }
                ))
                .toggleStyle(.checkbox)
            }
        }
    }

    private func settingRow<Control: View>(
        _ title: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Text(title).fixedSize()
                Spacer(minLength: 12)
                HStack(spacing: 8) { control() }
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                HStack(spacing: 8) { control() }
            }
        }
    }

    private static func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 6
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func formatSize(_ bytes: Int64?, unit: ResponseSizeUnit) -> String {
        guard let bytes else { return "Unlimited" }
        let value = Decimal(bytes) / Decimal(unit.multiplier)
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = unit.maximumFractionDigits
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? value.description
    }
}

private struct DecimalNumberField: View {
    let value: Double?
    let placeholder: String
    let allowsClearing: Bool
    let accessibilityLabel: String
    let onChange: (Double?) -> Void
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: Binding(
            get: { text },
            set: { newValue in
                text = newValue
                guard let onChangeValue = Self.parse(newValue) else {
                    if newValue.isEmpty && allowsClearing { onChange(nil) }
                    return
                }
                onChange(onChangeValue)
            }
        ))
        .textFieldStyle(.roundedBorder)
        .font(.system(.body, design: .monospaced))
        .multilineTextAlignment(.trailing)
        .accessibilityLabel(accessibilityLabel)
        .focused($isFocused)
        .onAppear { synchronize(from: value) }
        .onChange(of: value) { _, newValue in
            guard !isFocused else { return }
            synchronize(from: newValue)
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { synchronize(from: value) }
        }
        .onSubmit {
            if text.isEmpty || Self.parse(text) == nil {
                synchronize(from: value)
            }
        }
    }

    private func synchronize(from value: Double?) {
        guard let value else {
            text = ""
            return
        }
        text = Self.format(value)
    }

    private static func parse(_ text: String) -> Double? {
        HTTPSettingsInput.timeout(from: text, decimalSeparator: Locale.current.decimalSeparator ?? ".")
    }

    private static func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 6
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

private enum ResponseSizeUnit: String, CaseIterable, Identifiable {
    case kilobytes
    case megabytes

    var id: String { rawValue }
    var label: String { self == .kilobytes ? "KB" : "MB" }
    var multiplier: Int64 { self == .kilobytes ? 1_000 : 1_000_000 }
    var maximumFractionDigits: Int { self == .kilobytes ? 3 : 6 }
}

private struct ResponseSizeField: View {
    let bytes: Int64?
    let unit: ResponseSizeUnit
    let placeholder: String
    let allowsClearing: Bool
    let accessibilityLabel: String
    let onChange: (Int64?) -> Void
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: Binding(
            get: { text },
            set: { newValue in
                text = newValue
                guard let newBytes = Self.parse(newValue, unit: unit) else {
                    if newValue.isEmpty && allowsClearing { onChange(nil) }
                    return
                }
                onChange(newBytes)
            }
        ))
        .textFieldStyle(.roundedBorder)
        .font(.system(.body, design: .monospaced))
        .multilineTextAlignment(.trailing)
        .accessibilityLabel(accessibilityLabel)
        .focused($isFocused)
        .onAppear { synchronize() }
        .onChange(of: bytes) { _, _ in
            guard !isFocused else { return }
            synchronize()
        }
        .onChange(of: unit) { _, _ in synchronize() }
        .onChange(of: isFocused) { _, focused in
            if !focused { synchronize() }
        }
        .onSubmit {
            if text.isEmpty || Self.parse(text, unit: unit) == nil {
                synchronize()
            }
        }
    }

    private func synchronize() {
        guard let bytes else {
            text = ""
            return
        }
        let value = Decimal(bytes) / Decimal(unit.multiplier)
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = unit.maximumFractionDigits
        text = formatter.string(from: NSDecimalNumber(decimal: value)) ?? value.description
    }

    private static func parse(_ text: String, unit: ResponseSizeUnit) -> Int64? {
        HTTPSettingsInput.responseBytes(
            from: text,
            multiplier: unit.multiplier,
            decimalSeparator: Locale.current.decimalSeparator ?? "."
        )
    }
}

enum HTTPSettingsInput {
    static func timeout(from input: String, decimalSeparator: String) -> Double? {
        guard let value = decimal(from: input, decimalSeparator: decimalSeparator), value > .zero else { return nil }
        let seconds = NSDecimalNumber(decimal: value).doubleValue
        guard seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    static func responseBytes(
        from input: String,
        multiplier: Int64,
        decimalSeparator: String
    ) -> Int64? {
        guard multiplier > 0,
              let parts = decimalParts(from: input, decimalSeparator: decimalSeparator) else { return nil }

        var scale: Int64 = 1
        var fractionalDigits = 0
        while scale < multiplier {
            guard scale <= Int64.max / 10 else { return nil }
            scale *= 10
            fractionalDigits += 1
        }
        guard scale == multiplier, fractionalDigits > 0 else { return nil }

        let maximumWhole = Int64.max / multiplier
        let maximumRemainder = Int64.max % multiplier
        let maximumWholeText = String(maximumWhole)
        let wholeComparison = compareDigits(parts.whole, maximumWholeText)
        guard wholeComparison <= 0 else { return nil }

        let remainderText = String(maximumRemainder)
        let maximumFraction = String(repeating: "0", count: fractionalDigits - remainderText.count) + remainderText
        if wholeComparison == 0,
           compareFractions(parts.fraction, maximumFraction) > 0 { return nil }

        let whole = Int64(parts.whole) ?? 0
        let baseBytes = whole * multiplier
        let preciseFraction = String(parts.fraction.prefix(fractionalDigits))
        let paddedFraction = preciseFraction + String(repeating: "0", count: fractionalDigits - preciseFraction.count)
        let fractionBytes = Int64(paddedFraction) ?? 0
        var bytes = baseBytes + fractionBytes
        if let firstDiscardedDigit = parts.fraction.dropFirst(fractionalDigits).first,
           firstDiscardedDigit >= "5" {
            guard bytes < Int64.max else { return nil }
            bytes += 1
        }
        return bytes
    }

    private static func decimal(from input: String, decimalSeparator: String) -> Decimal? {
        guard let parts = decimalParts(from: input, decimalSeparator: decimalSeparator) else { return nil }
        let normalized = parts.fraction.isEmpty ? parts.whole : parts.whole + "." + parts.fraction
        guard let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")),
              !value.isNaN else { return nil }
        return value
    }

    private static func decimalParts(
        from input: String,
        decimalSeparator: String
    ) -> (whole: String, fraction: String)? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !decimalSeparator.isEmpty else { return nil }

        let components = input.components(separatedBy: decimalSeparator)
        guard components.count <= 2 else { return nil }
        let integer = components[0]
        let fraction = components.count == 2 ? components[1] : ""
        guard integer.isEmpty || isDigits(integer),
              components.count == 1 || isDigits(fraction),
              !integer.isEmpty || components.count == 2 else { return nil }

        return (normalizeDigits(integer.isEmpty ? "0" : integer), fraction)
    }

    private static func compareFractions(_ lhs: String, _ rhs: String) -> Int {
        let length = max(lhs.count, rhs.count)
        let left = lhs + String(repeating: "0", count: length - lhs.count)
        let right = rhs + String(repeating: "0", count: length - rhs.count)
        return compareDigits(left, right)
    }

    private static func compareDigits(_ lhs: String, _ rhs: String) -> Int {
        let left = normalizeDigits(lhs)
        let right = normalizeDigits(rhs)
        if left.count != right.count { return left.count < right.count ? -1 : 1 }
        if left == right { return 0 }
        return left < right ? -1 : 1
    }

    private static func normalizeDigits(_ value: String) -> String {
        let digits = value.drop(while: { $0 == "0" })
        return digits.isEmpty ? "0" : String(digits)
    }

    private static func isDigits(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }
}
