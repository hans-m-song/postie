import Foundation
import Darwin
import PostieAutomation
import PostieControl

@main
struct PostieCLI {
    static func main() async {
        do {
            var arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.isEmpty || arguments == ["--help"] {
                print(
                    """
                    Usage: PostieCLI [--socket-path PATH] OPERATION [--arguments JSON | --stdin]

                    Operations:
                    \(AutomationOperation.allCases.map(\.rawValue).joined(separator: "\n"))

                    Requires an existing Postie instance. JSON output includes resolved response
                    values without MCP redaction. Direct secret-variable reads are unavailable.
                    Supply sensitive arguments through --stdin rather than shell history.
                    """)
                return
            }
            var path = LocalIPC.defaultSocketPath
            if arguments.first == "--socket-path" {
                guard arguments.count >= 3 else { throw CLIError.usage }
                path = arguments[1]
                arguments.removeFirst(2)
            }
            guard let name = arguments.first, let operation = AutomationOperation(rawValue: name) else {
                throw CLIError.usage
            }
            arguments.removeFirst()
            let data: Data
            if arguments == ["--stdin"] {
                var input = Data()
                while input.count <= 1024 * 1024 {
                    let chunk =
                        try FileHandle.standardInput.read(upToCount: min(65_536, 1024 * 1024 + 1 - input.count))
                        ?? Data()
                    if chunk.isEmpty { break }
                    input.append(chunk)
                }
                data = input
            } else if arguments.count == 2, arguments[0] == "--arguments" {
                data = Data(arguments[1].utf8)
            } else if arguments.isEmpty {
                data = Data("{}".utf8)
            } else {
                throw CLIError.usage
            }
            guard data.count <= 1024 * 1024 else { throw CLIError.usage }
            let values = try JSONDecoder().decode([String: AutomationJSON].self, from: data)
            let reply = try await LocalIPC.send(
                AutomationCommand(operation: operation, arguments: values), socketPath: path)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let output = try encoder.encode(reply)
            FileHandle.standardOutput.write(output)
            FileHandle.standardOutput.write(Data([10]))
            if reply.error != nil { exit(1) }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}

private enum CLIError: LocalizedError {
    case usage
    var errorDescription: String? { "Invalid arguments. Use PostieCLI --help." }
}
