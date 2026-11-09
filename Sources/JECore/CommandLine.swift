import Foundation

public typealias CLIOutputSink = @Sendable (String) -> Void

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
    private static let legacyCommands: Set<String> = []

    public static func run(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        recordedDay: String? = nil,
        runID: String? = nil,
        secretStore: SecretStoring? = nil,
        harnessRunner: HarnessRunning? = nil,
        stdoutSink: CLIOutputSink? = nil,
        musePhysicalMemoryBytes: UInt64? = nil,
        ollamaTransport: OllamaHTTPTransport? = nil,
        ollamaRelayUpstream: OllamaRelayUpstream? = nil,
        gatewayTransport: BoundedHTTPTransport? = nil,
        gatewayProbeTransport: GatewayProbeTransport? = nil,
        builtInTransport: BuiltInHTTPTransport? = nil,
        memoryTransport: MemoryHTTPTransport? = nil,
        currentExecutablePath: String? = nil,
        setupRunner: SetupCommandRunning? = nil,
        setupConfirmer: SetupConfirming? = nil
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
        case "setup":
            guard let parsed = SetupArguments(arguments: Array(remaining.dropFirst())) else {
                return invalid()
            }
            return SetupCommand.run(
                configuration: parsed.configuration,
                environment: environment,
                runner: setupRunner ?? ProcessSetupCommandRunner(),
                confirmer: setupConfirmer ?? TerminalSetupConfirmer(),
                stdoutSink: stdoutSink
            )
        case "status":
            return status(arguments: remaining)
        case "support-matrix":
            return supportMatrix(arguments: remaining)
        case "contracts":
            return contracts(arguments: remaining)
        case "doctor":
            return doctor(
                arguments: remaining,
                explicitStateDirectory: explicitStateDirectory,
                environment: environment,
                secretStore: secretStore,
                gatewayTransport: gatewayTransport,
                gatewayProbeTransport: gatewayProbeTransport
            )
        case "assignments":
            return AssignmentCommands.run(
                arguments: remaining,
                stateDirectory: stateDirectory(
                    explicit: explicitStateDirectory,
                    environment: environment
                ),
                environment: environment,
                secretStore: secretStore,
                harnessRunner: harnessRunner,
                recordedDay: recordedDay,
                musePhysicalMemoryBytes: musePhysicalMemoryBytes,
                builtInTransport: builtInTransport
            )
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
                runID: runID,
                secretStore: secretStore,
                harnessRunner: harnessRunner,
                stdoutSink: stdoutSink,
                musePhysicalMemoryBytes: musePhysicalMemoryBytes,
                builtInTransport: builtInTransport,
                memoryTransport: memoryTransport
            )
        case "profile":
            return ProfileCommands.run(
                arguments: remaining,
                stateDirectory: stateDirectory(
                    explicit: explicitStateDirectory,
                    environment: environment
                ),
                environment: environment,
                secretStore: secretStore
            )
        case "memory":
            return ProfileCommands.runMemory(
                arguments: remaining,
                stateDirectory: stateDirectory(
                    explicit: explicitStateDirectory,
                    environment: environment
                ),
                environment: environment,
                secretStore: secretStore,
                memoryTransport: memoryTransport
            )
        case "ollama":
            return ollama(
                arguments: remaining,
                explicitStateDirectory: explicitStateDirectory,
                environment: environment,
                secretStore: secretStore,
                harnessRunner: harnessRunner,
                ollamaTransport: ollamaTransport,
                ollamaRelayUpstream: ollamaRelayUpstream
            )
        case "run":
            return genericRun(
                arguments: remaining,
                stateDirectory: stateDirectory(
                    explicit: explicitStateDirectory,
                    environment: environment
                ),
                environment: environment,
                secretStore: secretStore,
                harnessRunner: harnessRunner
            )
        case "connect":
            return connect(
                arguments: remaining,
                stateDirectory: stateDirectory(
                    explicit: explicitStateDirectory,
                    environment: environment
                ),
                environment: environment,
                secretStore: secretStore,
                harnessRunner: harnessRunner
            )
        case "export":
            return desktopExport(
                arguments: remaining,
                stateDirectory: stateDirectory(
                    explicit: explicitStateDirectory,
                    environment: environment
                ),
                environment: environment,
                secretStore: secretStore,
                currentExecutablePath: currentExecutablePath
            )
        case "credential":
            return credential(
                arguments: remaining,
                stateDirectory: stateDirectory(
                    explicit: explicitStateDirectory,
                    environment: environment
                ),
                environment: environment,
                secretStore: secretStore
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

    private static func doctor(
        arguments: [String],
        explicitStateDirectory: String?,
        environment: [String: String],
        secretStore: SecretStoring?,
        gatewayTransport: BoundedHTTPTransport?,
        gatewayProbeTransport: GatewayProbeTransport?
    ) -> CLIResult {
        if arguments == ["doctor"] || arguments == ["doctor", "--json"] {
            return doctorOverview(
                json: arguments.count == 2,
                stateDirectory: stateDirectory(
                    explicit: explicitStateDirectory,
                    environment: environment
                ),
                environment: environment
            )
        }
        guard arguments.count >= 2 else { return invalid() }
        guard arguments[1] == "muse" else {
            return gatewayDoctor(
                arguments: arguments,
                stateDirectory: stateDirectory(
                    explicit: explicitStateDirectory,
                    environment: environment
                ),
                environment: environment,
                secretStore: secretStore,
                gatewayTransport: gatewayTransport,
                gatewayProbeTransport: gatewayProbeTransport
            )
        }
        var asJSON = false
        var executable: String?
        var index = 2
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--json" {
                asJSON = true
                index += 1
            } else if argument == "--executable" {
                guard index + 1 < arguments.count, !arguments[index + 1].isEmpty else {
                    return invalid()
                }
                executable = arguments[index + 1]
                index += 2
            } else if argument.hasPrefix("--executable=") {
                let value = String(argument.dropFirst("--executable=".count))
                guard !value.isEmpty else { return invalid() }
                executable = value
                index += 1
            } else {
                return invalid()
            }
        }
        do {
            let report = try MuseContractDiscovery().discover(
                executableOverride: executable,
                environment: environment
            )
            if asJSON {
                return json(report)
            }
            let minimum = report.minimumKnownLocalMemoryBytes.map(String.init) ?? "unknown"
            return CLIResult(code: 0, stdout: """
            Muse version: \(report.version)
            Interactive providers: \(report.interactiveProviders.joined(separator: ", "))
            Headless providers: \(report.headlessProviders.joined(separator: ", "))
            Authentication providers: \(report.authenticationProviders.joined(separator: ", "))
            Local contract: \(report.localContractStatus)
            Arbitrary local endpoint contract discovered: false
            Physical memory bytes: \(report.physicalMemoryBytes)
            Minimum known local memory bytes: \(minimum)
            Evidence: \(report.evidenceReference)

            """)
        } catch let error as StateStoreError {
            return CLIResult(code: 2, stderr: error.message + "\n")
        } catch {
            return CLIResult(code: 2, stderr: "Muse contract discovery failed.\n")
        }
    }

    private static func gatewayDoctor(
        arguments: [String],
        stateDirectory: URL,
        environment: [String: String],
        secretStore: SecretStoring?,
        gatewayTransport: BoundedHTTPTransport?,
        gatewayProbeTransport: GatewayProbeTransport?
    ) -> CLIResult {
        guard let parsed = GatewayDoctorArguments(arguments: Array(arguments.dropFirst())) else {
            return invalid()
        }
        if parsed.harness != nil && !parsed.probe {
            return CLIResult(code: 2, stderr: "Use --harness only with --probe.\n")
        }
        do {
            let profile = try ProfileStore(directory: stateDirectory).loadResolvedProfile(
                name: parsed.profile,
                secretStore: secretStore ?? ProcessSecretStore.default(environment: environment)
            )
            let report = try GatewayConnectionChecker.check(
                profile: profile,
                transport: gatewayTransport ?? URLSessionOllamaHTTPTransport()
            )
            guard report.passed else {
                return CLIResult(
                    code: 1,
                    stderr: "Connected, but the selected model is not available to this key.\n"
                )
            }
            let connected = "Connected. Model \(profile.model) is available.\n"
            guard parsed.probe else {
                return CLIResult(code: 0, stdout: connected)
            }
            let protocols: [GatewayProbeProtocol]
            switch parsed.harness {
            case "codex":
                protocols = [.responses]
            case "claude":
                protocols = [.messages]
            default:
                protocols = [.responses, .messages]
            }
            let probeReport = GatewayProbeRunner.run(
                profile: profile,
                protocols: protocols,
                transport: gatewayProbeTransport ?? URLSessionGatewayProbeTransport()
            )
            let reportURL: URL
            do {
                reportURL = try GatewayProbeReportStore(directory: stateDirectory)
                    .write(probeReport, profileName: parsed.profile)
            } catch {
                return CLIResult(
                    code: 2,
                    stdout: connected,
                    stderr: "The protocol probe report could not be written.\n"
                )
            }
            let counts = probeReport.counts
            return CLIResult(
                code: probeReport.passed ? 0 : 1,
                stdout: connected
                    + "Protocol checks: \(counts.passed) passed, \(counts.failed) failed, "
                    + "\(counts.notRun) not run. Private report: \(reportURL.path)\n"
            )
        } catch let error as StateStoreError {
            return CLIResult(code: 2, stderr: error.message + "\n")
        } catch let error as GatewayCheckError {
            return CLIResult(code: 2, stderr: error.message + "\n")
        } catch {
            return CLIResult(code: 2, stderr: "The gateway connection could not be checked.\n")
        }
    }

    private static func doctorOverview(
        json: Bool,
        stateDirectory: URL,
        environment: [String: String]
    ) -> CLIResult {
        do {
            let report = try DoctorOverviewBuilder.build(
                stateDirectory: stateDirectory,
                environment: environment)
            let code: Int32 = report.healthy ? 0 : 1
            if json {
                return CLIResult(code: code, stdout: try StableJSON.encode(report))
            }
            return CLIResult(code: code, stdout: DoctorOverviewRenderer.render(report))
        } catch let error as StateStoreError {
            return CLIResult(code: 2, stderr: error.message + "\n")
        } catch {
            return CLIResult(code: 2, stderr: "The local health overview could not be built.\n")
        }
    }

    private static func desktopExport(
        arguments: [String],
        stateDirectory: URL,
        environment: [String: String],
        secretStore: SecretStoring?,
        currentExecutablePath: String?
    ) -> CLIResult {
        guard arguments.first == "export" else { return invalid() }
        guard let parsed = ExportArguments(arguments: Array(arguments.dropFirst())) else {
            return invalid()
        }
        let store = ProfileStore(directory: stateDirectory)
        let profile: ResolvedConnectionProfile
        do {
            profile = try store.loadResolvedProfile(
                name: parsed.profile,
                secretStore: secretStore ?? ProcessSecretStore.default(environment: environment)
            )
        } catch let error as StateStoreError {
            return CLIResult(code: 2, stderr: error.message + "\n")
        } catch {
            return CLIResult(code: 2, stderr: "The saved connection could not be loaded.\n")
        }
        guard let helperPath = resolveExportHelper(
            override: parsed.helperExecutable,
            environment: environment,
            currentExecutablePath: currentExecutablePath
        ) else {
            return CLIResult(code: 2, stderr: ExportError.helperUnavailable.message + "\n")
        }
        var catalogSnapshot: Data?
        if let binding = profile.codexCatalog {
            do {
                catalogSnapshot = try CodexCatalogLoader.loadSnapshot(
                    binding: binding,
                    model: profile.model,
                    contextWindow: profile.contextWindow,
                    secret: profile.secret
                )
            } catch let error as CodexCatalogError {
                return CLIResult(code: 2, stderr: error.message + "\n")
            } catch {
                return CLIResult(code: 2, stderr: "The saved connection could not be loaded.\n")
            }
        }
        do {
            let bundle = try DesktopExportWriter().writeBundle(
                profile: profile,
                catalogSnapshot: catalogSnapshot,
                helperPath: helperPath,
                stateDirectory: stateDirectory
            )
            return CLIResult(
                code: 0,
                stdout: "Desktop setup files saved to \(bundle.path). "
                    + "Review README.md before applying them.\n"
            )
        } catch let error as ExportError {
            return CLIResult(code: 2, stderr: error.message + "\n")
        } catch {
            return CLIResult(code: 2, stderr: ExportError.stateAccessFailed.message + "\n")
        }
    }

    private static func resolveExportHelper(
        override: String?,
        environment: [String: String],
        currentExecutablePath: String?
    ) -> String? {
        if let override {
            guard override.hasPrefix("/"),
                  isLaunchableFile(override, fileManager: FileManager.default) else {
                return nil
            }
            return override
        }
        let candidate: URL?
        if let currentExecutablePath, !currentExecutablePath.isEmpty {
            candidate = URL(fileURLWithPath: currentExecutablePath)
        } else if let argument = ProcessInfo.processInfo.arguments.first, !argument.isEmpty {
            if argument.contains("/") {
                let expanded = (argument as NSString).expandingTildeInPath
                if expanded.hasPrefix("/") {
                    candidate = URL(fileURLWithPath: expanded)
                } else {
                    candidate = URL(
                        fileURLWithPath: FileManager.default.currentDirectoryPath)
                        .appendingPathComponent(expanded)
                }
            } else {
                candidate = searchExecutableOnPath(named: argument, environment: environment)
            }
        } else {
            candidate = nil
        }
        guard let candidate else { return nil }
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard isLaunchableFile(resolved.path, fileManager: FileManager.default) else {
            return nil
        }
        return resolved.path
    }

    private struct SetupArguments {
        let configuration: SetupConfiguration

        init?(arguments: [String]) {
            var client: SetupClient?
            var clientSeen = false
            var confirmed = false
            var dryRun = false
            var remove = false
            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                if argument == "--yes" {
                    guard !confirmed else { return nil }
                    confirmed = true
                    index += 1
                    continue
                }
                if argument == "--dry-run" {
                    guard !dryRun else { return nil }
                    dryRun = true
                    index += 1
                    continue
                }
                if argument == "--remove" {
                    guard !remove else { return nil }
                    remove = true
                    index += 1
                    continue
                }
                if argument == "--client" || argument.hasPrefix("--client=") {
                    guard !clientSeen else { return nil }
                    let value: String
                    if argument == "--client" {
                        guard index + 1 < arguments.count else { return nil }
                        value = arguments[index + 1]
                        index += 2
                    } else {
                        value = String(argument.dropFirst("--client=".count))
                        index += 1
                    }
                    guard let parsed = SetupClient(rawValue: value) else { return nil }
                    client = parsed
                    clientSeen = true
                    continue
                }
                return nil
            }
            configuration = SetupConfiguration(
                client: client, confirmed: confirmed, dryRun: dryRun, remove: remove)
        }
    }

    private struct ExportArguments {
        let profile: String
        let helperExecutable: String?

        init?(arguments: [String]) {
            var profile: String?
            var helperExecutable: String?
            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                if argument == "--profile" || argument.hasPrefix("--profile=") {
                    guard profile == nil,
                          let value = Self.value(argument: argument, flag: "--profile", arguments: arguments, index: &index)
                    else { return nil }
                    profile = value
                    continue
                }
                if argument == "--helper-executable" || argument.hasPrefix("--helper-executable=") {
                    guard helperExecutable == nil,
                          let value = Self.value(argument: argument, flag: "--helper-executable", arguments: arguments, index: &index)
                    else { return nil }
                    helperExecutable = value
                    continue
                }
                return nil
            }
            guard let profile else { return nil }
            self.profile = profile
            self.helperExecutable = helperExecutable
        }

        private static func value(
            argument: String,
            flag: String,
            arguments: [String],
            index: inout Int
        ) -> String? {
            if argument == flag {
                guard index + 1 < arguments.count else { return nil }
                let value = arguments[index + 1]
                index += 2
                return value
            }
            index += 1
            return String(argument.dropFirst(flag.count + 1))
        }
    }

    private static func credential(
        arguments: [String],
        stateDirectory: URL,
        environment: [String: String],
        secretStore: SecretStoring?
    ) -> CLIResult {
        guard arguments.first == "credential" else { return invalid() }
        let rest = Array(arguments.dropFirst())
        let profileName: String
        if rest.count == 2 && rest[0] == "--profile" {
            profileName = rest[1]
        } else if rest.count == 1 && rest[0].hasPrefix("--profile=") {
            profileName = String(rest[0].dropFirst("--profile=".count))
        } else {
            return invalid()
        }
        guard !profileName.isEmpty else { return invalid() }
        do {
            let profile = try ProfileStore(directory: stateDirectory).loadResolvedProfile(
                name: profileName,
                secretStore: secretStore ?? ProcessSecretStore.default(environment: environment)
            )
            return CLIResult(code: 0, stdout: profile.secret + "\n")
        } catch let error as StateStoreError {
            return CLIResult(code: 2, stderr: error.message + "\n")
        } catch {
            return CLIResult(code: 2, stderr: "The saved credential could not be supplied.\n")
        }
    }

    private static func genericRun(
        arguments: [String],
        stateDirectory: URL,
        environment: [String: String],
        secretStore: SecretStoring?,
        harnessRunner: HarnessRunning?
    ) -> CLIResult {
        guard arguments.first == "run" else { return invalid() }
        guard let parsed = RunArguments(arguments: Array(arguments.dropFirst())) else {
            return invalid()
        }
        let profile: ResolvedConnectionProfile
        do {
            profile = try ProfileStore(directory: stateDirectory).loadResolvedProfile(
                name: parsed.profile,
                secretStore: secretStore ?? ProcessSecretStore.default(environment: environment)
            )
        } catch let error as StateStoreError {
            return CLIResult(code: 2, stderr: error.message + "\n")
        } catch {
            return CLIResult(code: 2, stderr: "The saved connection could not be loaded.\n")
        }
        // The oracle applies a differing --model by validating a replacement
        // profile. Context window and catalog clearing have no observable
        // effect here because the child receives only the model name.
        var model = profile.model
        if let override = parsed.model, !override.isEmpty, override != profile.model {
            guard Self.isValidModelName(override) else {
                return CLIResult(
                    code: 2,
                    stderr: "A nonempty model name without control characters is required.\n")
            }
            guard !override.contains(profile.secret) else {
                return CLIResult(
                    code: 2,
                    stderr: "Keep gateway credentials separate from the endpoint and model name.\n")
            }
            model = override
        }
        guard !parsed.command.isEmpty else {
            return CLIResult(code: 2, stderr: "Specify a command after --.\n")
        }
        let startFailure = "The operation failed; no credential or response contents were displayed.\n"
        guard !parsed.command.contains(where: { $0.contains("\0") }) else {
            return CLIResult(code: 2, stderr: startFailure)
        }
        guard !parsed.command.contains(where: { $0.contains(profile.secret) }) else {
            return CLIResult(
                code: 2,
                stderr: "Do not place the gateway credential in command-line arguments.\n")
        }
        guard let executableURL = resolveGenericExecutable(
            parsed.command[0], environment: environment) else {
            return CLIResult(code: 2, stderr: startFailure)
        }
        guard !executableURL.path.contains(profile.secret) else {
            return CLIResult(
                code: 2,
                stderr: "Do not place the gateway credential in the executable path.\n")
        }
        var childEnvironment = environment
        childEnvironment["OPENAI_BASE_URL"] = profile.apiBase
        childEnvironment["OPENAI_API_KEY"] = profile.secret
        childEnvironment["OPENAI_MODEL"] = model
        do {
            let code = try (harnessRunner ?? ProcessHarnessRunner()).run(HarnessLaunchSpec(
                executableURL: executableURL,
                arguments: Array(parsed.command.dropFirst()),
                environment: childEnvironment))
            return CLIResult(code: code)
        } catch {
            return CLIResult(code: 2, stderr: startFailure)
        }
    }

    private static func connect(
        arguments: [String],
        stateDirectory: URL,
        environment: [String: String],
        secretStore: SecretStoring?,
        harnessRunner: HarnessRunning?
    ) -> CLIResult {
        guard arguments.first == "connect" else { return invalid() }
        guard let parsed = ConnectArguments(arguments: Array(arguments.dropFirst())) else {
            return invalid()
        }
        let store = ProfileStore(directory: stateDirectory)
        let loaded: ResolvedConnectionProfile
        do {
            loaded = try store.loadResolvedProfile(
                name: parsed.profile,
                secretStore: secretStore ?? ProcessSecretStore.default(environment: environment)
            )
        } catch let error as StateStoreError {
            return CLIResult(code: 2, stderr: error.message + "\n")
        } catch {
            return CLIResult(code: 2, stderr: "The saved connection could not be loaded.\n")
        }
        // The oracle applies a differing --model by validating a replacement
        // profile, which drops the saved context window and catalog binding
        // for this session only.
        var profile = loaded
        if let override = parsed.model, !override.isEmpty, override != loaded.model {
            guard Self.isValidModelName(override) else {
                return CLIResult(
                    code: 2,
                    stderr: "A nonempty model name without control characters is required.\n")
            }
            guard !override.contains(loaded.secret) else {
                return CLIResult(
                    code: 2,
                    stderr: "Keep gateway credentials separate from the endpoint and model name.\n")
            }
            profile = ResolvedConnectionProfile(
                name: loaded.name,
                endpoint: loaded.endpoint,
                secret: loaded.secret,
                model: override,
                contextWindow: nil,
                codexCatalog: nil
            )
        }
        var memory: ResolvedMemoryProfile?
        if let memoryName = parsed.memoryProfile {
            do {
                memory = try store.loadResolvedMemoryProfile(
                    name: memoryName,
                    secretStore: secretStore ?? ProcessSecretStore.default(environment: environment)
                )
            } catch let error as StateStoreError {
                return CLIResult(code: 2, stderr: error.message + "\n")
            } catch {
                return CLIResult(code: 2, stderr: "The saved connection could not be loaded.\n")
            }
        }
        guard !parsed.trailing.contains(where: { $0.contains("\0") }) else {
            return CLIResult(code: 2, stderr: "The harness process could not be started.\n")
        }
        let prepared: PreparedHarnessLaunch
        do {
            prepared = try ConnectLaunchPreparer().prepare(
                harness: parsed.harness,
                profile: profile,
                memory: memory,
                trailingArguments: parsed.trailing,
                environment: environment,
                executableOverride: parsed.executable
            )
        } catch let error as ConnectLaunchError {
            return CLIResult(code: 2, stderr: error.message + "\n")
        } catch {
            return CLIResult(code: 2, stderr: "The harness launch could not be prepared.\n")
        }
        defer { prepared.cleanup() }
        do {
            let code = try (harnessRunner ?? ProcessHarnessRunner()).run(prepared.spec)
            return CLIResult(code: code)
        } catch {
            return CLIResult(code: 2, stderr: "The harness process could not be started.\n")
        }
    }

    private struct ConnectArguments {
        let harness: ConnectHarness
        let profile: String
        let model: String?
        let executable: String?
        let memoryProfile: String?
        let trailing: [String]

        init?(arguments: [String]) {
            // Like the oracle, split at the first -- before parsing flags;
            // everything after it reaches the harness verbatim.
            let head: [String]
            var trailing: [String] = []
            if let split = arguments.firstIndex(of: "--") {
                head = Array(arguments[..<split])
                trailing = Array(arguments[(split + 1)...])
            } else {
                head = arguments
            }
            var harness: ConnectHarness?
            var profile: String?
            var model: String?
            var executable: String?
            var memoryProfile: String?
            var index = 0
            while index < head.count {
                let argument = head[index]
                if argument == "--profile" || argument.hasPrefix("--profile=") {
                    guard profile == nil,
                          let value = Self.value(argument: argument, flag: "--profile", arguments: head, index: &index)
                    else { return nil }
                    profile = value
                    continue
                }
                if argument == "--model" || argument.hasPrefix("--model=") {
                    guard model == nil,
                          let value = Self.value(argument: argument, flag: "--model", arguments: head, index: &index)
                    else { return nil }
                    model = value
                    continue
                }
                if argument == "--executable" || argument.hasPrefix("--executable=") {
                    guard executable == nil,
                          let value = Self.value(argument: argument, flag: "--executable", arguments: head, index: &index)
                    else { return nil }
                    executable = value
                    continue
                }
                if argument == "--memory-profile" || argument.hasPrefix("--memory-profile=") {
                    guard memoryProfile == nil,
                          let value = Self.value(argument: argument, flag: "--memory-profile", arguments: head, index: &index)
                    else { return nil }
                    memoryProfile = value
                    continue
                }
                if argument.hasPrefix("-") {
                    return nil
                }
                guard harness == nil, let parsed = ConnectHarness(rawValue: argument) else {
                    return nil
                }
                harness = parsed
                index += 1
            }
            guard let harness, let profile else { return nil }
            self.harness = harness
            self.profile = profile
            self.model = model
            self.executable = executable
            self.memoryProfile = memoryProfile
            self.trailing = trailing
        }

        private static func value(
            argument: String,
            flag: String,
            arguments: [String],
            index: inout Int
        ) -> String? {
            if argument == flag {
                guard index + 1 < arguments.count else { return nil }
                let value = arguments[index + 1]
                index += 2
                return value
            }
            index += 1
            return String(argument.dropFirst(flag.count + 1))
        }
    }

    private static func isValidModelName(_ model: String) -> Bool {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed == model
            && !model.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }

    static func resolveGenericExecutable(
        _ command: String, environment: [String: String]
    ) -> URL? {
        guard !command.isEmpty else { return nil }
        if command.contains("/") {
            let url = URL(fileURLWithPath: command)
            return isLaunchableFile(url.path, fileManager: FileManager.default) ? url : nil
        }
        var searchEnvironment = environment
        if searchEnvironment["PATH"] == nil {
            // Matches the oracle's subprocess search when PATH is absent.
            searchEnvironment["PATH"] = "/bin:/usr/bin"
        }
        return searchExecutableOnPath(named: command, environment: searchEnvironment)
    }

    private struct RunArguments {
        let profile: String
        let model: String?
        let command: [String]

        init?(arguments: [String]) {
            // The oracle splits the whole invocation at the first -- before
            // parsing flags, so a flag value can never consume the separator.
            let head: [String]
            var command: [String] = []
            if let split = arguments.firstIndex(of: "--") {
                head = Array(arguments[..<split])
                command = Array(arguments[(split + 1)...])
            } else {
                head = arguments
            }
            var profile: String?
            var model: String?
            var index = 0
            while index < head.count {
                let argument = head[index]
                if argument == "--profile" || argument.hasPrefix("--profile=") {
                    guard profile == nil,
                          let value = Self.value(argument: argument, flag: "--profile", arguments: head, index: &index),
                          !value.isEmpty else { return nil }
                    profile = value
                    continue
                }
                if argument == "--model" || argument.hasPrefix("--model=") {
                    guard model == nil,
                          let value = Self.value(argument: argument, flag: "--model", arguments: head, index: &index)
                    else { return nil }
                    model = value
                    continue
                }
                return nil
            }
            guard let profile else { return nil }
            self.profile = profile
            self.model = model
            self.command = command
        }

        private static func value(
            argument: String,
            flag: String,
            arguments: [String],
            index: inout Int
        ) -> String? {
            if argument == flag {
                guard index + 1 < arguments.count else { return nil }
                let value = arguments[index + 1]
                index += 2
                return value
            }
            index += 1
            return String(argument.dropFirst(flag.count + 1))
        }
    }

    private struct GatewayDoctorArguments {
        let profile: String
        let probe: Bool
        let harness: String?

        init?(arguments: [String]) {
            var profile: String?
            var probe = false
            var harness: String?
            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                if argument == "--probe" {
                    guard !probe else { return nil }
                    probe = true
                    index += 1
                    continue
                }
                if argument == "--profile" || argument.hasPrefix("--profile=") {
                    guard profile == nil,
                          let value = Self.value(argument: argument, flag: "--profile", arguments: arguments, index: &index),
                          !value.isEmpty else { return nil }
                    profile = value
                    continue
                }
                if argument == "--harness" || argument.hasPrefix("--harness=") {
                    guard harness == nil,
                          let value = Self.value(argument: argument, flag: "--harness", arguments: arguments, index: &index),
                          ["codex", "claude"].contains(value) else { return nil }
                    harness = value
                    continue
                }
                return nil
            }
            guard let profile else { return nil }
            self.profile = profile
            self.probe = probe
            self.harness = harness
        }

        private static func value(
            argument: String,
            flag: String,
            arguments: [String],
            index: inout Int
        ) -> String? {
            if argument == flag {
                guard index + 1 < arguments.count else { return nil }
                let value = arguments[index + 1]
                index += 2
                return value
            }
            index += 1
            return String(argument.dropFirst(flag.count + 1))
        }
    }

    private static func ollama(
        arguments: [String],
        explicitStateDirectory: String?,
        environment: [String: String],
        secretStore: SecretStoring?,
        harnessRunner: HarnessRunning?,
        ollamaTransport: OllamaHTTPTransport?,
        ollamaRelayUpstream: OllamaRelayUpstream?
    ) -> CLIResult {
        let directory = stateDirectory(
            explicit: explicitStateDirectory,
            environment: environment
        )
        if arguments.count >= 2, arguments[1] == "profile" {
            return ProfileCommands.runOllamaProfile(
                arguments: arguments,
                stateDirectory: directory,
                environment: environment,
                secretStore: secretStore
            )
        }
        guard arguments.first == "ollama" else { return invalid() }
        guard let parsed = OllamaTopLevelArguments(arguments: Array(arguments.dropFirst())) else {
            return invalid()
        }
        let isCheck = !parsed.hadSeparator && parsed.positionals == ["check"]
        if !isCheck {
            return ollamaLaunch(
                parsed: parsed,
                stateDirectory: directory,
                environment: environment,
                secretStore: secretStore,
                harnessRunner: harnessRunner,
                ollamaRelayUpstream: ollamaRelayUpstream
            )
        }
        if parsed.executable != nil {
            return CLIResult(
                code: 2,
                stderr: "The native connection check does not launch an executable.\n"
            )
        }
        guard let profileName = parsed.profile else {
            return CLIResult(
                code: 2,
                stderr: "Select a saved native Ollama connection with --profile.\n"
            )
        }
        do {
            let profile = try ProfileStore(directory: directory).loadResolvedOllamaProfile(
                name: profileName,
                secretStore: secretStore ?? ProcessSecretStore.default(environment: environment)
            )
            let report = try OllamaConnectionChecker.check(
                profile: profile,
                transport: ollamaTransport ?? URLSessionOllamaHTTPTransport()
            )
            if report.passed {
                return CLIResult(
                    code: 0,
                    stdout: "Connected. Native model \(profile.model) is available.\n"
                )
            }
            return CLIResult(
                code: 1,
                stderr: "Connected, but the default native model is not available to this key.\n"
            )
        } catch let error as StateStoreError {
            return CLIResult(code: 2, stderr: error.message + "\n")
        } catch let error as OllamaCheckError {
            return CLIResult(code: 2, stderr: error.message + "\n")
        } catch {
            return CLIResult(code: 2, stderr: "The native Ollama connection could not be checked.\n")
        }
    }

    private static func ollamaLaunch(
        parsed: OllamaTopLevelArguments,
        stateDirectory: URL,
        environment: [String: String],
        secretStore: SecretStoring?,
        harnessRunner: HarnessRunning?,
        ollamaRelayUpstream: OllamaRelayUpstream?
    ) -> CLIResult {
        guard parsed.hadSeparator || parsed.positionals.isEmpty else {
            return invalid()
        }
        guard let profileName = parsed.profile else {
            return CLIResult(
                code: 2,
                stderr: "Select a saved native Ollama connection with --profile.\n"
            )
        }
        let profile: ResolvedOllamaProfile
        do {
            profile = try ProfileStore(directory: stateDirectory).loadResolvedOllamaProfile(
                name: profileName,
                secretStore: secretStore ?? ProcessSecretStore.default(environment: environment)
            )
        } catch let error as StateStoreError {
            return CLIResult(code: 2, stderr: error.message + "\n")
        } catch {
            return CLIResult(code: 2, stderr: "The native Ollama connection could not be launched.\n")
        }
        guard let executableURL = resolveOllamaExecutable(
            override: parsed.executable, environment: environment) else {
            return CLIResult(
                code: 2,
                stderr: "Install the Ollama CLI or provide the path to its executable.\n"
            )
        }
        let relay = OllamaLoopbackRelay(
            upstreamBase: profile.endpoint,
            bearerToken: profile.secret,
            upstream: ollamaRelayUpstream ?? URLSessionOllamaRelayUpstream())
        let relayURL: URL
        do {
            relayURL = try relay.start()
        } catch {
            return CLIResult(code: 2, stderr: "The local Ollama relay could not start.\n")
        }
        defer { relay.stop() }
        var childEnvironment = environment
        childEnvironment["OLLAMA_HOST"] = relayURL.absoluteString
        let childArguments = parsed.positionals.isEmpty
            ? ["run", profile.model]
            : parsed.positionals
        do {
            let code = try (harnessRunner ?? ProcessHarnessRunner()).run(HarnessLaunchSpec(
                executableURL: executableURL,
                arguments: childArguments,
                environment: childEnvironment))
            return CLIResult(code: code)
        } catch let error as HarnessLaunchError {
            return CLIResult(code: 2, stderr: error.message + "\n")
        } catch {
            return CLIResult(code: 2, stderr: "The native Ollama CLI could not be launched.\n")
        }
    }

    static func resolveOllamaExecutable(
        override: String?, environment: [String: String]
    ) -> URL? {
        let fileManager = FileManager.default
        if let override, !override.isEmpty {
            if override.contains("/") {
                let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
                return isLaunchableFile(url.path, fileManager: fileManager) ? url : nil
            }
            return searchExecutableOnPath(named: override, environment: environment)
        }
        if let found = searchExecutableOnPath(named: "ollama", environment: environment) {
            return found
        }
        for path in ["/usr/local/bin/ollama", "/opt/homebrew/bin/ollama"]
        where isLaunchableFile(path, fileManager: fileManager) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func isLaunchableFile(
        _ path: String, fileManager: FileManager
    ) -> Bool {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        return fileManager.isExecutableFile(atPath: path)
    }

    static func searchExecutableOnPath(
        named name: String, environment: [String: String]
    ) -> URL? {
        for directory in (environment["PATH"] ?? "").split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent(name)
            if isLaunchableFile(candidate.path, fileManager: FileManager.default) {
                return candidate
            }
        }
        return nil
    }

    private struct OllamaTopLevelArguments {
        let profile: String?
        let executable: String?
        let positionals: [String]
        let hadSeparator: Bool

        init?(arguments: [String]) {
            var profile: String?
            var executable: String?
            var positionals: [String] = []
            var hadSeparator = false
            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                if argument == "--" {
                    hadSeparator = true
                    positionals.append(contentsOf: arguments.dropFirst(index + 1))
                    break
                }
                if argument == "--profile" || argument.hasPrefix("--profile=") {
                    guard profile == nil,
                          let value = Self.value(argument: argument, flag: "--profile", arguments: arguments, index: &index),
                          !value.isEmpty else { return nil }
                    profile = value
                    continue
                }
                if argument == "--executable" || argument.hasPrefix("--executable=") {
                    guard executable == nil,
                          let value = Self.value(argument: argument, flag: "--executable", arguments: arguments, index: &index),
                          !value.isEmpty else { return nil }
                    executable = value
                    continue
                }
                if argument.hasPrefix("-") {
                    return nil
                }
                positionals.append(argument)
                index += 1
            }
            self.profile = profile
            self.executable = executable
            self.positionals = positionals
            self.hadSeparator = hadSeparator
        }

        private static func value(
            argument: String,
            flag: String,
            arguments: [String],
            index: inout Int
        ) -> String? {
            if argument == flag {
                guard index + 1 < arguments.count else { return nil }
                let value = arguments[index + 1]
                index += 2
                return value
            }
            index += 1
            return String(argument.dropFirst(flag.count + 1))
        }
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

    Native user core for je.

    Commands:
      status [--json]          Show native core and support status
      support-matrix [--json]  Show the published launch qualification matrix
      contracts [--json]       Show the frozen Python oracle contract
      doctor [--json]          Show a local health overview without contacting a service
      doctor muse [--json]     Probe public Muse local-contract signals without inference
      doctor --profile NAME    Check a gateway key and model without inference
      credential --profile NAME Supply a saved key to a desktop credential helper
      export --profile NAME    Write desktop setup files for review
      setup [--client C] [...] Add the Studio plugin to installed clients
      profile list             List saved connection names without credentials
      profile show NAME        Show public connection fields without credentials
      profile add NAME ...     Save a connection with a native secret reference
      profile remove NAME      Remove a saved connection locally
      memory list              List saved memory connection names without tokens
      memory show NAME         Show public memory fields without tokens
      memory add NAME ...      Save a memory connection with a native secret reference
      memory check NAME        Initialize memory MCP and list tools without calling one
      memory remove NAME       Remove a saved memory connection locally
      ollama profile list      List native Ollama connection names without credentials
      ollama profile show NAME Show public native Ollama fields without credentials
      ollama profile add NAME  Save a native Ollama connection with a secret reference
      ollama profile remove NAME Remove a saved native Ollama connection locally
      ollama --profile N check Check a native Ollama key and default model without inference
      ollama --profile N [...] Start the native Ollama CLI through a temporary loopback relay
      run --profile N -- CMD   Run another OpenAI-compatible client with the saved connection
      connect codex|claude ... Open Codex or Claude Code with a saved connection
      assignments list         List locally published assignment IDs
      assignments add ID ...   Publish one personal-machine assignment
      assignments qualify ID   Run and store one bounded qualification task
      why [flags] [--] PROMPT  Explain the selected qualified route without running it
      ask [flags] -- PROMPT    Select a route and launch its supported harness

    Host administration stays outside the user artifact.

    """
}
