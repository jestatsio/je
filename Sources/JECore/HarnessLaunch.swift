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
    case executableUnavailable
    case catalogLaunchNotPorted
    case catalogInvalid(String)
    case catalogVersionMismatch
    case secretInArguments
    case authenticationFailed
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
        case .executableUnavailable:
            return "The selected harness executable is unavailable."
        case .catalogLaunchNotPorted:
            return "Catalog-bound Codex launch is not ported to the native core yet."
        case .catalogInvalid(let message):
            return message
        case .catalogVersionMismatch:
            return "The installed Codex version does not match the saved catalog binding."
        case .secretInArguments:
            return "The saved connection key cannot appear in the prompt or harness arguments."
        case .authenticationFailed:
            return "The harness did not accept the saved connection for this launch."
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
    public init() {}

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
        switch candidate.harness {
        case .codex:
            return try prepareCodex(
                candidate: candidate,
                profile: profile,
                prompt: prompt,
                environment: environment,
                executableOverride: executableOverride,
                currentDirectoryURL: currentDirectoryURL
            )
        case .claudeCode:
            return try prepareClaude(
                candidate: candidate,
                profile: profile,
                prompt: prompt,
                environment: environment,
                executableOverride: executableOverride,
                currentDirectoryURL: currentDirectoryURL
            )
        case .muse, .builtIn:
            throw HarnessLaunchError.unsupportedHarness
        }
    }

    private func prepareCodex(
        candidate: RouteCandidate,
        profile: ResolvedConnectionProfile,
        prompt: String,
        environment: [String: String],
        executableOverride: String?,
        currentDirectoryURL: URL?
    ) throws -> PreparedHarnessLaunch {
        let executable = try resolveExecutable(
            override: executableOverride,
            defaultName: "codex",
            environment: environment
        )
        var temporaryDirectories: [URL] = []
        do {
            var arguments = [
                "-c", "model=" + jsonString(profile.model),
                "-c", "model_provider=\"je_studio\"",
                "-c", "model_providers.je_studio.name=\"JE Studio\"",
                "-c", "model_providers.je_studio.base_url=" + jsonString(profile.apiBase),
                "-c", "model_providers.je_studio.env_key=\"JE_STUDIO_API_KEY\"",
                "-c", "model_providers.je_studio.wire_api=\"responses\"",
                "-c", "model_providers.je_studio.supports_websockets=false"
            ]
            if let context = profile.contextWindow {
                arguments.append(contentsOf: ["-c", "model_context_window=\(context)"])
            }
            if let binding = profile.codexCatalog {
                do {
                    try CodexCatalogLoader.checkVersion(
                        executable: executable,
                        requiredVersion: binding.requiredVersion,
                        environment: environment,
                        secret: profile.secret
                    )
                    let raw = try CodexCatalogLoader.loadSnapshot(
                        binding: binding,
                        model: profile.model,
                        contextWindow: profile.contextWindow,
                        secret: profile.secret
                    )
                    let temporary = FileManager.default.temporaryDirectory
                        .appendingPathComponent(
                            "je-codex-" + UUID().uuidString.lowercased(),
                            isDirectory: true
                        )
                    try FileManager.default.createDirectory(
                        at: temporary,
                        withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700]
                    )
                    temporaryDirectories.append(temporary)
                    let snapshot = temporary.appendingPathComponent("catalog.json")
                    guard !snapshot.path.contains(profile.secret),
                          FileManager.default.createFile(
                            atPath: snapshot.path,
                            contents: raw,
                            attributes: [.posixPermissions: 0o600]
                          ) else {
                        throw HarnessLaunchError.preparationFailed
                    }
                    arguments.append(contentsOf: [
                        "-c", "model_catalog_json=" + jsonString(snapshot.path)
                    ])
                } catch let error as CodexCatalogError {
                    switch error {
                    case .versionMismatch:
                        throw HarnessLaunchError.catalogVersionMismatch
                    case .versionUnavailable:
                        throw HarnessLaunchError.catalogInvalid(error.message)
                    case .invalid(let message):
                        throw HarnessLaunchError.catalogInvalid(message)
                    }
                }
            }
            switch candidate.launchMode {
            case .headless:
                arguments.append(contentsOf: ["exec", "--json", prompt])
            case .interactive:
                arguments.append(prompt)
            case .singleStep:
                throw HarnessLaunchError.unsupportedHarness
            }
            var childEnvironment = environment
            childEnvironment.removeValue(forKey: "JE_GATEWAY_API_KEY")
            childEnvironment["JE_STUDIO_API_KEY"] = profile.secret
            let spec = HarnessLaunchSpec(
                executableURL: executable,
                arguments: arguments,
                environment: childEnvironment,
                currentDirectoryURL: currentDirectoryURL
            )
            try validateNoSecretInArguments(spec, secret: profile.secret)
            return PreparedHarnessLaunch(spec: spec, temporaryDirectories: temporaryDirectories)
        } catch {
            for directory in temporaryDirectories {
                try? FileManager.default.removeItem(at: directory)
            }
            throw error
        }
    }

    private func prepareClaude(
        candidate: RouteCandidate,
        profile: ResolvedConnectionProfile,
        prompt: String,
        environment: [String: String],
        executableOverride: String?,
        currentDirectoryURL: URL?
    ) throws -> PreparedHarnessLaunch {
        let executable = try resolveExecutable(
            override: executableOverride,
            defaultName: "claude",
            environment: environment
        )
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("je-claude-" + UUID().uuidString.lowercased(), isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: temporary,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let settingsURL = temporary.appendingPathComponent("settings.json")
            let settings = ClaudeSettings(env: [
                "API_TIMEOUT_MS": "3000000",
                "ANTHROPIC_BASE_URL": profile.apiBase,
                "ANTHROPIC_CUSTOM_MODEL_OPTION": profile.model,
                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
            ], model: profile.model)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard FileManager.default.createFile(
                atPath: settingsURL.path,
                contents: try encoder.encode(settings),
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw HarnessLaunchError.preparationFailed
            }

            var authEnvironment = environment
            authEnvironment.removeValue(forKey: "ANTHROPIC_API_KEY")
            authEnvironment["CLAUDE_CODE_OAUTH_TOKEN"] = profile.secret
            try verifyClaudeAuthentication(
                executable: executable,
                settingsURL: settingsURL,
                environment: authEnvironment
            )

            var arguments = ["--settings", settingsURL.path, "--model", profile.model]
            switch candidate.launchMode {
            case .headless:
                arguments.append(contentsOf: ["--print", prompt])
            case .interactive:
                arguments.append(prompt)
            case .singleStep:
                throw HarnessLaunchError.unsupportedHarness
            }
            let spec = HarnessLaunchSpec(
                executableURL: executable,
                arguments: arguments,
                environment: authEnvironment,
                currentDirectoryURL: currentDirectoryURL
            )
            try validateNoSecretInArguments(spec, secret: profile.secret)
            return PreparedHarnessLaunch(spec: spec, temporaryDirectories: [temporary])
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if let error = error as? HarnessLaunchError {
                throw error
            }
            throw HarnessLaunchError.preparationFailed
        }
    }

    private func verifyClaudeAuthentication(
        executable: URL,
        settingsURL: URL,
        environment: [String: String]
    ) throws {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = executable
        process.arguments = ["--settings", settingsURL.path, "auth", "status", "--json"]
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            let data = try stdout.fileHandleForReading.read(upToCount: 64 * 1024 + 1) ?? Data()
            process.waitUntilExit()
            guard process.terminationStatus == 0, data.count <= 64 * 1024,
                  let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  value["loggedIn"] as? Bool == true,
                  value["authMethod"] as? String == "oauth_token",
                  value["apiProvider"] as? String == "firstParty" else {
                throw HarnessLaunchError.authenticationFailed
            }
        } catch let error as HarnessLaunchError {
            throw error
        } catch {
            if process.isRunning {
                process.terminate()
            }
            throw HarnessLaunchError.authenticationFailed
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
            throw HarnessLaunchError.executableUnavailable
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

    private func validateNoSecretInArguments(_ spec: HarnessLaunchSpec, secret: String) throws {
        guard !spec.arguments.contains(where: { $0.contains(secret) }),
              !spec.executableURL.path.contains(secret) else {
            throw HarnessLaunchError.secretInArguments
        }
    }

    private func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let encoded = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return encoded
    }

    private struct ClaudeSettings: Encodable {
        let env: [String: String]
        let model: String
    }
}
