import Darwin
import Dispatch
import Foundation

private struct HTTPRequest {
    let method: String
    let path: String
    let query: String
    let headers: [(String, String)]
    let body: Data
}

private final class LoopbackHTTPServer {
    private let socketDescriptor: Int32
    let port: UInt16

    init(port requestedPort: UInt16) throws {
        let socketDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        self.socketDescriptor = socketDescriptor

        var reuseAddress: Int32 = 1
        _ = setsockopt(socketDescriptor, SOL_SOCKET, SO_REUSEADDR, &reuseAddress, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = requestedPort.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(socketDescriptor, SOMAXCONN) == 0 else {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            Darwin.close(socketDescriptor)
            throw error
        }

        var boundAddress = sockaddr_in()
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let addressResult = withUnsafeMutablePointer(to: &boundAddress) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(socketDescriptor, $0, &addressLength)
            }
        }
        guard addressResult == 0 else {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            Darwin.close(socketDescriptor)
            throw error
        }

        self.port = UInt16(bigEndian: boundAddress.sin_port)
    }

    func serveForever() {
        while true {
            let client = Darwin.accept(socketDescriptor, nil, nil)
            guard client >= 0 else {
                if errno == EINTR { continue }
                return
            }

            DispatchQueue.global(qos: .userInitiated).async {
                Self.handle(client)
            }
        }
    }

    private static func handle(_ client: Int32) {
        defer { Darwin.close(client) }
        var suppressSIGPIPE: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &suppressSIGPIPE, socklen_t(MemoryLayout<Int32>.size))

        guard let request = readRequest(from: client) else { return }
        let query = queryValues(request.query)

        if request.path == "/delay" {
            let seconds = boundedDouble(query["seconds"]?.first, default: 1, range: 0...10)
            Thread.sleep(forTimeInterval: seconds)
        }

        if request.path == "/redirect" || request.path == "/loop" {
            let location = request.path == "/loop" ? "/loop" : query["to"]?.first ?? "/echo"
            let status = integer(query["status"]?.first, default: 302)
            _ = sendHeaders(
                client,
                status: status,
                headers: [("Location", location), ("X-Redirect-Hop", "fixture"), ("Content-Length", "0")]
            )
            return
        }

        if request.path == "/large" || request.path == "/stream" {
            let count = boundedInteger(query["bytes"]?.first, default: 2_097_152, range: 0...33_554_432)
            let chunked = request.path == "/stream"
            var headers = [("Content-Type", "text/plain")]
            if chunked {
                headers.append(("Transfer-Encoding", "chunked"))
            } else {
                headers.append(("Content-Length", String(count)))
            }

            guard sendHeaders(client, status: 200, headers: headers), request.method != "HEAD" else { return }
            let delay = boundedDouble(query["chunk_delay"]?.first, default: 0, range: 0...0.1)
            writeRepeatedByte(client, byte: 0x78, count: count, chunked: chunked, delay: delay)
            return
        }

        if request.path == "/binary" {
            var bytes = [UInt8]()
            bytes.reserveCapacity(1_024)
            for _ in 0..<4 { bytes.append(contentsOf: 0...255) }
            sendFixtureBytes(client, status: 200, body: Data(bytes), contentType: "application/octet-stream", headOnly: request.method == "HEAD")
            return
        }

        let payload: [String: Any] = [
            "method": request.method,
            "path": request.path,
            "query": request.query,
            "headers": request.headers.map { [$0.0, $0.1] },
            "body": String(decoding: request.body, as: UTF8.self)
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else { return }
        let status = request.path == "/status" ? integer(query["status"]?.first, default: 200) : 200
        sendFixtureBytes(client, status: status, body: body, contentType: "application/json", headOnly: request.method == "HEAD")
    }

    private static func readRequest(from socket: Int32) -> HTTPRequest? {
        let headerLimit = 65_536
        let bodyLimit = 1_048_576
        let separator = Data([13, 10, 13, 10])
        var incoming = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var headerRange = incoming.range(of: separator)

        while headerRange == nil {
            let result = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.recv(socket, rawBuffer.baseAddress, rawBuffer.count, 0)
            }
            guard result > 0 else { return nil }
            incoming.append(contentsOf: buffer.prefix(result))
            guard incoming.count <= headerLimit + buffer.count else { return nil }
            headerRange = incoming.range(of: separator)
        }

        guard let headerRange, headerRange.lowerBound <= headerLimit else { return nil }
        let headerData = incoming[..<headerRange.lowerBound]
        let headerText = String(decoding: headerData, as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard requestParts.count >= 2 else { return nil }

        var headers = [(String, String)]()
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon])
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            headers.append((name, value))
        }

        let contentLength = headers.first { $0.0.caseInsensitiveCompare("Content-Length") == .orderedSame }
            .flatMap { Int($0.1) } ?? 0
        let bodyCount = min(max(contentLength, 0), bodyLimit)
        let bodyStart = headerRange.upperBound
        var body = Data(incoming[bodyStart...].prefix(bodyCount))

        while body.count < bodyCount {
            let remaining = bodyCount - body.count
            let result = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.recv(socket, rawBuffer.baseAddress, min(rawBuffer.count, remaining), 0)
            }
            guard result > 0 else { return nil }
            body.append(contentsOf: buffer.prefix(result))
        }

        let rawTarget = String(requestParts[1])
        let targetParts = rawTarget.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = targetParts.first.map(String.init) ?? "/"
        let query = targetParts.count > 1 ? String(targetParts[1]) : ""
        return HTTPRequest(method: String(requestParts[0]), path: path, query: query, headers: headers, body: body)
    }

    private static func queryValues(_ query: String) -> [String: [String]] {
        guard let items = URLComponents(string: "http://127.0.0.1/?\(query)")?.queryItems else { return [:] }
        return items.reduce(into: [:]) { values, item in
            values[item.name, default: []].append(item.value ?? "")
        }
    }

    private static func integer(_ value: String?, default defaultValue: Int) -> Int {
        guard let value, let parsed = Int(value) else { return defaultValue }
        return parsed
    }

    private static func boundedInteger(_ value: String?, default defaultValue: Int, range: ClosedRange<Int>) -> Int {
        min(max(integer(value, default: defaultValue), range.lowerBound), range.upperBound)
    }

    private static func boundedDouble(_ value: String?, default defaultValue: Double, range: ClosedRange<Double>) -> Double {
        guard let value, let parsed = Double(value), parsed.isFinite else { return defaultValue }
        return min(max(parsed, range.lowerBound), range.upperBound)
    }

    private static func sendFixtureBytes(_ socket: Int32, status: Int, body: Data, contentType: String, headOnly: Bool) {
        let headers = [
            ("Content-Type", contentType),
            ("Content-Length", String(body.count)),
            ("X-Postie-Fixture", "synthetic")
        ]
        guard sendHeaders(socket, status: status, headers: headers), !headOnly else { return }
        _ = sendAll(socket, data: body)
    }

    private static func sendHeaders(_ socket: Int32, status: Int, headers: [(String, String)]) -> Bool {
        let reason = HTTPURLResponse.localizedString(forStatusCode: status)
        var response = Data("HTTP/1.1 \(status) \(reason)\r\n".utf8)
        for (name, value) in headers {
            response.append(contentsOf: "\(name): \(value)\r\n".utf8)
        }
        response.append(contentsOf: "Connection: close\r\n\r\n".utf8)
        return sendAll(socket, data: response)
    }

    private static func writeRepeatedByte(_ socket: Int32, byte: UInt8, count: Int, chunked: Bool, delay: Double) {
        var remaining = count
        while remaining > 0 {
            let blockCount = min(remaining, 16_384)
            let block = Data(repeating: byte, count: blockCount)
            if chunked {
                var framed = Data("\(String(blockCount, radix: 16))\r\n".utf8)
                framed.append(block)
                framed.append(contentsOf: [13, 10])
                guard sendAll(socket, data: framed) else { return }
            } else if !sendAll(socket, data: block) {
                return
            }

            remaining -= blockCount
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        }

        if chunked { _ = sendAll(socket, data: Data([48, 13, 10, 13, 10])) }
    }

    private static func sendAll(_ socket: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return data.isEmpty }
            var sent = 0
            while sent < rawBuffer.count {
                let result = Darwin.send(socket, baseAddress.advanced(by: sent), rawBuffer.count - sent, 0)
                guard result > 0 else {
                    if errno == EINTR { continue }
                    return false
                }
                sent += result
            }
            return true
        }
    }
}

private enum FixtureArgumentError: Error, CustomStringConvertible {
    case invalidArguments

    var description: String { "usage: PostieHTTPFixture [--port 0...65535]" }

    static func requestedPort(from arguments: [String]) throws -> UInt16 {
        guard !arguments.isEmpty else { return 0 }
        guard arguments.count == 2,
              arguments[0] == "--port",
              let port = UInt16(arguments[1]) else {
            throw FixtureArgumentError.invalidArguments
        }
        return port
    }
}

do {
    let port = try FixtureArgumentError.requestedPort(from: Array(CommandLine.arguments.dropFirst()))
    let server = try LoopbackHTTPServer(port: port)
    let startup = try JSONSerialization.data(withJSONObject: ["port": Int(server.port)])
    FileHandle.standardOutput.write(startup)
    FileHandle.standardOutput.write(Data([10]))
    server.serveForever()
} catch {
    FileHandle.standardError.write(Data("PostieHTTPFixture: \(error)\n".utf8))
    Darwin.exit(EXIT_FAILURE)
}
