import Foundation

public struct CLIResult: Equatable, Sendable {
    public let code: Int32
    public let stdout: String
    public let stderr: String

    public init(code: Int32, stdout: String = "", stderr: String = "") {
        self.code = code
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum JECommandLine {
    private static let invalidArguments = "Invalid arguments. Run je --help or the command's --help.\n"
    private static let legacyCommands: Set<String> = [
        "setup", "connect", "run", "doctor", "export", "credential"
    ]

    public static func run(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        recordedDay: String? = nil,
        runID: String? = nil
    ) -> CLIResult {
        var remaining = arguments
        var explicitStateDirectory: String?
        while let first = remaining.first {
            if first == "--state-dir" {
                guard remaining.count >= 2 else { return invalid() }
                explicitStateDirectory = remaining[1]
                remaining.removeFirst(2)
            } else if first.hasPrefix("--state-dir=") {
                let value = String(first.dropFirst("--state-dir=".count))
                guard !value.isEmpty else { return invalid() }
                explicitStateDirectory = value
                remaining.removeFirst()
            } else {
                break
            }
        }
        guard let command = remaining.first else {
            return CLIResult(code: 2, stderr: invalidArguments)
        }

        switch command {
        case "--version":
            guard remaining.count == 1 else { return invalid() }
            return CLIResult(code: 0, stdout: "je \(JEVersion.current)\n")
        case "--help", "-h", "help":
            guard remaining.count == 1 else { return invalid() }
            return CLIResult(code: 0, stdout: helpText)
        case "status":
            return status(arguments: remaining)
        case "support-matrix":
            return supportMatrix(arguments: remaining)
        case "contracts":
            return contracts(arguments: remaining)
        case "why", "ask":
            return AskWhyCommand.run(
                command: command,
                arguments: remaining,
                stateDirectory: stateDirectory(
                    explicit: explicitStateDirectory,
                    environment: environment
                ),
                environment: environment,
                recordedDay: recordedDay,
                runID: runID
            )
        case "profile":
            return profile(
                arguments: remaining,
                explicitStateDirectory: explicitStateDirectory,
                environment: environment
            )
        case "memory":
            return memory(
                arguments: remaining,
                explicitStateDirectory: explicitStateDirectory,
                environment: environment
            )
        case "ollama":
            return ollama(
                arguments: remaining,
                explicitStateDirectory: explicitStateDirectory,
                environment: environment
            )
        case "workspace":
            return CLIResult(
                code: 2,
                stderr: "Workspace administration is host-only and is not part of the user artifact.\n"
            )
        default:
            if legacyCommands.contains(command) {
                return CLIResult(
                    code: 2,
                    stderr: "This command is not ported to the native core yet. Use the released Python client for now.\n"
                )
            }
            return invalid()
        }
    }

    private static func status(arguments: [String]) -> CLIResult {
        if arguments == ["status", "--json"] {
            return json(StatusReport.current)
        }
        guard arguments == ["status"] else { return invalid() }
        let summary = SupportMatrix.summary
        return CLIResult(code: 0, stdout: """
        je native core \(JEVersion.current)
        Python oracle \(JEVersion.pythonOracleVersion)
        Support matrix cells \(summary.totalCells)
        User modules \(ArtifactBoundary.userArtifactModules.count)
        Host-only modules excluded \(ArtifactBoundary.hostOnlyModules.count)

        """)
    }

    private static func supportMatrix(arguments: [String]) -> CLIResult {
        if arguments == ["support-matrix", "--json"] {
            return json(SupportMatrix.launchEntries)
        }
        guard arguments == ["support-matrix"] else { return invalid() }
        let summary = SupportMatrix.summary
        let counts = summary.countsByStatus
            .sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value)" }
            .joined(separator: ", ")
        return CLIResult(code: 0, stdout: "Launch support matrix: \(summary.totalCells) cells (\(counts)).\n")
    }

    private static func contracts(arguments: [String]) -> CLIResult {
        if arguments == ["contracts", "--json"] {
            return json(OracleContract.frozen)
        }
        guard arguments == ["contracts"] else { return invalid() }
        return CLIResult(code: 0, stdout: """
        Frozen Python oracle contract \(OracleContract.frozen.pythonOracleVersion)
        Profile schema versions \(OracleContract.frozen.profileSchemaVersions.map(String.init).joined(separator: ", "))
        \(OracleContract.frozen.invalidArgumentBehavior)

        """)
    }

    private static func profile(
        arguments: [String],
        explicitStateDirectory: String?,
        environment: [String: String]
    ) -> CLIResult {
        guard arguments.count >= 2 else { return invalid() }
        if arguments[1] == "add" || arguments[1] == "remove" {
            return CLIResult(
                code: 2,
                stderr: "Profile writes are not ported to the native core yet. Use the released Python client for now.\n"
            )
        }
        let store = ProfileStore(directory: stateDirectory(
            explicit: explicitStateDirectory,
            environment: environment
        ))
        do {
            if arguments == ["profile", "list"] {
                let names = try store.listProfiles()
                let output = names.isEmpty
                    ? "No saved connections. Run je profile add --help.\n"
                    : names.joined(separator: "\n") + "\n"
                return CLIResult(code: 0, stdout: output)
            }
            if arguments.count == 3 && arguments[1] == "show" {
                return json(try store.loadPublicProfile(name: arguments[2]))
            }
        } catch let error as StateStoreError {
            return CLIResult(code: 2, stderr: error.message + "\n")
        } catch {
            return CLIResult(code: 2, stderr: "The connection profile could not be read.\n")
        }
        return invalid()
    }

    private static func memory(
        arguments: [String],
        explicitStateDirectory: String?,
        environment: [String: String]
    ) -> CLIResult {
        guard arguments.count >= 2 else { return invalid() }
        if ["add", "remove", "check"].contains(arguments[1]) {
            return CLIResult(
                code: 2,
                stderr: "This memory command is not ported to the native core yet. Use the released Python client for now.\n"
            )
        }
        let store = ProfileStore(directory: stateDirectory(
            explicit: explicitStateDirectory,
            environment: environment
        ))
        do {
            if arguments == ["memory", "list"] {
                let names = try store.listMemoryProfiles()
                let output = names.isEmpty
                    ? "No saved memory connections. Run je memory add --help.\n"
                    : names.joined(separator: "\n") + "\n"
                return CLIResult(code: 0, stdout: output)
            }
            if arguments.count == 3 && arguments[1] == "show" {
                return json(try store.loadPublicMemoryProfile(name: arguments[2]))
            }
        } catch let error as StateStoreError {
            return CLIResult(code: 2, stderr: error.message + "\n")
        } catch {
            return CLIResult(code: 2, stderr: "The memory profile could not be read.\n")
        }
        return invalid()
    }

    private static func ollama(
        arguments: [String],
        explicitStateDirectory: String?,
        environment: [String: String]
    ) -> CLIResult {
        guard arguments.count >= 3, arguments[1] == "profile" else {
            if arguments.first == "ollama" {
                return CLIResult(
                    code: 2,
                    stderr: "Native Ollama launch and checks are not ported to the native core yet. Use the released Python client for now.\n"
                )
            }
            return invalid()
        }
        if ["add", "remove"].contains(arguments[2]) {
            return CLIResult(
                code: 2,
                stderr: "Native Ollama profile writes are not ported to the native core yet. Use the released Python client for now.\n"
            )
        }
        let store = ProfileStore(directory: stateDirectory(
            explicit: explicitStateDirectory,
            environment: environment
        ))
        do {
            if arguments == ["ollama", "profile", "list"] {
                let names = try store.listOllamaProfiles()
                let output = names.isEmpty
                    ? "No saved native connections. Run je ollama profile add --help.\n"
                    : names.joined(separator: "\n") + "\n"
                return CLIResult(code: 0, stdout: output)
            }
            if arguments.count == 4 && arguments[2] == "show" {
                return json(try store.loadPublicOllamaProfile(name: arguments[3]))
            }
        } catch let error as StateStoreError {
            return CLIResult(code: 2, stderr: error.message + "\n")
        } catch {
            return CLIResult(code: 2, stderr: "The native Ollama profile could not be read.\n")
        }
        return invalid()
    }

    private static func stateDirectory(
        explicit: String?,
        environment: [String: String]
    ) -> URL {
        if let explicit, !explicit.isEmpty {
            return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
        }
        for key in ["JE_STUDIO_HOME", "JE_GATEWAY_HOME"] {
            if let value = environment[key], !value.isEmpty {
                return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
            }
        }
        let configHome: URL
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            configHome = URL(fileURLWithPath: (xdg as NSString).expandingTildeInPath)
        } else if let home = environment["HOME"], !home.isEmpty {
            configHome = URL(fileURLWithPath: home).appendingPathComponent(".config")
        } else {
            configHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        }
        return configHome.appendingPathComponent("je-gateway")
    }

    private static func json<T: Encodable>(_ value: T) -> CLIResult {
        do {
            return CLIResult(code: 0, stdout: try StableJSON.encode(value))
        } catch {
            return CLIResult(code: 1, stderr: "Could not encode the requested report.\n")
        }
    }

    private static func invalid() -> CLIResult {
        CLIResult(code: 2, stderr: invalidArguments)
    }

    private static let helpText = """
    usage: je [--version] [--state-dir DIR] <command>

    Experimental native user core for je.

    Commands:
      status [--json]          Show native core and support status
      support-matrix [--json]  Show the published launch qualification matrix
      contracts [--json]       Show the frozen Python oracle contract
      profile list             List saved connection names without credentials
      profile show NAME        Show public connection fields without credentials
      memory list              List saved memory connection names without tokens
      memory show NAME         Show public memory fields without tokens
      ollama profile list      List native Ollama connection names without credentials
      ollama profile show NAME Show public native Ollama fields without credentials
      why [flags] [--] PROMPT  Explain the selected qualified route without running it
      ask [flags] -- PROMPT    Select and show a route, then stop before unported launch

    Other released Python commands are not ported yet. Host administration stays
    outside the user artifact.

    """
}
