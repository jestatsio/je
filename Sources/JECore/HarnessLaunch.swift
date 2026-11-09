import Foundation

public struct HarnessLaunchSpec: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let currentDirectoryURL: URL?

    public init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
    }
}

public final class PreparedHarnessLaunch: @unchecked Sendable {
    public let spec: HarnessLaunchSpec
    private let temporaryDirectories: [URL]
    private var cleanedUp = false

    init(spec: HarnessLaunchSpec, temporaryDirectories: [URL] = []) {
        self.spec = spec
        self.temporaryDirectories = temporaryDirectories
    }

    public func cleanup() {
        guard !cleanedUp else { return }
        cleanedUp = true
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    deinit {
        cleanup()
    }
}

public enum HarnessLaunchError: Error, Equatable, Sendable {
    case unsupportedHarness
    case unsupportedPlace
    case connectionProfileRequired
    case modelMismatch
    case executableUnavailable(String)
    case catalogLaunchNotPorted
    case catalogInvalid(String)
    case catalogVersionMismatch
    case secretInArguments
    case secretInExecutablePath
    case authenticationFailed(String)
    case localModelUnavailable
    case localContractUnknown
    case preparationFailed
    case launchFailed

    public var message: String {
        switch self {
        case .unsupportedHarness:
            return "Harness launch is not ported for the selected route yet."
        case .unsupportedPlace:
            return "The selected route cannot launch from this execution place."
        case .connectionProfileRequired:
            return "The selected assignment does not name a usable connection profile."
        case .modelMismatch:
            return "The selected assignment model does not match its connection profile."
        case .executableUnavailable(let message):
            return message
        case .catalogLaunchNotPorted:
            return "Catalog-bound Codex launch is not ported to the native core yet."
        case .catalogInvalid(let message):
            return message
        case .catalogVersionMismatch:
            return "The installed Codex version does not match the saved catalog binding."
        case .secretInArguments:
            return "Do not place the gateway credential in command-line arguments."
        case .secretInExecutablePath:
            return "Do not place the gateway credential in the executable path."
        case .authenticationFailed(let message):
            return message
        case .localModelUnavailable:
            return "The Muse built-in local model is unavailable on this machine."
        case .localContractUnknown:
            return "The Muse local launch contract is not qualified for this version or assignment."
        case .preparationFailed:
            return "The harness launch could not be prepared."
        case .launchFailed:
            return "The harness process could not be started."
        }
    }
}

public protocol HarnessRunning: Sendable {
    func run(_ spec: HarnessLaunchSpec) throws -> Int32
}

public struct ProcessHarnessRunner: HarnessRunning {
    public init() {}

    public func run(_ spec: HarnessLaunchSpec) throws -> Int32 {
        let process = Process()
        process.executableURL = spec.executableURL
        process.arguments = spec.arguments
        process.environment = spec.environment
        if let currentDirectoryURL = spec.currentDirectoryURL {
            process.currentDirectoryURL = currentDirectoryURL
        }
        do {
            try process.run()
        } catch {
            throw HarnessLaunchError.launchFailed
        }
        process.waitUntilExit()
        if process.terminationReason == .uncaughtSignal {
            return 128 + process.terminationStatus
        }
        return process.terminationStatus
    }
}

public struct HarnessLaunchPreparer: Sendable {
    public static let museLocalProtocolImplementation = "muse-local-glimmer"

    public init() {}

    public static func isMuseLocal(_ candidate: RouteCandidate) -> Bool {
        candidate.harness == .muse
            && candidate.protocolImplementation == museLocalProtocolImplementation
    }

    public func prepareMuseLocal(
        candidate: RouteCandidate,
        prompt: String,
        environment: [String: String],
        executableOverride: String?,
        currentDirectoryURL: URL? = nil,
        discoveryReport: MuseContractReport? = nil,
        physicalMemoryBytes: UInt64? = nil
    ) throws -> PreparedHarnessLaunch {
        guard candidate.executionPlace == .personalMachine else {
            throw HarnessLaunchError.unsupportedPlace
        }
        guard Self.isMuseLocal(candidate),
              candidate.providerKind == .local,
              candidate.engine == .mlxNative,
              candidate.connectionProfileName == nil,
              candidate.cloudProfileReference == nil,
              ["local", "glimmer"].contains(candidate.modelArtifact) else {
            throw HarnessLaunchError.localContractUnknown
        }
        let executable = try resolveExecutable(
            override: executableOverride,
            defaultName: "muse",
            environment: environment
        )
        let report: MuseContractReport
        if let discoveryReport {
            report = discoveryReport
        } else {
            let discovery = physicalMemoryBytes.map {
                MuseContractDiscovery(physicalMemoryBytes: $0)
            } ?? MuseContractDiscovery()
            do {
                report = try discovery.discover(
                    executableOverride: executable.path,
                    environment: environment
                )
            } catch {
                throw HarnessLaunchError.localContractUnknown
            }
        }
        guard report.version == candidate.protocolVersion else {
            throw HarnessLaunchError.localContractUnknown
        }
        switch report.localContractStatus {
        case "builtin_glimmer_contract_discovered_not_qualified":
            break
        case "builtin_glimmer_unavailable_memory":
            throw HarnessLaunchError.localModelUnavailable
        default:
            throw HarnessLaunchError.localContractUnknown
        }
        guard let experimentVariable = report.experimentEnvironmentVariable else {
            throw HarnessLaunchError.localContractUnknown
        }

        let arguments: [String]
        switch candidate.launchMode {
        case .headless:
            arguments = ["exec", "--provider", "local", "--model", candidate.modelArtifact, prompt]
        case .interactive:
            arguments = ["--provider", "local", "--model", candidate.modelArtifact, prompt]
        case .singleStep:
            throw HarnessLaunchError.unsupportedHarness
        }
        var childEnvironment = environment
        childEnvironment.removeValue(forKey: "JE_GATEWAY_API_KEY")
        childEnvironment.removeValue(forKey: "JE_STUDIO_API_KEY")
        childEnvironment[experimentVariable] = "1"
        return PreparedHarnessLaunch(spec: HarnessLaunchSpec(
            executableURL: executable,
            arguments: arguments,
            environment: childEnvironment,
            currentDirectoryURL: currentDirectoryURL
        ))
    }

    public func prepare(
        candidate: RouteCandidate,
        profile: ResolvedConnectionProfile,
        prompt: String,
        environment: [String: String],
        executableOverride: String?,
        currentDirectoryURL: URL? = nil
    ) throws -> PreparedHarnessLaunch {
        guard candidate.executionPlace == .personalMachine else {
            throw HarnessLaunchError.unsupportedPlace
        }
        guard candidate.connectionProfileName == profile.name else {
            throw HarnessLaunchError.connectionProfileRequired
        }
        guard candidate.modelArtifact == profile.model else {
            throw HarnessLaunchError.modelMismatch
        }
        guard !prompt.contains(profile.secret) else {
            throw HarnessLaunchError.secretInArguments
        }
        let harness: ConnectHarness
        let trailingArguments: [String]
        switch candidate.harness {
        case .codex:
            harness = .codex
            switch candidate.launchMode {
            case .headless:
                trailingArguments = ["exec", "--json", prompt]
            case .interactive:
                trailingArguments = [prompt]
            case .singleStep:
                throw HarnessLaunchError.unsupportedHarness
            }
        case .claudeCode:
            harness = .claudeCode
            switch candidate.launchMode {
            case .headless:
                trailingArguments = ["--print", prompt]
            case .interactive:
                trailingArguments = [prompt]
            case .singleStep:
                throw HarnessLaunchError.unsupportedHarness
            }
        case .muse, .builtIn:
            throw HarnessLaunchError.unsupportedHarness
        }
        // Codex and Claude launches share the oracle connect configuration;
        // the prompt travels as the trailing harness arguments.
        do {
            return try ConnectLaunchPreparer().prepare(
                harness: harness,
                profile: profile,
                memory: nil,
                trailingArguments: trailingArguments,
                environment: environment,
                executableOverride: executableOverride,
                currentDirectoryURL: currentDirectoryURL
            )
        } catch let error as ConnectLaunchError {
            throw Self.translate(error)
        }
    }

    private static func translate(_ error: ConnectLaunchError) -> HarnessLaunchError {
        switch error {
        case .executableUnavailable(let harness):
            return .executableUnavailable(harness.installMessage)
        case .secretInArguments:
            return .secretInArguments
        case .secretInExecutablePath:
            return .secretInExecutablePath
        case .versionMismatch:
            return .catalogVersionMismatch
        case .versionTimedOut, .versionUnrecognized:
            return .catalogInvalid(error.message)
        case .catalogInvalid(let message):
            return .catalogInvalid(message)
        case .authenticationUnverified, .authenticationUnconfirmed, .authenticationMismatch:
            return .authenticationFailed(error.message)
        case .credentialsInPublicMetadata, .memoryRequiresQualifiedCodex, .preparationFailed:
            return .preparationFailed
        }
    }

    private func resolveExecutable(
        override: String?,
        defaultName: String,
        environment: [String: String]
    ) throws -> URL {
        let candidate: URL?
        if let override, !override.isEmpty {
            if override.contains("/") {
                candidate = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            } else {
                candidate = searchPath(for: override, environment: environment)
            }
        } else {
            candidate = searchPath(for: defaultName, environment: environment)
        }
        guard let candidate, FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw HarnessLaunchError.executableUnavailable(
                "The selected harness executable is unavailable.")
        }
        return candidate
    }

    private func searchPath(for name: String, environment: [String: String]) -> URL? {
        for directory in (environment["PATH"] ?? "").split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
