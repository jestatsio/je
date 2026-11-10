public enum ModelRole: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case fast
    case strong
}

public enum InternalRole: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case embeddings
    case triage
}

public enum EngineFamily: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case ollama
    case mlxNative = "mlx_native"
    case lmStudio = "lm_studio"
    case llamaCpp = "llama_cpp"
}

public enum HarnessKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case codex
    case claudeCode = "claude_code"
    case muse
    case builtIn = "built_in"
}

public enum LaunchMode: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case interactive
    case headless
    case singleStep = "single_step"
}

public enum ExecutionPlace: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case personalMachine = "personal_machine"
    case studioWorkspace = "studio_workspace"
}

public enum QualificationStatus: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case planned
    case blockedOnContractDiscovery = "blocked_on_contract_discovery"
    case qualified
    case unsupported
}

public struct SupportMatrixEntry: Codable, Equatable, Hashable, Sendable {
    public let role: ModelRole
    public let engine: EngineFamily
    public let harness: HarnessKind
    public let launchMode: LaunchMode
    public let executionPlace: ExecutionPlace
    public let status: QualificationStatus

    public init(
        role: ModelRole,
        engine: EngineFamily,
        harness: HarnessKind,
        launchMode: LaunchMode,
        executionPlace: ExecutionPlace,
        status: QualificationStatus
    ) {
        self.role = role
        self.engine = engine
        self.harness = harness
        self.launchMode = launchMode
        self.executionPlace = executionPlace
        self.status = status
    }

    public var id: String {
        [role.rawValue, engine.rawValue, harness.rawValue, launchMode.rawValue, executionPlace.rawValue]
            .joined(separator: "/")
    }
}

public struct SupportMatrixSummary: Codable, Equatable, Sendable {
    public let totalCells: Int
    public let countsByStatus: [String: Int]
    public let roles: [String]
    public let engines: [String]
    public let harnesses: [String]
    public let executionPlaces: [String]
}

public enum SupportMatrix {
    public static let launchEntries: [SupportMatrixEntry] = buildLaunchEntries()

    public static var summary: SupportMatrixSummary {
        var counts: [String: Int] = [:]
        for entry in launchEntries {
            counts[entry.status.rawValue, default: 0] += 1
        }
        return SupportMatrixSummary(
            totalCells: launchEntries.count,
            countsByStatus: counts,
            roles: ModelRole.allCases.map(\.rawValue),
            engines: EngineFamily.allCases.map(\.rawValue),
            harnesses: HarnessKind.allCases.map(\.rawValue),
            executionPlaces: ExecutionPlace.allCases.map(\.rawValue)
        )
    }

    public static func duplicateIDs(in entries: [SupportMatrixEntry] = launchEntries) -> [String] {
        var seen: Set<String> = []
        var duplicates: Set<String> = []
        for entry in entries {
            if !seen.insert(entry.id).inserted {
                duplicates.insert(entry.id)
            }
        }
        return duplicates.sorted()
    }

    private static func buildLaunchEntries() -> [SupportMatrixEntry] {
        var entries: [SupportMatrixEntry] = []
        let codingHarnesses: [HarnessKind] = [.codex, .claudeCode, .muse]
        let codingModes: [LaunchMode] = [.interactive, .headless]

        for role in ModelRole.allCases {
            for engine in EngineFamily.allCases {
                for place in ExecutionPlace.allCases {
                    for harness in codingHarnesses {
                        for mode in codingModes {
                            // Muse 1.4.14 has no arbitrary local endpoint
                            // contract. Its only local route is the gated
                            // built-in Glimmer experiment (MLX family).
                            // Non-MLX Muse cells were declared unsupported
                            // ahead of qualification on 2026-11-09 trial
                            // evidence. See MUSE_CONTRACT_TRIALS.md.
                            let status: QualificationStatus =
                                (harness == .muse && engine != .mlxNative)
                                ? .unsupported
                                : .planned
                            entries.append(SupportMatrixEntry(
                                role: role,
                                engine: engine,
                                harness: harness,
                                launchMode: mode,
                                executionPlace: place,
                                status: status
                            ))
                        }
                    }
                    // Qualified 2026-11-09 on recorded evidence; see IMPLEMENTATION.md.
                    let builtInStatus: QualificationStatus =
                        (role == .fast && engine == .ollama && place == .personalMachine)
                        ? .qualified
                        : .planned
                    entries.append(SupportMatrixEntry(
                        role: role,
                        engine: engine,
                        harness: .builtIn,
                        launchMode: .singleStep,
                        executionPlace: place,
                        status: builtInStatus
                    ))
                }
            }
        }
        return entries.sorted { $0.id < $1.id }
    }
}
