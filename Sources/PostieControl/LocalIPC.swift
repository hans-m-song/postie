import Darwin
import Foundation
import PostieAutomation

public enum LocalIPCError: Error, LocalizedError, Sendable {
    case unavailable, unsafePath, invalidFrame, timedOut

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Postie is unavailable. Open Postie before using the CLI."
        case .unsafePath: "The local control socket directory is not private or is already in use."
        case .invalidFrame: "The local control message is invalid or too large."
        case .timedOut:
            "The local control connection timed out. The operation may have been accepted; it was not retried."
        }
    }
}

public enum LocalIPC {
    public static var defaultSocketPath: String { "/tmp/postie-\(getuid())/control.sock" }
    static let maximumFrameBytes = 4 * 1024 * 1024

    public static func send(_ command: AutomationCommand, socketPath: String = defaultSocketPath) async throws
        -> AutomationReply
    {
        try await Task.detached {
            let descriptor = try connect(path: socketPath)
            defer { Darwin.close(descriptor) }
            try writeFrame(JSONEncoder().encode(command), descriptor: descriptor)
            let reply = try JSONDecoder().decode(AutomationReply.self, from: readFrame(descriptor: descriptor))
            guard reply.id == command.id else { throw LocalIPCError.invalidFrame }
            return reply
        }.value
    }

    static func address<T>(path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw LocalIPCError.unsafePath }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.copyBytes(from: bytes) }
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func makeSocket() throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw LocalIPCError.unavailable }
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        return descriptor
    }

    static func connect(path: String) throws -> Int32 {
        var metadata = stat()
        let directory = (path as NSString).deletingLastPathComponent
        guard lstat(directory, &metadata) == 0 else {
            if errno == ENOENT { throw LocalIPCError.unavailable }
            throw LocalIPCError.unsafePath
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR,
            metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0
        else { throw LocalIPCError.unsafePath }
        guard lstat(path, &metadata) == 0 else {
            if errno == ENOENT { throw LocalIPCError.unavailable }
            throw LocalIPCError.unsafePath
        }
        guard metadata.st_mode & S_IFMT == S_IFSOCK,
            metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0
        else { throw LocalIPCError.unsafePath }
        let descriptor = try makeSocket()
        do {
            let result = try address(path: path) { Darwin.connect(descriptor, $0, $1) }
            if result != 0 {
                guard errno == EINPROGRESS else { throw LocalIPCError.unavailable }
                try ready(descriptor, events: Int16(POLLOUT), deadline: Date().addingTimeInterval(5))
                var failure: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &size) == 0, failure == 0 else {
                    throw LocalIPCError.unavailable
                }
            }
            var user: uid_t = 0
            var group: gid_t = 0
            guard getpeereid(descriptor, &user, &group) == 0, user == getuid() else { throw LocalIPCError.unsafePath }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func ready(_ descriptor: Int32, events: Int16, deadline: Date) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw LocalIPCError.timedOut }
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&item, 1, Int32(min(remaining * 1000, 30_000)))
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { throw LocalIPCError.timedOut }
            guard item.revents & events != 0 else { throw LocalIPCError.unavailable }
            return
        }
    }

    static func readFrame(descriptor: Int32, maximumBytes: Int = maximumFrameBytes) throws -> Data {
        let deadline = Date().addingTimeInterval(30)
        let prefix = try read(count: 4, descriptor: descriptor, deadline: deadline)
        let count = prefix.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= maximumBytes else { throw LocalIPCError.invalidFrame }
        return try read(count: count, descriptor: descriptor, deadline: deadline)
    }

    private static func read(count: Int, descriptor: Int32, deadline: Date) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            try ready(descriptor, events: Int16(POLLIN), deadline: deadline)
            let received = data.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), count - offset)
            }
            if received < 0, errno == EINTR || errno == EAGAIN { continue }
            guard received > 0 else { throw LocalIPCError.unavailable }
            offset += received
        }
        return data
    }

    static func writeFrame(_ data: Data, descriptor: Int32) throws {
        guard !data.isEmpty, data.count <= maximumFrameBytes else { throw LocalIPCError.invalidFrame }
        let count = UInt32(data.count)
        var frame = Data([
            UInt8((count >> 24) & 255), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255),
        ])
        frame.append(data)
        let deadline = Date().addingTimeInterval(30)
        var offset = 0
        while offset < frame.count {
            try ready(descriptor, events: Int16(POLLOUT), deadline: deadline)
            let sent = frame.withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), frame.count - offset)
            }
            if sent < 0, errno == EINTR || errno == EAGAIN { continue }
            guard sent > 0 else { throw LocalIPCError.unavailable }
            offset += sent
        }
    }
}

public actor LocalIPCServer {
    private let path: String
    private let dispatcher: AutomationDispatcher
    private var listener: Int32?
    private var lockDescriptor: Int32?
    private var socketIdentity: (device: dev_t, inode: ino_t)?
    private var accepting: Task<Void, Never>?
    private var isStopping = false
    private var admitted: [UUID: Task<Void, Never>] = [:]

    public init(socketPath: String = LocalIPC.defaultSocketPath, dispatcher: @escaping AutomationDispatcher) {
        path = socketPath
        self.dispatcher = dispatcher
    }

    public func start() throws {
        guard !isStopping else { throw LocalIPCError.unavailable }
        guard listener == nil else { beginAccepting(); return }
        let directory = (path as NSString).deletingLastPathComponent
        if mkdir(directory, 0o700) != 0, errno != EEXIST { throw LocalIPCError.unsafePath }
        var metadata = stat()
        guard lstat(directory, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
            metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0
        else { throw LocalIPCError.unsafePath }
        let lock = open(directory + "/server.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw LocalIPCError.unsafePath }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(lock); throw LocalIPCError.unsafePath }
        do {
            if lstat(path, &metadata) == 0 {
                guard metadata.st_mode & S_IFMT == S_IFSOCK, metadata.st_uid == getuid() else {
                    throw LocalIPCError.unsafePath
                }
                guard unlink(path) == 0 else { throw LocalIPCError.unsafePath }
            } else if errno != ENOENT {
                throw LocalIPCError.unsafePath
            }
            let descriptor = try LocalIPC.makeSocket()
            do {
                guard try LocalIPC.address(path: path, { bind(descriptor, $0, $1) }) == 0,
                    chmod(path, 0o600) == 0, listen(descriptor, 16) == 0
                else { throw LocalIPCError.unsafePath }
            } catch { Darwin.close(descriptor); throw error }
            listener = descriptor
            guard lstat(path, &metadata) == 0 else {
                Darwin.close(descriptor); listener = nil; throw LocalIPCError.unsafePath
            }
            socketIdentity = (metadata.st_dev, metadata.st_ino)
            lockDescriptor = lock
            beginAccepting()
        } catch { Darwin.close(lock); throw error }
    }

    private func beginAccepting() {
        guard accepting == nil else { return }
        accepting = Task { [weak self] in
            while !Task.isCancelled {
                await self?.acceptOne()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func acceptOne() {
        guard accepting != nil, !isStopping, let listener, admitted.count < 16 else { return }
        let descriptor = accept(listener, nil, nil)
        guard descriptor >= 0 else { return }
        var user: uid_t = 0
        var group: gid_t = 0
        guard getpeereid(descriptor, &user, &group) == 0, user == getuid() else { Darwin.close(descriptor); return }
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        let id = UUID()
        let dispatcher = dispatcher
        admitted[id] = Task.detached { [weak self] in
            defer { Darwin.close(descriptor) }
            do {
                let data = try LocalIPC.readFrame(descriptor: descriptor, maximumBytes: 1024 * 1024)
                let command = try JSONDecoder().decode(AutomationCommand.self, from: data)
                let reply = await dispatcher(command, .cli)
                try LocalIPC.writeFrame(JSONEncoder().encode(reply), descriptor: descriptor)
            } catch {}
            await self?.finished(id)
        }
    }

    private func finished(_ id: UUID) { admitted.removeValue(forKey: id) }

    @discardableResult
    public func stop(drainTimeout: TimeInterval = 30) async -> Bool {
        if isStopping {
            while isStopping { try? await Task.sleep(for: .milliseconds(25)) }
            return lockDescriptor == nil
        }
        guard lockDescriptor != nil else { return true }
        isStopping = true
        defer { isStopping = false }
        accepting?.cancel()
        accepting = nil
        let deadline = Date().addingTimeInterval(drainTimeout)
        while !admitted.isEmpty {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(25))
        }
        if let listener { Darwin.close(listener); self.listener = nil }
        var metadata = stat()
        if let identity = socketIdentity, lstat(path, &metadata) == 0,
            metadata.st_dev == identity.device, metadata.st_ino == identity.inode
        {
            unlink(path)
        }
        socketIdentity = nil
        if let lockDescriptor { Darwin.close(lockDescriptor); self.lockDescriptor = nil }
        return true
    }
}
