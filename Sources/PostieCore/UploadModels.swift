import Foundation

public enum RequestBodyKind: String, Codable, CaseIterable, Sendable {
    case text
    case rawFile
    case multipart
}

public struct HTTPFileReference: Codable, Equatable, Sendable {
    public var path: String
    public var filename: String?
    public var contentType: String?

    public init(path: String, filename: String? = nil, contentType: String? = nil) {
        self.path = path
        self.filename = filename
        self.contentType = contentType
    }
}

public enum MultipartPartKind: String, Codable, CaseIterable, Sendable {
    case text
    case file
}

public struct HTTPMultipartPart: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: MultipartPartKind
    public var text: String
    public var file: HTTPFileReference?
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(), name: String = "", kind: MultipartPartKind = .text,
        text: String = "", file: HTTPFileReference? = nil, isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.text = text
        self.file = file
        self.isEnabled = isEnabled
    }
}

public struct SnapshotUploadFile: Codable, Equatable, Sendable {
    public let partName: String?
    public let filename: String
    public let contentType: String
    public let byteCount: Int64
    public let sha256: String?

    public init(partName: String? = nil, filename: String, contentType: String, byteCount: Int64, sha256: String? = nil)
    {
        self.partName = partName
        self.filename = filename
        self.contentType = contentType
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct SnapshotUploadPart: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let kind: MultipartPartKind
    public let text: String?
    public let fileIndex: Int?

    public init(id: UUID, name: String, kind: MultipartPartKind, text: String? = nil, fileIndex: Int? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.text = text
        self.fileIndex = fileIndex
    }
}

public struct SnapshotUploadBody: Codable, Equatable, Sendable {
    public let kind: RequestBodyKind
    public let contentType: String
    public let byteCount: Int64
    public let files: [SnapshotUploadFile]
    public let binaryOmitted: Bool
    public let parts: [SnapshotUploadPart]?

    public init(
        kind: RequestBodyKind, contentType: String, byteCount: Int64, files: [SnapshotUploadFile],
        parts: [SnapshotUploadPart] = []
    ) {
        self.kind = kind
        self.contentType = contentType
        self.byteCount = byteCount
        self.files = files
        self.binaryOmitted = true
        self.parts = parts.isEmpty ? nil : parts
    }

    var omittingPartValues: SnapshotUploadBody {
        SnapshotUploadBody(kind: kind, contentType: contentType, byteCount: byteCount, files: files)
    }
}
