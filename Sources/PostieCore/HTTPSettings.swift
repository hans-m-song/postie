import Foundation

public struct HTTPOptionsOverrides: Codable, Equatable, Sendable {
    public var followRedirects: Bool?
    public var inactivityTimeout: Double?
    public var overallTimeout: Double?
    public var maximumResponseBytes: Int64?
    public var overallTimeoutIsUnlimited: Bool
    public var responseSizeIsUnlimited: Bool

    public init(
        followRedirects: Bool? = nil,
        inactivityTimeout: Double? = nil,
        overallTimeout: Double? = nil,
        maximumResponseBytes: Int64? = nil,
        overallTimeoutIsUnlimited: Bool = false,
        responseSizeIsUnlimited: Bool = false
    ) {
        self.followRedirects = followRedirects
        self.inactivityTimeout = inactivityTimeout
        self.overallTimeout = overallTimeout
        self.maximumResponseBytes = maximumResponseBytes
        self.overallTimeoutIsUnlimited = overallTimeoutIsUnlimited
        self.responseSizeIsUnlimited = responseSizeIsUnlimited
    }

    public func resolve(against defaults: HTTPOptions) -> HTTPOptions {
        HTTPOptions(
            followRedirects: followRedirects ?? defaults.followRedirects,
            inactivityTimeout: inactivityTimeout ?? defaults.inactivityTimeout,
            overallTimeout: overallTimeoutIsUnlimited ? nil : (overallTimeout ?? defaults.overallTimeout),
            maximumResponseBytes: responseSizeIsUnlimited ? nil : (maximumResponseBytes ?? defaults.maximumResponseBytes)
        )
    }

    public static func explicit(_ options: HTTPOptions) -> HTTPOptionsOverrides {
        HTTPOptionsOverrides(
            followRedirects: options.followRedirects,
            inactivityTimeout: options.inactivityTimeout,
            overallTimeout: options.overallTimeout,
            maximumResponseBytes: options.maximumResponseBytes,
            overallTimeoutIsUnlimited: options.overallTimeout == nil,
            responseSizeIsUnlimited: options.maximumResponseBytes == nil
        )
    }

    private enum CodingKeys: String, CodingKey {
        case followRedirects
        case inactivityTimeout
        case overallTimeout
        case maximumResponseBytes
        case overallTimeoutIsUnlimited
        case responseSizeIsUnlimited
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        followRedirects = try container.decodeIfPresent(Bool.self, forKey: .followRedirects)
        inactivityTimeout = try container.decodeIfPresent(Double.self, forKey: .inactivityTimeout)
        overallTimeout = try container.decodeIfPresent(Double.self, forKey: .overallTimeout)
        maximumResponseBytes = try container.decodeIfPresent(Int64.self, forKey: .maximumResponseBytes)
        overallTimeoutIsUnlimited = try container.decodeIfPresent(Bool.self, forKey: .overallTimeoutIsUnlimited) ?? false
        responseSizeIsUnlimited = try container.decodeIfPresent(Bool.self, forKey: .responseSizeIsUnlimited) ?? false
    }
}
