import Foundation

public struct DoctorMachine: Codable, Equatable, Sendable {
    public let os: String
    public let arch: String
    public let memoryBytes: UInt64

    enum CodingKeys: String, CodingKey {
        case os
        case arch
        case memoryBytes = "memory_bytes"
    }
}

public struct DoctorProfileEntry: Codable, Equatable, Sendable {
    public let name: String
    public let endpoint: String
    public let model: String?
    public let secretStorage: String

    enum CodingKeys: String, CodingKey {
        case name
        case endpoint
        case model
        case secretStorage = "secret_storage"
    }
}

public struct DoctorProfiles: Codable, Equatable, Sendable {
    public let gateway: [DoctorProfileEntry]
    public let memory: [DoctorProfileEntry]
    public let ollama: [DoctorProfileEntry]
}

public struct DoctorAssignmentEntry: Codable, Equatable, Sendable {
    public let id: String
    public let role: String
    public let engine: String
    public let harness: String
    public let model: String
    public let status: String
}

public struct DoctorAssignments: Codable, Equatable, Sendable {
    public let total: Int
    public let qualified: Int
    public let countsByStatus: [String: Int]
    public let entries: [DoctorAssignmentEntry]

    enum CodingKeys: String, CodingKey {
        case total
        case qualified
        case countsByStatus = "counts_by_status"
        case entries
    }
}

public struct DoctorExecutable: Codable, Equatable, Sendable {
    public let name: String
    public let path: String?
}

public struct DoctorUsage: Codable, Equatable, Sendable {
    public let detailedTraces: Int
    public let latestRecordedDay: String?

    enum CodingKeys: String, CodingKey {
        case detailedTraces = "detailed_traces"
        case latestRecordedDay = "latest_recorded_day"
    }
}

public struct DoctorWarning: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
}

public struct DoctorOverviewReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let nativeVersion: String
    public let artifact: String
    public let stateDirectory: String
    public let machine: DoctorMachine
    public let profiles: DoctorProfiles
    public let assignments: DoctorAssignments
    public let supportMatrix: SupportMatrixSummary
    public let executables: [DoctorExecutable]
    public let usage: DoctorUsage
    public let warnings: [DoctorWarning]
    public let healthy: Bool

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case nativeVersion = "native_version"
        case artifact
        case stateDirectory = "state_directory"
        case machine
        case profiles
        case assignments
        case supportMatrix = "support_matrix"
        case executables
        case usage
        case warnings
        case healthy
    }
}

/// Builds the local-only `je doctor` overview from saved state. It never
/// resolves secret values, contacts a service, or runs inference.
public enum DoctorOverviewBuilder {
    public static func build(
        stateDirectory: URL,
        environment: [String: String],
        machineOS: String = DoctorOverviewBuilder.defaultMachineOS(),
        machineArch: String = DoctorOverviewBuilder.defaultMachineArch(),
        memoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) throws -> DoctorOverviewReport {
        let directory = stateDirectory.standardizedFileURL
        let store = ProfileStore(directory: directory)
        var embeddedWarnings: [DoctorWarning] = []
        var unloadableWarnings: [DoctorWarning] = []

        func loadKind(
            folder: String,
            kind: String,
            load: (String) throws -> DoctorProfileEntry
        ) -> [DoctorProfileEntry] {
            var entries: [DoctorProfileEntry] = []
            for name in profileFileNames(stateDirectory: directory, folderName: folder) {
                do {
                    let entry = try load(name)
                    entries.append(entry)
                    if entry.secretStorage == ProfileSecretStorage.embeddedLegacy.rawValue {
                        embeddedWarnings.append(DoctorWarning(
                            code: "embedded_secret",
                            message: "\(kind) profile '\(name)' still stores its credential "
                                + "inside the profile file. Migrate it to native secret "
                                + "storage; older backups may still contain the embedded key."))
                    }
                } catch {
                    unloadableWarnings.append(DoctorWarning(
                        code: "unloadable_profile",
                        message: "\(kind) profile '\(name)' could not be loaded and was skipped."))
                }
            }
            return entries
        }

        let gatewayFiles = profileFileNames(stateDirectory: directory, folderName: "profiles")
        let ollamaFiles = profileFileNames(
            stateDirectory: directory, folderName: "ollama-profiles")
        let gateway = loadKind(folder: "profiles", kind: "Gateway") { name in
            let profile = try store.loadPublicProfile(name: name)
            return DoctorProfileEntry(
                name: profile.name,
                endpoint: profile.endpoint,
                model: profile.model,
                secretStorage: try store.gatewaySecretStorage(name: name).rawValue)
        }
        let memory = loadKind(folder: "memory-profiles", kind: "Memory") { name in
            let profile = try store.loadPublicMemoryProfile(name: name)
            return DoctorProfileEntry(
                name: profile.name,
                endpoint: profile.endpoint,
                model: nil,
                secretStorage: try store.memorySecretStorage(name: name).rawValue)
        }
        let ollama = loadKind(folder: "ollama-profiles", kind: "Ollama") { name in
            let profile = try store.loadPublicOllamaProfile(name: name)
            return DoctorProfileEntry(
                name: profile.name,
                endpoint: profile.endpoint,
                model: profile.model,
                secretStorage: try store.ollamaSecretStorage(name: name).rawValue)
        }

        var assignmentWarnings: [DoctorWarning] = []
        var candidates: [RouteCandidate] = []
        do {
            candidates = try AssignmentRegistry(directory: directory)
                .loadCandidates()
                .sorted { $0.id < $1.id }
        } catch {
            assignmentWarnings.append(DoctorWarning(
                code: "assignments_unreadable",
                message: "Published assignments could not be read and were skipped."))
        }
        let knownProfiles = Set(gatewayFiles).union(ollamaFiles)
        for candidate in candidates {
            if let name = candidate.connectionProfileName,
               !knownProfiles.contains(name) {
                assignmentWarnings.append(DoctorWarning(
                    code: "dangling_assignment_profile",
                    message: "Assignment '\(candidate.id)' references missing "
                        + "connection profile '\(name)'."))
            }
        }
        var countsByStatus: [String: Int] = [:]
        for candidate in candidates {
            countsByStatus[candidate.qualificationStatus.rawValue, default: 0] += 1
        }
        let qualified = countsByStatus[QualificationStatus.qualified.rawValue] ?? 0
        let assignments = DoctorAssignments(
            total: candidates.count,
            qualified: qualified,
            countsByStatus: countsByStatus,
            entries: candidates.map {
                DoctorAssignmentEntry(
                    id: $0.id,
                    role: $0.role.rawValue,
                    engine: $0.engine.rawValue,
                    harness: $0.harness.rawValue,
                    model: $0.modelArtifact,
                    status: $0.qualificationStatus.rawValue)
            })

        let ollamaPath = JECommandLine.resolveOllamaExecutable(
            override: nil, environment: environment)?.path
        let codexPath = JECommandLine.searchExecutableOnPath(
            named: "codex", environment: environment)?.path
        let claudePath = JECommandLine.searchExecutableOnPath(
            named: "claude", environment: environment)?.path
        let musePath = JECommandLine.searchExecutableOnPath(
            named: "muse", environment: environment)?.path
        let executables = [
            DoctorExecutable(name: "ollama", path: ollamaPath),
            DoctorExecutable(name: "codex", path: codexPath),
            DoctorExecutable(name: "claude", path: claudePath),
            DoctorExecutable(name: "muse", path: musePath)
        ]
        var executableWarnings: [DoctorWarning] = []
        if ollamaPath == nil && !ollama.isEmpty {
            executableWarnings.append(DoctorWarning(
                code: "missing_executable",
                message: "The Ollama CLI was not found, but native Ollama profiles are saved."))
        }
        let harnessNeeds: [(name: String, path: String?, harness: HarnessKind)] = [
            ("codex", codexPath, .codex),
            ("claude", claudePath, .claudeCode),
            ("muse", musePath, .muse)
        ]
        for need in harnessNeeds
        where need.path == nil && candidates.contains(where: { $0.harness == need.harness }) {
            executableWarnings.append(DoctorWarning(
                code: "missing_executable",
                message: "The \(need.name) executable was not found, "
                    + "but published assignments need it."))
        }

        var tailWarnings: [DoctorWarning] = []
        if !candidates.isEmpty && qualified == 0 {
            tailWarnings.append(DoctorWarning(
                code: "no_qualified_assignments",
                message: "No published assignment is qualified yet. "
                    + "Run je assignments qualify ID."))
        }
        var usage = DoctorUsage(detailedTraces: 0, latestRecordedDay: nil)
        do {
            let ledger = try UsageLedgerFile(directory: directory).load()
            usage = DoctorUsage(
                detailedTraces: ledger.entries.count,
                latestRecordedDay: ledger.entries.map(\.recordedDay).max())
        } catch {
            tailWarnings.append(DoctorWarning(
                code: "usage_unreadable",
                message: "The usage ledger could not be read and was skipped."))
        }

        let warnings = embeddedWarnings + unloadableWarnings
            + assignmentWarnings + executableWarnings + tailWarnings
        return DoctorOverviewReport(
            schemaVersion: 1,
            nativeVersion: JEVersion.current,
            artifact: "user",
            stateDirectory: directory.path,
            machine: DoctorMachine(os: machineOS, arch: machineArch, memoryBytes: memoryBytes),
            profiles: DoctorProfiles(gateway: gateway, memory: memory, ollama: ollama),
            assignments: assignments,
            supportMatrix: SupportMatrix.summary,
            executables: executables,
            usage: usage,
            warnings: warnings,
            healthy: warnings.isEmpty)
    }

    public static func defaultMachineOS() -> String {
        #if os(macOS)
        let name = "macOS"
        #elseif os(Linux)
        let name = "Linux"
        #else
        let name = "OS"
        #endif
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(name) \(version.majorVersion).\(version.minorVersion)"
    }

    public static func defaultMachineArch() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func profileFileNames(stateDirectory: URL, folderName: String) -> [String] {
        let folder = stateDirectory.appendingPathComponent(folderName, isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []) else {
            return []
        }
        return entries.compactMap { url -> String? in
            guard url.pathExtension == "json" else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            guard ProfileNameValidator.isValid(name) else { return nil }
            let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
                return nil
            }
            return name
        }.sorted()
    }
}

public enum DoctorOverviewRenderer {
    public static func render(_ report: DoctorOverviewReport) -> String {
        var lines: [String] = []
        lines.append("je doctor")
        lines.append("Version: je \(report.nativeVersion) · user artifact · contracts pre-1.0")
        lines.append("State: \(report.stateDirectory)")
        let gigabytes = Int((Double(report.machine.memoryBytes) / 1_000_000_000).rounded())
        lines.append("Machine: \(report.machine.os) · \(report.machine.arch) · \(gigabytes) GB memory")
        lines.append("")

        lines.append("Profiles")
        let rows: [(kind: String, entry: DoctorProfileEntry)] =
            report.profiles.gateway.map { ("Gateway", $0) }
            + report.profiles.memory.map { ("Memory", $0) }
            + report.profiles.ollama.map { ("Ollama", $0) }
        if rows.isEmpty {
            lines.append("  none saved")
        } else {
            let nameWidth = rows.map { $0.entry.name.count }.max() ?? 0
            for row in rows {
                var detail = row.entry.endpoint
                if let model = row.entry.model {
                    detail = model + " · " + detail
                }
                detail += " · " + storageText(row.entry.secretStorage)
                lines.append(
                    "  \(pad(row.kind, to: 8)) \(pad(row.entry.name, to: nameWidth)) \(detail)")
            }
        }
        lines.append("")

        lines.append("Assignments")
        if report.assignments.entries.isEmpty {
            lines.append("  none published")
        } else {
            let idWidth = report.assignments.entries.map { $0.id.count }.max() ?? 0
            for entry in report.assignments.entries {
                lines.append(
                    "  \(pad(entry.id, to: idWidth)) \(entry.role) · "
                        + "\(entry.engine)/\(entry.harness) · \(entry.model) · \(entry.status)")
            }
            lines.append(
                "  \(report.assignments.total) published · "
                    + "\(report.assignments.qualified) qualified")
        }
        lines.append("")

        lines.append("Support matrix")
        var matrix = "  \(report.supportMatrix.totalCells) launch cells"
        let knownOrder = ["planned", "blocked_on_contract_discovery", "qualified"]
        let extras = report.supportMatrix.countsByStatus.keys
            .filter { !knownOrder.contains($0) }.sorted()
        for key in knownOrder + extras {
            if let count = report.supportMatrix.countsByStatus[key] {
                matrix += " · \(count) \(key)"
            }
        }
        lines.append(matrix)
        lines.append("")

        lines.append("Executables")
        for executable in report.executables {
            lines.append("  \(pad(executable.name, to: 7)) \(executable.path ?? "not found")")
        }
        lines.append("")

        lines.append("Usage")
        if report.usage.detailedTraces == 0 {
            lines.append("  no runs recorded")
        } else if let latest = report.usage.latestRecordedDay {
            lines.append("  \(report.usage.detailedTraces) detailed traces · latest \(latest)")
        } else {
            lines.append("  \(report.usage.detailedTraces) detailed traces")
        }

        if !report.warnings.isEmpty {
            lines.append("")
            lines.append("Warnings")
            for warning in report.warnings {
                lines.append("  - \(warning.message)")
            }
        }
        lines.append("")
        if report.healthy {
            lines.append("Healthy. Run je doctor --profile NAME to check a connection live.")
        } else {
            let count = report.warnings.count
            let noun = count == 1 ? "warning" : "warnings"
            lines.append(
                "\(count) \(noun) to review. "
                    + "Run je doctor --profile NAME to check a connection live.")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func storageText(_ raw: String) -> String {
        raw == ProfileSecretStorage.embeddedLegacy.rawValue ? "embedded key" : "secret reference"
    }

    private static func pad(_ value: String, to width: Int) -> String {
        value.count >= width
            ? value
            : value + String(repeating: " ", count: width - value.count)
    }
}
