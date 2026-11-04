public enum RunOutcome: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case succeeded
    case failed
    case canceled
    case waiting
}

public struct CostAmount: Codable, Equatable, Hashable, Sendable {
    public let currency: String
    public let minorUnits: Int64

    public init(currency: String, minorUnits: Int64) {
        self.currency = currency
        self.minorUnits = minorUnits
    }

    public var isValid: Bool {
        currency.count == 3
            && currency.allSatisfy { $0 >= "A" && $0 <= "Z" }
            && minorUnits >= 0
    }
}

public struct DetailedUsageTrace: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let runID: String
    public let recordedDay: String
    public let personID: String
    public let harness: HarnessKind
    public let launchMode: LaunchMode
    public let role: ModelRole
    public let engine: EngineFamily
    public let executionPlace: ExecutionPlace
    public let providerKind: ProviderKind
    public let assignmentID: String
    public let policyVersion: String
    public let winningLayer: String
    public let durationMs: Int64?
    public let inputTokens: Int64?
    public let outputTokens: Int64?
    public let actualCost: CostAmount?
    public let estimatedCost: CostAmount?
    public let costEstimateSource: String?
    public let outcome: RunOutcome

    public init(
        schemaVersion: Int = 1,
        runID: String,
        recordedDay: String,
        personID: String,
        harness: HarnessKind,
        launchMode: LaunchMode,
        role: ModelRole,
        engine: EngineFamily,
        executionPlace: ExecutionPlace,
        providerKind: ProviderKind,
        assignmentID: String,
        policyVersion: String,
        winningLayer: String,
        durationMs: Int64? = nil,
        inputTokens: Int64? = nil,
        outputTokens: Int64? = nil,
        actualCost: CostAmount? = nil,
        estimatedCost: CostAmount? = nil,
        costEstimateSource: String? = nil,
        outcome: RunOutcome
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.recordedDay = recordedDay
        self.personID = personID
        self.harness = harness
        self.launchMode = launchMode
        self.role = role
        self.engine = engine
        self.executionPlace = executionPlace
        self.providerKind = providerKind
        self.assignmentID = assignmentID
        self.policyVersion = policyVersion
        self.winningLayer = winningLayer
        self.durationMs = durationMs
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.actualCost = actualCost
        self.estimatedCost = estimatedCost
        self.costEstimateSource = costEstimateSource
        self.outcome = outcome
    }
}

public enum UsageLedgerError: Error, Equatable, Sendable {
    case invalidEntry(String)
    case conflictingRunID(String)
}

public struct UsageLedger: Equatable, Sendable {
    public private(set) var entries: [DetailedUsageTrace]

    public init() {
        self.entries = []
    }

    public init(entries: [DetailedUsageTrace]) throws {
        self.entries = []
        for entry in entries {
            try append(entry)
        }
    }

    @discardableResult
    public mutating func append(_ entry: DetailedUsageTrace) throws -> Bool {
        try Self.validate(entry)
        if let existing = entries.first(where: { $0.runID == entry.runID }) {
            if existing == entry {
                return false
            }
            throw UsageLedgerError.conflictingRunID(entry.runID)
        }
        entries.append(entry)
        entries.sort { lhs, rhs in
            if lhs.recordedDay != rhs.recordedDay { return lhs.recordedDay < rhs.recordedDay }
            return lhs.runID < rhs.runID
        }
        return true
    }

    public func aggregates() -> [UsageAggregate] {
        Self.aggregate(entries: entries)
    }

    public static func validate(_ entry: DetailedUsageTrace) throws {
        guard entry.schemaVersion == 1 else {
            throw UsageLedgerError.invalidEntry("unsupported schema version")
        }
        guard !entry.runID.isEmpty, !entry.personID.isEmpty, !entry.assignmentID.isEmpty,
              !entry.policyVersion.isEmpty, !entry.winningLayer.isEmpty else {
            throw UsageLedgerError.invalidEntry("required identity fields must not be empty")
        }
        guard isValidDay(entry.recordedDay) else {
            throw UsageLedgerError.invalidEntry("recorded day must use yyyy-mm-dd")
        }
        for value in [entry.durationMs, entry.inputTokens, entry.outputTokens] {
            if let value, value < 0 {
                throw UsageLedgerError.invalidEntry("measurements must not be negative")
            }
        }
        if let actualCost = entry.actualCost, !actualCost.isValid {
            throw UsageLedgerError.invalidEntry("actual cost is invalid")
        }
        if let estimatedCost = entry.estimatedCost {
            guard estimatedCost.isValid else {
                throw UsageLedgerError.invalidEntry("estimated cost is invalid")
            }
            guard let source = entry.costEstimateSource, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw UsageLedgerError.invalidEntry("estimated cost requires a source")
            }
        } else if entry.costEstimateSource != nil {
            throw UsageLedgerError.invalidEntry("cost estimate source requires an estimated cost")
        }
    }

    private static func isValidDay(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let month = Int(parts[1]), (1...12).contains(month),
              let day = Int(parts[2]), (1...31).contains(day),
              parts.allSatisfy({ part in part.allSatisfy { $0 >= "0" && $0 <= "9" } }) else {
            return false
        }
        return true
    }
}

public struct UsageAggregateKey: Codable, Equatable, Hashable, Sendable {
    public let day: String
    public let personID: String
    public let harness: HarnessKind
    public let role: ModelRole
    public let engine: EngineFamily
    public let executionPlace: ExecutionPlace
    public let providerKind: ProviderKind
    public let outcome: RunOutcome

    public var sortKey: String {
        [day, personID, harness.rawValue, role.rawValue, engine.rawValue,
         executionPlace.rawValue, providerKind.rawValue, outcome.rawValue]
            .joined(separator: "/")
    }
}

public struct UsageAggregate: Codable, Equatable, Sendable {
    public let key: UsageAggregateKey
    public let runCount: Int
    public let knownInputTokens: Int64
    public let knownOutputTokens: Int64
    public let unknownTokenRuns: Int
    public let knownDurationMs: Int64
    public let unknownDurationRuns: Int
    public let actualCostMinorUnitsByCurrency: [String: Int64]
    public let estimatedCostMinorUnitsByCurrency: [String: Int64]
}

public extension UsageLedger {
    static func aggregate(entries: [DetailedUsageTrace]) -> [UsageAggregate] {
        let grouped = Dictionary(grouping: entries) { entry in
            UsageAggregateKey(
                day: entry.recordedDay,
                personID: entry.personID,
                harness: entry.harness,
                role: entry.role,
                engine: entry.engine,
                executionPlace: entry.executionPlace,
                providerKind: entry.providerKind,
                outcome: entry.outcome
            )
        }
        return grouped.map { key, values in
            UsageAggregate(
                key: key,
                runCount: values.count,
                knownInputTokens: values.compactMap(\.inputTokens).reduce(0, +),
                knownOutputTokens: values.compactMap(\.outputTokens).reduce(0, +),
                unknownTokenRuns: values.filter { $0.inputTokens == nil || $0.outputTokens == nil }.count,
                knownDurationMs: values.compactMap(\.durationMs).reduce(0, +),
                unknownDurationRuns: values.filter { $0.durationMs == nil }.count,
                actualCostMinorUnitsByCurrency: sumCosts(values.compactMap(\.actualCost)),
                estimatedCostMinorUnitsByCurrency: sumCosts(values.compactMap(\.estimatedCost))
            )
        }.sorted { $0.key.sortKey < $1.key.sortKey }
    }

    private static func sumCosts(_ costs: [CostAmount]) -> [String: Int64] {
        costs.reduce(into: [String: Int64]()) { result, cost in
            result[cost.currency, default: 0] += cost.minorUnits
        }
    }
}
