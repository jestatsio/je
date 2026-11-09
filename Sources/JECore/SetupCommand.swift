import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct SetupCommandResult: Equatable, Sendable {
    public let status: Int32
    public let stdout: String

    public init(status: Int32, stdout: String) {
        self.status = status
        self.stdout = stdout
    }
}

public protocol SetupCommandRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) -> SetupCommandResult
}

public struct ProcessSetupCommandRunner: SetupCommandRunning {
    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) -> SetupCommandResult {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let timeoutState = SetupTimeoutState()
        let timeout = DispatchWorkItem {
            if process.isRunning {
                timeoutState.markTimedOut()
                process.terminate()
            }
        }
        do {
            try process.run()
        } catch {
            return SetupCommandResult(status: -1, stdout: "")
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60, execute: timeout)
        let data: Data
        do {
            data = try stdout.fileHandleForReading.read(upToCount: 1024 * 1024 + 1) ?? Data()
        } catch {
            timeout.cancel()
            if process.isRunning { process.terminate() }
            return SetupCommandResult(status: -1, stdout: "")
        }
        if data.count > 1024 * 1024, process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        timeout.cancel()
        if timeoutState.timedOut || data.count > 1024 * 1024 {
            return SetupCommandResult(status: -1, stdout: "")
        }
        let status = process.terminationReason == .uncaughtSignal
            ? 128 + process.terminationStatus
            : process.terminationStatus
        return SetupCommandResult(
            status: status,
            stdout: String(data: data, encoding: .utf8) ?? ""
        )
    }
}

private final class SetupTimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func markTimedOut() {
        lock.withLock { flag = true }
    }

    var timedOut: Bool {
        lock.withLock { flag }
    }
}

public protocol SetupConfirming: Sendable {
    var canPrompt: Bool { get }
    func readAnswer() -> Bool
}

public struct TerminalSetupConfirmer: SetupConfirming {
    public init() {}

    public var canPrompt: Bool {
        isatty(FileHandle.standardInput.fileDescriptor) != 0
    }

    public func readAnswer() -> Bool {
        guard let line = readLine() else { return false }
        let answer = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return answer == "y" || answer == "yes"
    }
}

public enum SetupClient: String, Equatable, Sendable {
    case codex
    case claudeCode = "claude"

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude Code"
        }
    }

    var scopePhrase: String {
        switch self {
        case .codex: return "in Codex for this user"
        case .claudeCode: return "in Claude Code at user scope"
        }
    }
}

public struct SetupConfiguration: Equatable, Sendable {
    public let client: SetupClient?
    public let confirmed: Bool
    public let dryRun: Bool
    public let remove: Bool

    public init(client: SetupClient?, confirmed: Bool, dryRun: Bool, remove: Bool) {
        self.client = client
        self.confirmed = confirmed
        self.dryRun = dryRun
        self.remove = remove
    }
}

public enum SetupCommand {
    private static let marketplaceName = "jestudio"
    private static let marketplaceSource = "jestatsio/je"
    private static let pluginID = "je@jestudio"

    public static func run(
        configuration: SetupConfiguration,
        environment: [String: String],
        runner: SetupCommandRunning,
        confirmer: SetupConfirming,
        stdoutSink: CLIOutputSink?
    ) -> CLIResult {
        var session = Session(
            configuration: configuration,
            environment: environment,
            runner: runner,
            confirmer: confirmer,
            stdoutSink: stdoutSink
        )
        return session.run()
    }

    private enum Outcome {
        case success
        case skipped
        case missing
        case failed
    }

    private struct ClientState {
        var marketplacePresent = false
        var installed = false
        var enabled = false
    }

    private struct Session {
        let configuration: SetupConfiguration
        let environment: [String: String]
        let runner: SetupCommandRunning
        let confirmer: SetupConfirming
        let stdoutSink: CLIOutputSink?
        var stdoutBuffer = ""
        var stderrBuffer = ""

        mutating func run() -> CLIResult {
            emit("Studio integration adds connection, status, and memory skills.\n")
            emit("It does not change models, credentials, approvals, or memory connections.\n")
            let clients: [SetupClient] = configuration.client.map { [$0] } ?? [.codex, .claudeCode]
            var detected = 0
            var failed = false
            for client in clients {
                let outcome = process(client)
                if outcome != .missing { detected += 1 }
                if outcome == .failed { failed = true }
            }
            let code: Int32 = (!failed && detected > 0) ? 0 : 1
            return CLIResult(
                code: code,
                stdout: stdoutSink == nil ? stdoutBuffer : "",
                stderr: stderrBuffer
            )
        }

        private mutating func emit(_ text: String) {
            stdoutBuffer += text
            stdoutSink?(text)
        }

        private mutating func fail(_ client: SetupClient, _ detail: String) -> Outcome {
            stderrBuffer += "\(client.displayName) setup failed. \(detail)\n"
            return .failed
        }

        private enum FlowFailure: Error {
            case detail(String)
        }

        private static let nativeCommandFailedDetail =
            "The native plugin command failed. Check the client's plugin settings and retry."

        private mutating func process(_ client: SetupClient) -> Outcome {
            guard let executable = resolve(client) else {
                emit("\(client.displayName) is not installed. Install it separately to add the Studio plugin.\n")
                return .missing
            }
            let versionResult = runner.run(
                executable: executable, arguments: ["--version"], environment: environment)
            guard versionResult.status == 0,
                  let version = Self.version(from: versionResult.stdout, client: client) else {
                return fail(client, "Cannot read the client version. Update the client and retry.")
            }
            emit("\(client.displayName) \(version) detected.\n")
            let help = runner.run(
                executable: executable,
                arguments: helpArguments(client),
                environment: environment
            )
            guard help.status == 0, help.stdout.contains("--json") else {
                return fail(
                    client,
                    "Update the client to a version with native plugin management and JSON output.")
            }
            let state: ClientState
            do {
                state = try fetchState(client, executable: executable)
            } catch FlowFailure.detail(let detail) {
                return fail(client, detail)
            } catch {
                return fail(client, Self.nativeCommandFailedDetail)
            }
            if configuration.remove {
                return planRemove(client, executable: executable, state: state)
            }
            return planInstall(client, executable: executable, state: state)
        }

        private mutating func planInstall(
            _ client: SetupClient, executable: URL, state: ClientState
        ) -> Outcome {
            if state.installed {
                guard state.marketplacePresent else {
                    return fail(
                        client,
                        "Cannot verify the installed je plugin source. Check its marketplace in the native client.")
                }
                guard state.enabled else {
                    return fail(
                        client,
                        "The je plugin is installed but disabled. Enable it in the native client if intended.")
                }
                emit("\(client.displayName) plugin is already installed and enabled.\n")
                return .success
            }
            emit("Install \(SetupCommand.pluginID) from \(SetupCommand.marketplaceSource) \(client.scopePhrase).\n")
            if let done = gate(client) { return done }
            return install(client, executable: executable, state: state)
        }

        private mutating func planRemove(
            _ client: SetupClient, executable: URL, state: ClientState
        ) -> Outcome {
            guard state.installed else {
                emit("\(client.displayName) plugin is not installed. Nothing to remove.\n")
                return .success
            }
            guard state.marketplacePresent else {
                return fail(
                    client,
                    "Cannot verify the installed je plugin source. Check its marketplace in the native client.")
            }
            emit("Remove \(SetupCommand.pluginID) from \(SetupCommand.marketplaceSource) \(client.scopePhrase).\n")
            if let done = gate(client) { return done }
            return removePlugin(client, executable: executable)
        }

        /// Returns a finished outcome, or nil to proceed with changes.
        private mutating func gate(_ client: SetupClient) -> Outcome? {
            if configuration.dryRun {
                emit("Dry run. No plugin or marketplace changes were made.\n")
                return .success
            }
            if configuration.confirmed {
                return nil
            }
            guard confirmer.canPrompt else {
                return fail(
                    client,
                    "Run setup interactively to confirm, or pass --yes for the displayed integration.")
            }
            emit("Continue? [y/N] ")
            if confirmer.readAnswer() {
                return nil
            }
            emit("Skipped \(client.displayName).\n")
            return .skipped
        }

        private mutating func install(
            _ client: SetupClient, executable: URL, state: ClientState
        ) -> Outcome {
            do {
                var current = state
                if !current.marketplacePresent {
                    let added = runner.run(
                        executable: executable,
                        arguments: marketplaceAddArguments(client),
                        environment: environment
                    )
                    guard added.status == 0 else {
                        return fail(client, Self.nativeCommandFailedDetail)
                    }
                    current = try fetchState(client, executable: executable)
                    guard current.marketplacePresent else {
                        return fail(
                            client,
                            "Cannot verify marketplace registration. No plugin was installed.")
                    }
                }
                let added = runner.run(
                    executable: executable,
                    arguments: pluginAddArguments(client),
                    environment: environment
                )
                guard added.status == 0 else {
                    return fail(client, Self.nativeCommandFailedDetail)
                }
                current = try fetchState(client, executable: executable)
                guard current.installed, current.enabled else {
                    return fail(
                        client,
                        "Cannot verify the plugin change. Inspect je in the native client's plugin manager.")
                }
                emit("Installed the \(client.displayName) je plugin. Start a new client session to use its skills.\n")
                return .success
            } catch FlowFailure.detail(let detail) {
                return fail(client, detail)
            } catch {
                return fail(client, Self.nativeCommandFailedDetail)
            }
        }

        private mutating func removePlugin(
            _ client: SetupClient, executable: URL
        ) -> Outcome {
            do {
                let removed = runner.run(
                    executable: executable,
                    arguments: pluginRemoveArguments(client),
                    environment: environment
                )
                guard removed.status == 0 else {
                    return fail(client, Self.nativeCommandFailedDetail)
                }
                let current = try fetchState(client, executable: executable)
                guard !current.installed else {
                    return fail(
                        client,
                        "Cannot verify the plugin change. Inspect je in the native client's plugin manager.")
                }
                emit("Removed the \(client.displayName) je plugin. Its marketplace remains registered.\n")
                return .success
            } catch FlowFailure.detail(let detail) {
                return fail(client, detail)
            } catch {
                return fail(client, Self.nativeCommandFailedDetail)
            }
        }

        private func fetchState(_ client: SetupClient, executable: URL) throws -> ClientState {
            let marketplaceResult = runner.run(
                executable: executable,
                arguments: ["plugin", "marketplace", "list", "--json"],
                environment: environment
            )
            guard marketplaceResult.status == 0 else {
                throw FlowFailure.detail(Self.nativeCommandFailedDetail)
            }
            let marketplaces = try Self.dictionaries(
                from: marketplaceResult.stdout,
                client: client,
                marketplaceList: true
            )
            var state = ClientState()
            for entry in marketplaces where entry["name"] as? String == SetupCommand.marketplaceName {
                guard Self.marketplaceSourceValid(client, entry: entry) else {
                    throw FlowFailure.detail(
                        "The jestudio marketplace uses a different source. Resolve it in the native client first.")
                }
                state.marketplacePresent = true
                break
            }
            let listResult = runner.run(
                executable: executable,
                arguments: ["plugin", "list", "--json"],
                environment: environment
            )
            guard listResult.status == 0 else {
                throw FlowFailure.detail(Self.nativeCommandFailedDetail)
            }
            let installed = try Self.dictionaries(
                from: listResult.stdout, client: client, marketplaceList: false)
            for entry in installed where Self.isStudioPlugin(client, entry: entry) {
                if client == .claudeCode,
                   let scope = entry["scope"] as? String, scope != "user" {
                    throw FlowFailure.detail(
                        "The je plugin is configured at another Claude scope. Manage that scope in Claude Code first.")
                }
                guard let enabled = entry["enabled"] as? Bool else {
                    throw FlowFailure.detail(
                        "The native plugin listing has an invalid enabled state.")
                }
                state.installed = true
                state.enabled = enabled
                break
            }
            return state
        }

        private static func dictionaries(
            from stdout: String, client: SetupClient, marketplaceList: Bool
        ) throws -> [[String: Any]] {
            guard let data = stdout.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) else {
                throw FlowFailure.detail("The native plugin command returned invalid JSON.")
            }
            let list: [Any]?
            if marketplaceList, client == .codex {
                list = (parsed as? [String: Any])?["marketplaces"] as? [Any]
            } else if !marketplaceList, client == .codex {
                list = (parsed as? [String: Any])?["installed"] as? [Any]
            } else {
                list = parsed as? [Any]
            }
            guard let list else {
                throw FlowFailure.detail("The native plugin command returned invalid JSON.")
            }
            return list.compactMap { $0 as? [String: Any] }
        }

        private static func isStudioPlugin(_ client: SetupClient, entry: [String: Any]) -> Bool {
            switch client {
            case .codex:
                return entry["name"] as? String == "je"
                    && entry["marketplaceName"] as? String == marketplaceName
            case .claudeCode:
                return entry["id"] as? String == pluginID
            }
        }

        private static func marketplaceSourceValid(
            _ client: SetupClient, entry: [String: Any]
        ) -> Bool {
            switch client {
            case .codex:
                guard let source = entry["marketplaceSource"] as? [String: Any],
                      source["sourceType"] as? String == "git",
                      let value = source["source"] as? String else {
                    return false
                }
                return gitRepoMatches(value)
            case .claudeCode:
                guard let kind = entry["source"] as? String else { return false }
                if kind == "github" {
                    return gitRepoMatches(entry["repo"] as? String ?? entry["url"] as? String ?? "")
                }
                if kind == "git" {
                    return gitRepoMatches(entry["url"] as? String ?? entry["repo"] as? String ?? "")
                }
                return false
            }
        }

        private static func gitRepoMatches(_ value: String) -> Bool {
            var host = "github.com"
            var path = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("git@") {
                let rest = String(path.dropFirst("git@".count))
                guard let colon = rest.firstIndex(of: ":") else { return false }
                host = String(rest[..<colon])
                path = String(rest[rest.index(after: colon)...])
            } else if let scheme = path.range(of: "://") {
                let rest = String(path[scheme.upperBound...])
                guard let slash = rest.firstIndex(of: "/") else { return false }
                var authority = String(rest[..<slash])
                if let at = authority.lastIndex(of: "@") {
                    authority = String(authority[authority.index(after: at)...])
                }
                host = authority.split(separator: ":").first.map(String.init) ?? authority
                path = String(rest[rest.index(after: slash)...])
            }
            while path.hasSuffix("/") { path.removeLast() }
            if path.lowercased().hasSuffix(".git") {
                path = String(path.dropLast(4))
            }
            return host.lowercased() == "github.com" && path.lowercased() == marketplaceSource
        }

        private func resolve(_ client: SetupClient) -> URL? {
            if let found = JECommandLine.searchExecutableOnPath(
                named: client.rawValue, environment: environment) {
                return found
            }
            guard client == .claudeCode else { return nil }
            let home: URL
            if let value = environment["HOME"], !value.isEmpty {
                home = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
            } else {
                home = FileManager.default.homeDirectoryForCurrentUser
            }
            let candidate = home.appendingPathComponent(".local/bin/claude")
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  FileManager.default.isExecutableFile(atPath: candidate.path) else {
                return nil
            }
            return candidate
        }

        private func helpArguments(_ client: SetupClient) -> [String] {
            switch (client, configuration.remove) {
            case (.codex, false): return ["plugin", "add", "--help"]
            case (.codex, true): return ["plugin", "remove", "--help"]
            case (.claudeCode, false): return ["plugin", "install", "--help"]
            case (.claudeCode, true): return ["plugin", "uninstall", "--help"]
            }
        }

        private func marketplaceAddArguments(_ client: SetupClient) -> [String] {
            switch client {
            case .codex: return ["plugin", "marketplace", "add", SetupCommand.marketplaceSource, "--json"]
            case .claudeCode: return ["plugin", "marketplace", "add", SetupCommand.marketplaceSource]
            }
        }

        private func pluginAddArguments(_ client: SetupClient) -> [String] {
            switch client {
            case .codex: return ["plugin", "add", SetupCommand.pluginID, "--json"]
            case .claudeCode: return ["plugin", "install", SetupCommand.pluginID, "--scope", "user", "--json"]
            }
        }

        private func pluginRemoveArguments(_ client: SetupClient) -> [String] {
            switch client {
            case .codex: return ["plugin", "remove", SetupCommand.pluginID, "--json"]
            case .claudeCode: return ["plugin", "uninstall", SetupCommand.pluginID, "--scope", "user", "--json"]
            }
        }

        private static func version(from stdout: String, client: SetupClient) -> String? {
            switch client {
            case .codex:
                return CodexCatalogLoader.recognizedVersion(in: stdout)
            case .claudeCode:
                let firstLine = stdout.split(separator: "\n", maxSplits: 1).first ?? ""
                for token in firstLine.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                    if isVersionToken(String(token)) {
                        return String(token)
                    }
                }
                return nil
            }
        }

        private static func isVersionToken(_ token: String) -> Bool {
            let buildParts = token.split(separator: "+", omittingEmptySubsequences: false)
            guard buildParts.count == 1 || buildParts.count == 2,
                  buildParts.allSatisfy({ !$0.isEmpty }) else { return false }
            if buildParts.count == 2, !isIdentifierList(String(buildParts[1])) {
                return false
            }
            let parts = buildParts[0].split(
                separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, !isIdentifierList(String(parts[1])) {
                return false
            }
            let core = parts[0].split(separator: ".", omittingEmptySubsequences: false)
            return core.count == 3
                && core.allSatisfy { !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }
        }

        private static func isIdentifierList(_ value: String) -> Bool {
            let identifiers = value.split(separator: ".", omittingEmptySubsequences: false)
            return !identifiers.isEmpty && identifiers.allSatisfy { identifier in
                !identifier.isEmpty && identifier.allSatisfy { character in
                    character.isASCII
                        && (character.isLetter || character.isNumber || character == "-")
                }
            }
        }
    }
}
