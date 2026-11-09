import Foundation

public enum ConnectHarness: String, Equatable, Sendable {
    case codex
    case claudeCode = "claude"

    public var defaultExecutableName: String { rawValue }

    public var installMessage: String {
        switch self {
        case .codex:
            return "Install Codex or provide the path to its executable."
        case .claudeCode:
            return "Install Claude Code or provide the path to its executable."
        }
    }
}

public enum ConnectLaunchError: Error, Equatable, Sendable {
    case executableUnavailable(ConnectHarness)
    case secretInArguments
    case secretInExecutablePath
    case credentialsInPublicMetadata
    case memoryRequiresQualifiedCodex
    case versionTimedOut
    case versionUnrecognized
    case versionMismatch
    case catalogInvalid(String)
    case authenticationUnverified
    case authenticationUnconfirmed
    case authenticationMismatch
    case preparationFailed

    public var message: String {
        switch self {
        case .executableUnavailable(let harness):
            return harness.installMessage
        case .secretInArguments:
            return "Do not place the gateway credential in command-line arguments."
        case .secretInExecutablePath:
            return "Do not place the gateway credential in the executable path."
        case .credentialsInPublicMetadata:
            return "Keep credentials out of public connection metadata and command-line arguments."
        case .memoryRequiresQualifiedCodex:
            return "Memory attachment requires the qualified Codex version and a matching catalog binding."
        case .versionTimedOut:
            return "The Codex version check timed out; no session was started."
        case .versionUnrecognized:
            return "Codex did not return a recognized version; no session was started."
        case .versionMismatch:
            return "The installed Codex version does not match the saved catalog binding."
        case .catalogInvalid(let message):
            return message
        case .authenticationUnverified:
            return "Claude Code authentication could not be verified; no session was started."
        case .authenticationUnconfirmed:
            return "Claude Code could not confirm the selected gateway credentials; no session was started."
        case .authenticationMismatch:
            return "Claude Code selected another sign-in or provider. Check its auth status before connecting."
        case .preparationFailed:
            return "The harness launch could not be prepared."
        }
    }
}

public struct ConnectLaunchPreparer: Sendable {
    // The oracle attaches memory to Codex only on this exact build, with a
    // catalog binding that names the same version when one is saved.
    public static let qualifiedCodexMemoryVersion = "0.166.0-alpha.5.1"

    public init() {}

    public func prepare(
        harness: ConnectHarness,
        profile: ResolvedConnectionProfile,
        memory: ResolvedMemoryProfile?,
        trailingArguments: [String],
        environment: [String: String],
        executableOverride: String?,
        currentDirectoryURL: URL? = nil
    ) throws -> PreparedHarnessLaunch {
        if let memory, profile.model.contains(memory.secret) {
            throw ConnectLaunchError.credentialsInPublicMetadata
        }
        if trailingArguments.contains(where: { $0.contains(profile.secret) }) {
            throw ConnectLaunchError.secretInArguments
        }
        if let memory, trailingArguments.contains(where: { $0.contains(memory.secret) }) {
            throw ConnectLaunchError.credentialsInPublicMetadata
        }
        let executable = try resolveExecutable(
            harness: harness,
            override: executableOverride,
            environment: environment
        )
        if executable.path.contains(profile.secret) {
            throw ConnectLaunchError.secretInExecutablePath
        }
        if let memory, executable.path.contains(memory.secret) {
            throw ConnectLaunchError.credentialsInPublicMetadata
        }
        switch harness {
        case .codex:
            return try prepareCodex(
                executable: executable,
                profile: profile,
                memory: memory,
                trailingArguments: trailingArguments,
                environment: environment,
                currentDirectoryURL: currentDirectoryURL
            )
        case .claudeCode:
            return try prepareClaude(
                executable: executable,
                profile: profile,
                memory: memory,
                trailingArguments: trailingArguments,
                environment: environment,
                currentDirectoryURL: currentDirectoryURL
            )
        }
    }

    private func prepareCodex(
        executable: URL,
        profile: ResolvedConnectionProfile,
        memory: ResolvedMemoryProfile?,
        trailingArguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL?
    ) throws -> PreparedHarnessLaunch {
        var temporaryDirectories: [URL] = []
        do {
            if memory != nil, let binding = profile.codexCatalog,
               binding.requiredVersion != Self.qualifiedCodexMemoryVersion {
                throw ConnectLaunchError.memoryRequiresQualifiedCodex
            }
            let requiredVersion: String?
            if let binding = profile.codexCatalog {
                requiredVersion = binding.requiredVersion
            } else if memory != nil {
                requiredVersion = Self.qualifiedCodexMemoryVersion
            } else {
                requiredVersion = nil
            }
            if let requiredVersion {
                var secrets = [profile.secret]
                if let memory { secrets.append(memory.secret) }
                try checkCodexVersion(
                    executable: executable,
                    requiredVersion: requiredVersion,
                    environment: environment,
                    secrets: secrets
                )
            }
            var arguments = [
                "-c", "model=" + jsonString(profile.model),
                "-c", "model_provider=\"je_studio\"",
                "-c", "model_providers.je_studio.name=\"J&E Studio\"",
                "-c", "model_providers.je_studio.base_url=" + jsonString(profile.apiBase),
                "-c", "model_providers.je_studio.env_key=\"JE_STUDIO_API_KEY\"",
                "-c", "model_providers.je_studio.wire_api=\"responses\"",
                "-c", "model_providers.je_studio.requires_openai_auth=false"
            ]
            if let context = profile.contextWindow {
                arguments.append(contentsOf: ["-c", "model_context_window=\(context)"])
            }
            if let binding = profile.codexCatalog {
                let raw: Data
                do {
                    raw = try CodexCatalogLoader.loadSnapshot(
                        binding: binding,
                        model: profile.model,
                        contextWindow: profile.contextWindow,
                        secret: profile.secret
                    )
                } catch let error as CodexCatalogError {
                    throw ConnectLaunchError.catalogInvalid(error.message)
                }
                let temporary = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "je-studio-codex-" + UUID().uuidString.lowercased(),
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
                    throw ConnectLaunchError.preparationFailed
                }
                arguments.append(contentsOf: [
                    "-c", "model_catalog_json=" + jsonString(snapshot.path)
                ])
            }
            if let memory {
                let server = memory.serverName
                arguments.append(contentsOf: [
                    "-c", "mcp_servers.\(server).url=" + jsonString(memory.endpoint),
                    "-c", "mcp_servers.\(server).bearer_token_env_var=\"JE_MEMORY_TOKEN\"",
                    "-c", "mcp_servers.\(server).required=true",
                    "-c", "mcp_servers.\(server).startup_readiness=\"connection\""
                ])
            }
            arguments.append(contentsOf: trailingArguments)
            var childEnvironment = environment
            childEnvironment.removeValue(forKey: "JE_GATEWAY_API_KEY")
            childEnvironment["JE_STUDIO_API_KEY"] = profile.secret
            if let memory {
                childEnvironment["JE_MEMORY_TOKEN"] = memory.secret
            }
            let spec = HarnessLaunchSpec(
                executableURL: executable,
                arguments: arguments,
                environment: childEnvironment,
                currentDirectoryURL: currentDirectoryURL
            )
            try validateNoCredentials(in: spec, profile: profile, memory: memory)
            return PreparedHarnessLaunch(spec: spec, temporaryDirectories: temporaryDirectories)
        } catch {
            for directory in temporaryDirectories {
                try? FileManager.default.removeItem(at: directory)
            }
            throw error
        }
    }

    private func prepareClaude(
        executable: URL,
        profile: ResolvedConnectionProfile,
        memory: ResolvedMemoryProfile?,
        trailingArguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL?
    ) throws -> PreparedHarnessLaunch {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "je-studio-claude-" + UUID().uuidString.lowercased(),
                isDirectory: true
            )
        do {
            try FileManager.default.createDirectory(
                at: temporary,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let pairs = claudeEnvironmentPairs(profile: profile)
            let settingsURL = temporary.appendingPathComponent("settings.json")
            let settings = "{\"env\": " + orderedJSONObject(pairs) + "}"
            guard FileManager.default.createFile(
                atPath: settingsURL.path,
                contents: Data((settings + "\n").utf8),
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw ConnectLaunchError.preparationFailed
            }
            var arguments = ["--settings", settingsURL.path]
            if let memory {
                let mcpURL = temporary.appendingPathComponent("mcp.json")
                guard FileManager.default.createFile(
                    atPath: mcpURL.path,
                    contents: Data((mcpConfiguration(memory: memory) + "\n").utf8),
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw ConnectLaunchError.preparationFailed
                }
                arguments.append(contentsOf: ["--mcp-config", mcpURL.path])
            }
            var childEnvironment = environment
            for (key, value) in pairs {
                childEnvironment[key] = value
            }
            try verifyClaudeAuthentication(
                executable: executable,
                settingsURL: settingsURL,
                environment: childEnvironment
            )
            arguments.append(contentsOf: ["--model", profile.model])
            arguments.append(contentsOf: trailingArguments)
            let spec = HarnessLaunchSpec(
                executableURL: executable,
                arguments: arguments,
                environment: childEnvironment,
                currentDirectoryURL: currentDirectoryURL
            )
            try validateNoCredentials(in: spec, profile: profile, memory: memory)
            return PreparedHarnessLaunch(spec: spec, temporaryDirectories: [temporary])
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if let error = error as? ConnectLaunchError {
                throw error
            }
            throw ConnectLaunchError.preparationFailed
        }
    }

    private func claudeEnvironmentPairs(
        profile: ResolvedConnectionProfile
    ) -> [(String, String)] {
        var pairs: [(String, String)] = [
            ("ANTHROPIC_BASE_URL", profile.endpoint),
            ("ANTHROPIC_AUTH_TOKEN", profile.secret),
            ("ANTHROPIC_API_KEY", ""),
            ("CLAUDE_CODE_OAUTH_TOKEN", ""),
            ("CLAUDE_CODE_USE_BEDROCK", ""),
            ("CLAUDE_CODE_USE_VERTEX", ""),
            ("CLAUDE_CODE_USE_FOUNDRY", ""),
            ("CLAUDE_CODE_USE_ANTHROPIC_AWS", ""),
            ("ANTHROPIC_MODEL", profile.model),
            ("ANTHROPIC_DEFAULT_MODEL", profile.model),
            ("ANTHROPIC_CUSTOM_MODEL_OPTION", profile.model),
            ("CLAUDE_CODE_SUBAGENT_MODEL", profile.model),
            ("ANTHROPIC_DEFAULT_FABLE_MODEL", profile.model),
            ("ANTHROPIC_DEFAULT_OPUS_MODEL", profile.model),
            ("ANTHROPIC_DEFAULT_SONNET_MODEL", profile.model),
            ("ANTHROPIC_DEFAULT_HAIKU_MODEL", profile.model)
        ]
        if let context = profile.contextWindow {
            pairs.append(("CLAUDE_CODE_MAX_CONTEXT_TOKENS", String(context)))
        }
        return pairs
    }

    private func mcpConfiguration(memory: ResolvedMemoryProfile) -> String {
        let server = "{\"type\": \"http\", \"url\": " + jsonString(memory.endpoint)
            + ", \"headers\": {\"Authorization\": "
            + jsonString("Bearer " + memory.secret) + "}}"
        return "{\"mcpServers\": {" + jsonString(memory.serverName) + ": " + server + "}}"
    }

    private func checkCodexVersion(
        executable: URL,
        requiredVersion: String,
        environment: [String: String],
        secrets: [String]
    ) throws {
        do {
            try CodexCatalogLoader.checkVersion(
                executable: executable,
                requiredVersion: requiredVersion,
                environment: environment,
                secrets: secrets
            )
        } catch let error as CodexCatalogError {
            switch error {
            case .versionMismatch:
                throw ConnectLaunchError.versionMismatch
            case .versionTimedOut:
                throw ConnectLaunchError.versionTimedOut
            case .versionUnavailable:
                throw ConnectLaunchError.versionUnrecognized
            case .invalid(let message):
                throw ConnectLaunchError.catalogInvalid(message)
            }
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
        } catch {
            throw ConnectLaunchError.authenticationUnconfirmed
        }
        let data: Data
        do {
            data = try stdout.fileHandleForReading.read(upToCount: 64 * 1024 + 1) ?? Data()
        } catch {
            if process.isRunning { process.terminate() }
            throw ConnectLaunchError.authenticationUnverified
        }
        if data.count > 64 * 1024, process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ConnectLaunchError.authenticationUnconfirmed
        }
        guard data.count <= 64 * 1024,
              let value = try? JSONSerialization.jsonObject(with: data),
              let report = value as? [String: Any] else {
            throw ConnectLaunchError.authenticationUnverified
        }
        guard report["loggedIn"] as? Bool == true,
              report["authMethod"] as? String == "oauth_token",
              report["apiProvider"] as? String == "firstParty" else {
            throw ConnectLaunchError.authenticationMismatch
        }
    }

    private func resolveExecutable(
        harness: ConnectHarness,
        override: String?,
        environment: [String: String]
    ) throws -> URL {
        let candidate: URL?
        if let override {
            if override.isEmpty {
                candidate = nil
            } else if override.contains("/") {
                let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
                candidate = Self.isLaunchableFile(url.path) ? url : nil
            } else {
                candidate = JECommandLine.searchExecutableOnPath(
                    named: override, environment: environment)
            }
        } else {
            candidate = JECommandLine.searchExecutableOnPath(
                named: harness.defaultExecutableName, environment: environment)
                ?? homeFallback(harness: harness, environment: environment)
        }
        guard let candidate else {
            throw ConnectLaunchError.executableUnavailable(harness)
        }
        return candidate
    }

    private func homeFallback(
        harness: ConnectHarness,
        environment: [String: String]
    ) -> URL? {
        // The oracle finds the native Claude Code install under ~/.local/bin
        // when PATH does not carry it. Codex has no such fallback.
        guard harness == .claudeCode else { return nil }
        let home: URL
        if let value = environment["HOME"], !value.isEmpty {
            home = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
        }
        let candidate = home.appendingPathComponent(".local/bin/claude")
        return Self.isLaunchableFile(candidate.path) ? candidate : nil
    }

    private static func isLaunchableFile(_ path: String) -> Bool {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    private func validateNoCredentials(
        in spec: HarnessLaunchSpec,
        profile: ResolvedConnectionProfile,
        memory: ResolvedMemoryProfile?
    ) throws {
        if spec.arguments.contains(where: { $0.contains(profile.secret) }) {
            throw ConnectLaunchError.secretInArguments
        }
        if let memory, spec.arguments.contains(where: { $0.contains(memory.secret) }) {
            throw ConnectLaunchError.credentialsInPublicMetadata
        }
    }

    private func orderedJSONObject(_ pairs: [(String, String)]) -> String {
        "{" + pairs
            .map { jsonString($0.0) + ": " + jsonString($0.1) }
            .joined(separator: ", ") + "}"
    }

    // Matches the oracle's JSON string encoding, which leaves slashes bare
    // (JSONSerialization would emit "\/" inside Codex -c values).
    private func jsonString(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22:
                result += "\\\""
            case 0x5C:
                result += "\\\\"
            case 0x08:
                result += "\\b"
            case 0x09:
                result += "\\t"
            case 0x0A:
                result += "\\n"
            case 0x0C:
                result += "\\f"
            case 0x0D:
                result += "\\r"
            case 0x20...0x7E:
                result.unicodeScalars.append(scalar)
            case 0x00...0xFFFF:
                result += String(format: "\\u%04x", scalar.value)
            default:
                let shifted = scalar.value - 0x10000
                result += String(format: "\\u%04x\\u%04x", 0xD800 + shifted / 0x400, 0xDC00 + shifted % 0x400)
            }
        }
        result += "\""
        return result
    }
}
