import Foundation

public struct ModelsEngineEntry: Codable, Equatable, Sendable {
    public let engine: String
    public let executableName: String
    public let executablePath: String?
    public let storePath: String?
    public let storePresent: Bool
    public let storeBytes: Int64?
    public let storeComplete: Bool
    public let matrixCells: Int
    public let matrixCountsByStatus: [String: Int]
    public let assignments: Int
    public let assignmentCountsByStatus: [String: Int]

    enum CodingKeys: String, CodingKey {
        case engine
        case executableName = "executable_name"
        case executablePath = "executable_path"
        case storePath = "store_path"
        case storePresent = "store_present"
        case storeBytes = "store_bytes"
        case storeComplete = "store_complete"
        case matrixCells = "matrix_cells"
        case matrixCountsByStatus = "matrix_counts_by_status"
        case assignments
        case assignmentCountsByStatus = "assignment_counts_by_status"
    }
}

public struct ModelsArtifactEntry: Codable, Equatable, Sendable {
    public let engine: String
    public let modelArtifact: String
    public let modelFormat: String
    public let engineVersion: String
    public let assignments: Int
    public let qualifiedAssignments: Int
    public let roles: [String]

    enum CodingKeys: String, CodingKey {
        case engine
        case modelArtifact = "model_artifact"
        case modelFormat = "model_format"
        case engineVersion = "engine_version"
        case assignments
        case qualifiedAssignments = "qualified_assignments"
        case roles
    }
}

public struct ModelsAssignmentEntry: Codable, Equatable, Sendable {
    public let id: String
    public let cell: String
    public let role: String
    public let engine: String
    public let harness: String
    public let launchMode: String
    public let executionPlace: String
    public let modelArtifact: String
    public let engineVersion: String
    public let modelFormat: String
    public let protocolImplementation: String
    public let protocolVersion: String
    public let configurationDigest: String
    public let qualificationStatus: String
    public let qualificationEvidenceReference: String?
    public let connectionProfileName: String?
    public let available: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case cell
        case role
        case engine
        case harness
        case launchMode = "launch_mode"
        case executionPlace = "execution_place"
        case modelArtifact = "model_artifact"
        case engineVersion = "engine_version"
        case modelFormat = "model_format"
        case protocolImplementation = "protocol_implementation"
        case protocolVersion = "protocol_version"
        case configurationDigest = "configuration_digest"
        case qualificationStatus = "qualification_status"
        case qualificationEvidenceReference = "qualification_evidence_reference"
        case connectionProfileName = "connection_profile_name"
        case available
    }
}

public struct ModelsStorageArea: Codable, Equatable, Sendable {
    public let name: String
    public let bytes: Int64
    public let complete: Bool
}

public struct ModelsStorage: Codable, Equatable, Sendable {
    public let stateDirectory: String
    public let areas: [ModelsStorageArea]
    public let totalBytes: Int64

    enum CodingKeys: String, CodingKey {
        case stateDirectory = "state_directory"
        case areas
        case totalBytes = "total_bytes"
    }
}

public struct ModelsInspectionReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let nativeVersion: String
    public let engines: [ModelsEngineEntry]
    public let artifacts: [ModelsArtifactEntry]
    public let assignments: [ModelsAssignmentEntry]
    public let storage: ModelsStorage
    public let supportMatrix: SupportMatrixSummary

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case nativeVersion = "native_version"
        case engines
        case artifacts
        case assignments
        case storage
        case supportMatrix = "support_matrix"
    }
}

/// Builds the read-only `je models` inventory. It reads saved assignments,
/// the published matrix, PATH presence, and file sizes only. It never
/// resolves secret values, contacts a service, launches an engine, or
/// runs inference. Executable presence means found on PATH, not healthy.
public enum ModelsInspectionBuilder {
    private static let maximumWalkEntries = 50_000

    private struct EngineProbe {
        let family: EngineFamily
        let executableName: String
        let store: URL?
    }

    public static func build(
        stateDirectory: URL,
        environment: [String: String],
        homeDirectory: URL
    ) throws -> ModelsInspectionReport {
        let directory = stateDirectory.standardizedFileURL
        let candidates = try AssignmentRegistry(directory: directory)
            .loadCandidates()
            .sorted { $0.id < $1.id }

        let probes: [EngineProbe] = [
            EngineProbe(
                family: .ollama,
                executableName: "ollama",
                store: ollamaStore(environment: environment, homeDirectory: homeDirectory)
            ),
            EngineProbe(family: .mlxNative, executableName: "mlx_lm.server", store: nil),
            EngineProbe(
                family: .lmStudio,
                executableName: "lms",
                store: homeDirectory.appendingPathComponent(".lmstudio/models", isDirectory: true)
            ),
            EngineProbe(family: .llamaCpp, executableName: "llama-server", store: nil)
        ]

        let engines = probes.map { probe -> ModelsEngineEntry in
            var matrixCounts: [String: Int] = [:]
            var matrixCells = 0
            for entry in SupportMatrix.launchEntries where entry.engine == probe.family {
                matrixCells += 1
                matrixCounts[entry.status.rawValue, default: 0] += 1
            }
            var assignmentCounts: [String: Int] = [:]
            var assignmentTotal = 0
            for candidate in candidates where candidate.engine == probe.family {
                assignmentTotal += 1
                assignmentCounts[candidate.qualificationStatus.rawValue, default: 0] += 1
            }
            let storePresent = probe.store.map {
                FileManager.default.fileExists(atPath: $0.path)
            } ?? false
            let measured = probe.store.flatMap { storePresent ? measure($0) : nil }
            return ModelsEngineEntry(
                engine: probe.family.rawValue,
                executableName: probe.executableName,
                executablePath: JECommandLine.searchExecutableOnPath(
                    named: probe.executableName, environment: environment
                )?.path,
                storePath: probe.store?.path,
                storePresent: storePresent,
                storeBytes: measured?.bytes,
                storeComplete: measured?.complete ?? true,
                matrixCells: matrixCells,
                matrixCountsByStatus: matrixCounts,
                assignments: assignmentTotal,
                assignmentCountsByStatus: assignmentCounts
            )
        }

        var artifactGroups: [String: (entry: ModelsArtifactEntry, roles: Set<String>)] = [:]
        var artifactOrder: [String] = []
        for candidate in candidates {
            let key = [
                candidate.engine.rawValue, candidate.modelArtifact,
                candidate.modelFormat, candidate.engineVersion
            ].joined(separator: "\u{1}")
            if artifactGroups[key] == nil {
                artifactOrder.append(key)
                artifactGroups[key] = (
                    ModelsArtifactEntry(
                        engine: candidate.engine.rawValue,
                        modelArtifact: candidate.modelArtifact,
                        modelFormat: candidate.modelFormat,
                        engineVersion: candidate.engineVersion,
                        assignments: 0,
                        qualifiedAssignments: 0,
                        roles: []
                    ),
                    []
                )
            }
            var group = artifactGroups[key]!
            group.roles.insert(candidate.role.rawValue)
            group.entry = ModelsArtifactEntry(
                engine: group.entry.engine,
                modelArtifact: group.entry.modelArtifact,
                modelFormat: group.entry.modelFormat,
                engineVersion: group.entry.engineVersion,
                assignments: group.entry.assignments + 1,
                qualifiedAssignments: group.entry.qualifiedAssignments
                    + (candidate.qualificationStatus == .qualified ? 1 : 0),
                roles: group.roles.sorted()
            )
            artifactGroups[key] = group
        }
        let artifacts = artifactOrder
            .map { artifactGroups[$0]!.entry }
            .sorted {
                ($0.engine, $0.modelArtifact, $0.modelFormat, $0.engineVersion)
                    < ($1.engine, $1.modelArtifact, $1.modelFormat, $1.engineVersion)
            }

        let assignments = candidates.map { candidate in
            ModelsAssignmentEntry(
                id: candidate.id,
                cell: [
                    candidate.role.rawValue, candidate.engine.rawValue,
                    candidate.harness.rawValue, candidate.launchMode.rawValue,
                    candidate.executionPlace.rawValue
                ].joined(separator: "/"),
                role: candidate.role.rawValue,
                engine: candidate.engine.rawValue,
                harness: candidate.harness.rawValue,
                launchMode: candidate.launchMode.rawValue,
                executionPlace: candidate.executionPlace.rawValue,
                modelArtifact: candidate.modelArtifact,
                engineVersion: candidate.engineVersion,
                modelFormat: candidate.modelFormat,
                protocolImplementation: candidate.protocolImplementation,
                protocolVersion: candidate.protocolVersion,
                configurationDigest: candidate.configurationDigest,
                qualificationStatus: candidate.qualificationStatus.rawValue,
                qualificationEvidenceReference: candidate.qualificationEvidenceReference,
                connectionProfileName: candidate.connectionProfileName,
                available: candidate.available
            )
        }

        return ModelsInspectionReport(
            schemaVersion: 1,
            nativeVersion: JEVersion.current,
            engines: engines,
            artifacts: artifacts,
            assignments: assignments,
            storage: storage(directory: directory),
            supportMatrix: SupportMatrix.summary
        )
    }

    public static func render(_ report: ModelsInspectionReport) -> String {
        var lines: [String] = ["Engines"]
        for engine in report.engines {
            let found = engine.executablePath ?? "not found on PATH"
            let store: String
            if engine.storePath == nil {
                store = "no dedicated store"
            } else if !engine.storePresent {
                store = "store absent"
            } else if let bytes = engine.storeBytes {
                store = "store \(formatBytes(bytes))" + (engine.storeComplete ? "" : "+ (truncated)")
            } else {
                store = "store unmeasured"
            }
            lines.append(
                "  \(engine.engine): \(engine.executableName) \(found); \(store); "
                    + "matrix \(countsText(engine.matrixCountsByStatus)) of \(engine.matrixCells); "
                    + "assignments \(engine.assignments) (\(countsText(engine.assignmentCountsByStatus)))"
            )
        }
        lines.append("Artifacts")
        if report.artifacts.isEmpty {
            lines.append("  none published")
        } else {
            for artifact in report.artifacts {
                let noun = artifact.assignments == 1 ? "assignment" : "assignments"
                lines.append(
                    "  \(artifact.engine) \(artifact.modelArtifact) (\(artifact.modelFormat), "
                        + "engine \(artifact.engineVersion)): \(artifact.assignments) \(noun), "
                        + "\(artifact.qualifiedAssignments) qualified, roles "
                        + artifact.roles.joined(separator: ", ")
                )
            }
        }
        lines.append("Assignments")
        if report.assignments.isEmpty {
            lines.append("  none published")
        } else {
            for assignment in report.assignments {
                lines.append(
                    "  \(assignment.id): \(assignment.cell) \(assignment.modelArtifact) "
                        + "[\(assignment.qualificationStatus)]"
                )
            }
        }
        lines.append("Storage")
        lines.append("  state \(report.storage.stateDirectory): \(formatBytes(report.storage.totalBytes)) total")
        for area in report.storage.areas {
            lines.append("  \(area.name): \(formatBytes(area.bytes))" + (area.complete ? "" : "+ (truncated)"))
        }
        lines.append("Qualification")
        lines.append(
            "  matrix \(report.supportMatrix.totalCells) cells: "
                + countsText(report.supportMatrix.countsByStatus)
        )
        lines.append("Executable presence means found on PATH, not healthy. This view is read-only.")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func ollamaStore(environment: [String: String], homeDirectory: URL) -> URL {
        if let override = environment["OLLAMA_MODELS"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(".ollama/models", isDirectory: true)
    }

    private static func storage(directory: URL) -> ModelsStorage {
        let areaNames = [
            "profiles", "memory-profiles", "ollama-profiles",
            "qualification", "usage", "reports", "exports"
        ]
        var areas: [ModelsStorageArea] = []
        for name in areaNames {
            let url = directory.appendingPathComponent(name, isDirectory: true)
            guard FileManager.default.fileExists(atPath: url.path),
                  let measured = measure(url) else { continue }
            areas.append(ModelsStorageArea(name: name, bytes: measured.bytes, complete: measured.complete))
        }
        let registry = directory.appendingPathComponent("assignments.json")
        if let measured = measure(registry) {
            areas.append(ModelsStorageArea(
                name: "assignments.json", bytes: measured.bytes, complete: measured.complete
            ))
        }
        return ModelsStorage(
            stateDirectory: directory.path,
            areas: areas,
            totalBytes: areas.map(\.bytes).reduce(0, +)
        )
    }

    private static func measure(_ url: URL) -> (bytes: Int64, complete: Bool)? {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }
        if !isDirectory.boolValue {
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            guard values?.isSymbolicLink != true else { return nil }
            return (Int64(values?.fileSize ?? 0), true)
        }
        guard let enumerator = manager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        ) else {
            return (0, false)
        }
        var total: Int64 = 0
        var seen = 0
        var complete = true
        for case let item as URL in enumerator {
            seen += 1
            if seen > maximumWalkEntries {
                complete = false
                break
            }
            guard let values = try? item.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            ) else { continue }
            if values.isSymbolicLink == true {
                if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return (total, complete)
    }

    private static func countsText(_ counts: [String: Int]) -> String {
        guard !counts.isEmpty else { return "none" }
        return counts.sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value)" }
            .joined(separator: ", ")
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit == 0 {
            return "\(bytes) B"
        }
        return String(format: "%.1f %@", value, units[unit])
    }
}
