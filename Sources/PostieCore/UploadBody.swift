import CryptoKit
import CoreFoundation
import Darwin
import Foundation

enum UploadError: LocalizedError {
    case invalidFile
    case sourceChanged
    case invalidPart
    case invalidContentType
    case invalidLength
    case readFailed

    var errorDescription: String? {
        switch self {
        case .invalidFile: "The upload source must be an available, readable regular file at an absolute path."
        case .sourceChanged: "An upload source changed after preparation. Prepare the request again before sending."
        case .invalidPart: "Multipart names and filenames must be non-empty and contain no control characters."
        case .invalidContentType: "The upload Content-Type is invalid or contradicts the multipart boundary."
        case .invalidLength: "The upload Content-Length contradicts the prepared payload size."
        case .readFailed: "The upload source could not be read completely."
        }
    }
}

private struct UploadFileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ value: stat) {
        device = value.st_dev
        inode = value.st_ino
        size = value.st_size
        modifiedSeconds = value.st_mtimespec.tv_sec
        modifiedNanoseconds = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec
        changedNanoseconds = value.st_ctimespec.tv_nsec
    }
}

private struct UploadFile: Sendable {
    let path: String
    let identity: UploadFileIdentity
    let metadata: SnapshotUploadFile

    init(reference: HTTPFileReference, partName: String?) throws {
        guard (reference.path as NSString).isAbsolutePath, !reference.path.utf8.contains(0) else {
            throw UploadError.invalidFile
        }
        path = reference.path
        let filename = reference.filename ?? URL(fileURLWithPath: path).lastPathComponent
        try Self.validateDisposition(filename)
        let contentType = reference.contentType ?? "application/octet-stream"
        try Self.validateContentType(contentType)
        let descriptor = try Self.openFile(path)
        defer { Darwin.close(descriptor) }
        identity = try Self.identity(of: descriptor)
        metadata = SnapshotUploadFile(
            partName: partName, filename: filename, contentType: contentType, byteCount: identity.size)
    }

    func openValidated() throws -> Int32 {
        let descriptor = try Self.openFile(path)
        do {
            guard try Self.identity(of: descriptor) == identity else { throw UploadError.sourceChanged }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    func validate(descriptor: Int32) throws {
        guard try Self.identity(of: descriptor) == identity else { throw UploadError.sourceChanged }
        let current = try openValidated()
        Darwin.close(current)
    }

    private static func openFile(_ path: String) throws -> Int32 {
        let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else { throw UploadError.invalidFile }
        do {
            _ = try identity(of: descriptor)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func identity(of descriptor: Int32) throws -> UploadFileIdentity {
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_size >= 0 else {
            throw UploadError.invalidFile
        }
        return UploadFileIdentity(value)
    }

    static func validateDisposition(_ value: String) throws {
        guard !value.isEmpty, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw UploadError.invalidPart
        }
    }

    static func validateContentType(_ value: String) throws {
        let mime = (value.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            .trimmingCharacters(in: .whitespaces)
        let components = mime.split(separator: "/", omittingEmptySubsequences: false)
        let separators = CharacterSet(charactersIn: "()<>@,;:\\\"/[]?={} \t")
        guard components.count == 2,
            components.allSatisfy({ component in
                !component.isEmpty
                    && component.unicodeScalars.allSatisfy {
                        $0.isASCII && !CharacterSet.controlCharacters.contains($0) && !separators.contains($0)
                    }
            }), !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw UploadError.invalidContentType
        }
    }
}

private enum UploadSegment: Sendable {
    case bytes(Data)
    case file(Int)
}

public final class PreparedUploadBody: @unchecked Sendable {
    public let kind: RequestBodyKind
    public let contentType: String
    public let byteCount: Int64
    private let files: [UploadFile]
    private let segments: [UploadSegment]
    private let parts: [SnapshotUploadPart]
    private let lock = NSLock()
    private var hashes: [Int: String] = [:]

    private init(
        kind: RequestBodyKind, contentType: String, files: [UploadFile], segments: [UploadSegment],
        parts: [SnapshotUploadPart] = []
    ) throws {
        self.kind = kind
        self.contentType = contentType
        self.files = files
        self.segments = segments
        self.parts = parts
        var count: Int64 = 0
        for segment in segments {
            let size: Int64
            switch segment {
            case .bytes(let data): size = Int64(data.count)
            case .file(let index): size = files[index].identity.size
            }
            let addition = count.addingReportingOverflow(size)
            guard !addition.overflow else { throw UploadError.invalidLength }
            count = addition.partialValue
        }
        byteCount = count
    }

    public var snapshotMetadata: SnapshotUploadBody {
        lock.lock()
        defer { lock.unlock() }
        return SnapshotUploadBody(
            kind: kind, contentType: contentType, byteCount: byteCount,
            files: files.enumerated().map { index, file in
                SnapshotUploadFile(
                    partName: file.metadata.partName, filename: file.metadata.filename,
                    contentType: file.metadata.contentType, byteCount: file.metadata.byteCount, sha256: hashes[index])
            }, parts: parts)
    }

    public func makeInputStream() throws -> InputStream {
        for file in files {
            let descriptor = try file.openValidated()
            Darwin.close(descriptor)
        }
        lock.lock()
        hashes.removeAll()
        lock.unlock()
        return UploadInputStream(body: self, files: files, segments: segments)
    }

    fileprivate func recordHash(_ hash: String, index: Int) {
        lock.lock()
        hashes[index] = hash
        lock.unlock()
    }

    static func prepare(
        configuration: HTTPRequestConfiguration, contentType: String?,
        substitute: (String) throws -> String
    ) throws -> PreparedUploadBody? {
        guard configuration.bodyEnabled, configuration.bodyKind != .text else { return nil }
        if configuration.bodyKind == .rawFile {
            guard let reference = configuration.rawFile else { throw UploadError.invalidFile }
            let file = try UploadFile(reference: reference, partName: nil)
            let type = contentType ?? file.metadata.contentType
            try UploadFile.validateContentType(type)
            return try PreparedUploadBody(kind: .rawFile, contentType: type, files: [file], segments: [.file(0)])
        }
        let boundary: String
        if let contentType {
            let components = contentType.split(separator: ";", omittingEmptySubsequences: false)
            guard components.first?.trimmingCharacters(in: .whitespaces).lowercased() == "multipart/form-data",
                components.count == 2
            else { throw UploadError.invalidContentType }
            let parameter = components[1].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parameter.count == 2, parameter[0].trimmingCharacters(in: .whitespaces).lowercased() == "boundary"
            else { throw UploadError.invalidContentType }
            var value = parameter[1].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            let allowed = CharacterSet(
                charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'-_+.()/:=?")
            guard !value.isEmpty, value.utf8.count <= 70,
                value.unicodeScalars.allSatisfy(allowed.contains)
            else { throw UploadError.invalidContentType }
            boundary = value
        } else {
            boundary = "Postie-" + UUID().uuidString
        }
        var files: [UploadFile] = []
        var segments: [UploadSegment] = []
        var parts: [SnapshotUploadPart] = []
        let quote = { (value: String) in
            value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        for part in configuration.multipartParts where part.isEnabled {
            try UploadFile.validateDisposition(part.name)
            var header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(quote(part.name))\""
            if part.kind == .file {
                guard let reference = part.file else { throw UploadError.invalidFile }
                let file = try UploadFile(reference: reference, partName: part.name)
                header +=
                    "; filename=\"\(quote(file.metadata.filename))\"\r\nContent-Type: \(file.metadata.contentType)\r\n\r\n"
                segments.append(.bytes(Data(header.utf8)))
                segments.append(.file(files.count))
                parts.append(SnapshotUploadPart(id: part.id, name: part.name, kind: .file, fileIndex: files.count))
                files.append(file)
            } else {
                let resolvedText = try substitute(part.text)
                header += "\r\n\r\n" + resolvedText
                parts.append(SnapshotUploadPart(id: part.id, name: part.name, kind: .text, text: resolvedText))
                segments.append(.bytes(Data(header.utf8)))
            }
            segments.append(.bytes(Data("\r\n".utf8)))
        }
        segments.append(.bytes(Data("--\(boundary)--\r\n".utf8)))
        return try PreparedUploadBody(
            kind: .multipart, contentType: contentType ?? "multipart/form-data; boundary=\(boundary)",
            files: files, segments: segments, parts: parts)
    }
}

final class UploadInputStream: InputStream, @unchecked Sendable {
    let body: PreparedUploadBody
    private let files: [UploadFile]
    private let segments: [UploadSegment]
    private let lock = NSLock()
    private var status: Stream.Status = .notOpen
    private var error: Error?
    private var segmentIndex = 0
    private var offset: Int64 = 0
    private var descriptor: Int32?
    private var hasher = SHA256()
    private weak var streamDelegate: (any StreamDelegate)?
    private var properties: [Stream.PropertyKey: Any] = [:]
    private var scheduledRunLoops: [(RunLoop, RunLoop.Mode)] = []

    fileprivate init(body: PreparedUploadBody, files: [UploadFile], segments: [UploadSegment]) {
        self.body = body
        self.files = files
        self.segments = segments
        super.init(data: Data())
    }

    override var streamStatus: Stream.Status { lock.withLock { status } }
    override var streamError: Error? { lock.withLock { error } }
    override var hasBytesAvailable: Bool {
        lock.withLock { status != .closed && status != .error && segmentIndex < segments.count }
    }
    override var delegate: (any StreamDelegate)? {
        get { lock.withLock { streamDelegate } }
        set { lock.withLock { streamDelegate = newValue } }
    }
    override func property(forKey key: Stream.PropertyKey) -> Any? { lock.withLock { properties[key] } }
    override func setProperty(_ property: Any?, forKey key: Stream.PropertyKey) -> Bool {
        lock.withLock { properties[key] = property }
        return true
    }
    override func open() {
        let opened = lock.withLock {
            guard status == .notOpen else { return false }
            status = .open
            return true
        }
        if opened {
            emit(.openCompleted)
            emit(.hasBytesAvailable)
        }
    }
    override func close() {
        lock.withLock {
            closeFile()
            status = .closed
            scheduledRunLoops.removeAll()
            properties.removeAll()
        }
    }

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        lock.lock()
        defer {
            let nextEvent: Stream.Event =
                status == .error ? .errorOccurred : status == .atEnd ? .endEncountered : .hasBytesAvailable
            lock.unlock()
            emit(nextEvent)
        }
        guard status != .closed, status != .error else { return -1 }
        guard len > 0 else { return 0 }
        status = .reading
        do {
            while segmentIndex < segments.count {
                switch segments[segmentIndex] {
                case .bytes(let data):
                    let count = min(len, data.count - Int(offset))
                    if count > 0 {
                        data.copyBytes(to: buffer, from: Int(offset)..<(Int(offset) + count))
                        offset += Int64(count)
                        status = .open
                        return count
                    }
                case .file(let index):
                    let file = files[index]
                    if descriptor == nil { descriptor = try file.openValidated() }
                    let remaining = file.identity.size - offset
                    if remaining > 0 {
                        let count = Darwin.read(descriptor!, buffer, min(len, Int(min(remaining, 65_536))))
                        if count < 0, errno == EINTR { continue }
                        guard count > 0 else { throw UploadError.readFailed }
                        hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
                        offset += Int64(count)
                        if offset == file.identity.size {
                            try file.validate(descriptor: descriptor!)
                            body.recordHash(hasher.finalize().map { String(format: "%02x", $0) }.joined(), index: index)
                        }
                        status = .open
                        return count
                    }
                    try file.validate(descriptor: descriptor!)
                    if file.identity.size == 0 {
                        body.recordHash(hasher.finalize().map { String(format: "%02x", $0) }.joined(), index: index)
                    }
                    closeFile()
                }
                segmentIndex += 1
                offset = 0
                hasher = SHA256()
            }
            status = .atEnd
            return 0
        } catch {
            self.error = error
            closeFile()
            status = .error
            return -1
        }
    }

    override func getBuffer(
        _ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, length len: UnsafeMutablePointer<Int>
    ) -> Bool { false }
    override func schedule(in aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {
        let isOpen = lock.withLock {
            if !scheduledRunLoops.contains(where: { $0.0 === aRunLoop && $0.1 == mode }) {
                scheduledRunLoops.append((aRunLoop, mode))
            }
            return status == .open
        }
        if isOpen { emit(.hasBytesAvailable) }
    }
    override func remove(from aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {
        lock.withLock { scheduledRunLoops.removeAll { $0.0 === aRunLoop && $0.1 == mode } }
    }

    private func emit(_ event: Stream.Event) {
        let runLoops = lock.withLock { scheduledRunLoops }
        for (runLoop, mode) in runLoops {
            runLoop.perform(inModes: [mode]) { [weak self] in
                guard let self, self.streamStatus != .closed else { return }
                self.delegate?.stream?(self, handle: event)
            }
            CFRunLoopWakeUp(runLoop.getCFRunLoop())
        }
    }

    private func closeFile() {
        if let descriptor { Darwin.close(descriptor) }
        descriptor = nil
    }

    deinit { closeFile() }
}
