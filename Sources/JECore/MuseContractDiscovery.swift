import Foundation

public struct MuseContractReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let version: String
    public let interactiveProviders: [String]
    public let headlessProviders: [String]
    public let authenticationProviders: [String]
    public let physicalMemoryBytes: UInt64
    public let minimumKnownLocalMemoryBytes: UInt64?
    public let experimentEnvironmentVariable: String?
    public let headlessLocalParserAccepted: Bool?
    public let arbitraryLocalEndpointContractDiscovered: Bool
    public let localContractStatus: String
    public let evidenceCodes: [String]
    public let evidenceReference: String
}

public struct MuseContractDiscovery: Sendable {
    public let physicalMemoryBytes: UInt64

    public init(physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        self.physicalMemoryBytes = physicalMemoryBytes
    }

    public func discover(
        executableOverride: String?,
        environment: [String: String]
    ) throws -> MuseContractReport {
        let executable = try resolveExecutable(
            override: executableOverride,
            environment: environment
        )
        var probeEnvironment = environment
        probeEnvironment.removeValue(forKey: "MUSE_EXPERIMENTAL_LOCAL_MODELS")

        let versionOutput = try run(executable, ["--version"], environment: probeEnvironment)
        let interactiveHelp = try run(executable, ["--help"], environment: probeEnvironment)
        let headlessHelp = try run(executable, ["exec", "--help"], environment: probeEnvironment)
        let authHelp = try run(executable, ["auth", "set", "--help"], environment: probeEnvironment)

        let version = parseVersion(versionOutput)
        guard !version.isEmpty else {
            throw StateStoreError("Muse did not return a recognized version.")
        }
        let interactiveProviders = parseStartupProviders(interactiveHelp)
        let headlessProviders = parseStartupProviders(headlessHelp)
        let authProviders = parseAuthenticationProviders(authHelp)
        let knownVersion = version.hasPrefix("1.4.14")
        let minimumMemory: UInt64? = knownVersion ? 64 * 1024 * 1024 * 1024 : nil
        let interactiveLocal = interactiveProviders.contains("local")

        let status: String
        if !interactiveLocal {
            status = "local_not_advertised"
        } else if !knownVersion {
            status = "unknown_version_contract_unqualified"
        } else if let minimumMemory, physicalMemoryBytes < minimumMemory {
            status = "builtin_glimmer_unavailable_memory"
        } else {
            status = "builtin_glimmer_contract_discovered_not_qualified"
        }

        var evidence: [String] = []
        if interactiveLocal {
            evidence.append("interactive_help_lists_local")
        }
        if headlessProviders.contains("local") {
            evidence.append("headless_help_lists_local")
        } else {
            evidence.append("headless_help_omits_local")
        }
        if authProviders == ["meta"] {
            evidence.append("auth_accepts_only_meta")
        }
        if knownVersion {
            evidence.append("known_version_local_models_experiment")
            evidence.append("known_version_headless_local_parser_accepted")
            evidence.append("known_version_builtin_glimmer_memory_gate")
        }

        let evidenceDigest = SHA256.hexDigest(Data([
            version,
            interactiveProviders.joined(separator: ","),
            headlessProviders.joined(separator: ","),
            authProviders.joined(separator: ","),
            String(physicalMemoryBytes),
            status
        ].joined(separator: "|").utf8))

        return MuseContractReport(
            schemaVersion: 1,
            version: version,
            interactiveProviders: interactiveProviders,
            headlessProviders: headlessProviders,
            authenticationProviders: authProviders,
            physicalMemoryBytes: physicalMemoryBytes,
            minimumKnownLocalMemoryBytes: minimumMemory,
            experimentEnvironmentVariable: knownVersion ? "MUSE_EXPERIMENTAL_LOCAL_MODELS" : nil,
            headlessLocalParserAccepted: knownVersion ? true : nil,
            arbitraryLocalEndpointContractDiscovered: false,
            localContractStatus: status,
            evidenceCodes: evidence,
            evidenceReference: "evidence:muse-contract:" + evidenceDigest
        )
    }

    private func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]
    ) throws -> String {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        let timeout = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        do {
            try process.run()
        } catch {
            throw StateStoreError("The Muse executable could not be started.")
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: timeout)
        let data: Data
        do {
            data = try stdout.fileHandleForReading.read(upToCount: 64 * 1024 + 1) ?? Data()
        } catch {
            timeout.cancel()
            if process.isRunning { process.terminate() }
            throw StateStoreError("Muse contract discovery failed.")
        }
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0, data.count <= 64 * 1024,
              let output = String(data: data, encoding: .utf8) else {
            throw StateStoreError("Muse contract discovery failed.")
        }
        return output
    }

    private func resolveExecutable(
        override: String?,
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
            candidate = searchPath(for: "muse", environment: environment)
        }
        guard let candidate, FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw StateStoreError("The Muse executable is unavailable.")
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

    private func parseVersion(_ output: String) -> String {
        let firstLine = output.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let value = firstLine.hasPrefix("Muse Code ")
            ? String(firstLine.dropFirst("Muse Code ".count))
            : firstLine
        return value.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
    }

    private func parseStartupProviders(_ help: String) -> [String] {
        let flattened = help
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        guard let start = flattened.range(of: "Startup provider:") else {
            return []
        }
        let remainder = flattened[start.upperBound...]
        let end = remainder.range(of: "(default")?.lowerBound ?? remainder.endIndex
        let segment = remainder[..<end]
        return ["echo", "meta", "local"].filter { segment.contains($0) }
    }

    private func parseAuthenticationProviders(_ help: String) -> [String] {
        guard let start = help.range(of: "[possible values:") else {
            return []
        }
        let remainder = help[start.upperBound...]
        guard let end = remainder.range(of: "]") else {
            return []
        }
        return remainder[..<end.lowerBound]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
