import Foundation

public struct AssignmentRegistry: Sendable {
    public let directory: URL
    private let stateStore: ProfileStore

    public init(directory: URL) {
        self.directory = directory.standardizedFileURL
        self.stateStore = ProfileStore(directory: directory)
    }

    public var registryURL: URL {
        directory.appendingPathComponent("assignments.json")
    }

    public func loadCandidates() throws -> [RouteCandidate] {
        guard try stateStore.checkPrivateDirectory(directory) else {
            return []
        }
        if !FileManager.default.fileExists(atPath: registryURL.path) {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: registryURL.path)) != nil {
                throw StateStoreError("The assignment registry could not be read.")
            }
            return []
        }
        let data = try stateStore.readPrivateData(registryURL, limit: 1024 * 1024)
        return try Self.decodeCandidates(from: data)
    }

    @discardableResult
    public func publish(_ candidate: RouteCandidate, replace: Bool = false) throws -> RouteCandidate {
        var candidates = try loadCandidates()
        if let index = candidates.firstIndex(where: { $0.id == candidate.id }) {
            guard replace else {
                throw StateStoreError("That assignment already exists; use explicit replacement to update it.")
            }
            candidates[index] = candidate
        } else {
            candidates.append(candidate)
        }
        try save(candidates)
        return candidate
    }

    @discardableResult
    public func remove(id: String) throws -> Bool {
        var candidates = try loadCandidates()
        let originalCount = candidates.count
        candidates.removeAll { $0.id == id }
        guard candidates.count != originalCount else {
            throw StateStoreError("The requested assignment does not exist.")
        }
        try save(candidates)
        return true
    }

    public func save(_ candidates: [RouteCandidate]) throws {
        let records = try candidates.map { candidate -> AssignmentRecord in
            let validated = try Self.candidate(
                from: AssignmentRecord(candidate: candidate),
                supportedCells: Set(SupportMatrix.launchEntries.map(CellKey.init))
            )
            return AssignmentRecord(candidate: validated)
        }
        let sorted = records.sorted { lhs, rhs in
            if lhs.publishedPriority != rhs.publishedPriority {
                return lhs.publishedPriority < rhs.publishedPriority
            }
            return lhs.id < rhs.id
        }
        guard Set(sorted.map(\.id)).count == sorted.count else {
            throw StateStoreError("The assignment registry contains a duplicate assignment ID.")
        }
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(AssignmentRegistryDocument(
                schemaVersion: 1,
                assignments: sorted
            )) + Data([10])
        } catch {
            throw StateStoreError("The assignment registry could not be encoded.")
        }
        try writeRegistryAtomically(data)
    }

    private func writeRegistryAtomically(_ data: Data) throws {
        try stateStore.ensurePrivateDirectory(directory)
        if FileManager.default.fileExists(atPath: registryURL.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: registryURL.path)) != nil {
            _ = try stateStore.readPrivateData(registryURL, limit: 1024 * 1024)
        }
        let temporary = directory.appendingPathComponent(".assignments-\(UUID().uuidString.lowercased()).tmp")
        do {
            guard FileManager.default.createFile(
                atPath: temporary.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw StateStoreError("The assignment registry could not be saved.")
            }
            if FileManager.default.fileExists(atPath: registryURL.path) {
                _ = try FileManager.default.replaceItemAt(registryURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: registryURL)
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: registryURL.path
            )
        } catch let error as StateStoreError {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw StateStoreError("The assignment registry could not be saved.")
        }
    }

    public static func decodeCandidates(from data: Data) throws -> [RouteCandidate] {
        let document: AssignmentRegistryDocument
        do {
            document = try JSONDecoder().decode(AssignmentRegistryDocument.self, from: data)
        } catch {
            throw StateStoreError("The assignment registry is invalid; no contents were displayed.")
        }
        guard document.schemaVersion == 1 else {
            throw StateStoreError("Unsupported assignment registry format.")
        }
        let supportedCells = Set(SupportMatrix.launchEntries.map(CellKey.init))
        var seenIDs: Set<String> = []
        var candidates: [RouteCandidate] = []
        for record in document.assignments {
            let candidate = try candidate(from: record, supportedCells: supportedCells)
            guard seenIDs.insert(candidate.id).inserted else {
                throw StateStoreError("The assignment registry contains a duplicate assignment ID.")
            }
            candidates.append(candidate)
        }
        return candidates.sorted { lhs, rhs in
            if lhs.publishedPriority != rhs.publishedPriority {
                return lhs.publishedPriority < rhs.publishedPriority
            }
            return lhs.id < rhs.id
        }
    }

    private static func candidate(
        from record: AssignmentRecord,
        supportedCells: Set<CellKey>
    ) throws -> RouteCandidate {
        for value in [
            record.id, record.modelArtifact, record.engineVersion, record.modelFormat,
            record.protocolImplementation, record.protocolVersion, record.configurationDigest
        ] {
            guard isCleanRequiredText(value) else {
                throw StateStoreError("The assignment registry contains an invalid assignment identity.")
            }
        }
        guard record.configurationDigest.count == 64,
              record.configurationDigest.allSatisfy({ ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") }) else {
            throw StateStoreError("The assignment registry contains an invalid configuration digest.")
        }
        guard record.publishedPriority >= 0,
              !record.allowedPersonIDs.isEmpty,
              record.allowedPersonIDs.allSatisfy(isCleanRequiredText),
              Set(record.allowedPersonIDs).count == record.allowedPersonIDs.count else {
            throw StateStoreError("The assignment registry contains invalid permissions or priority.")
        }
        if let connectionProfileName = record.connectionProfileName,
           !ProfileNameValidator.isValid(connectionProfileName) {
            throw StateStoreError("The assignment registry contains an invalid connection profile name.")
        }
        if let evidence = record.qualificationEvidenceReference,
           !isCleanRequiredText(evidence) {
            throw StateStoreError("The assignment registry contains an invalid qualification evidence reference.")
        }
        if record.qualificationStatus == .qualified && record.qualificationEvidenceReference == nil {
            throw StateStoreError("Qualified assignments require a qualification evidence reference.")
        }
        let cloudReference = record.cloudProfileReference?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch record.providerKind {
        case .local:
            guard cloudReference == nil || cloudReference?.isEmpty == true else {
                throw StateStoreError("Local assignments must not name a cloud profile reference.")
            }
        case .cloud:
            guard let cloudReference, isCleanRequiredText(cloudReference) else {
                throw StateStoreError("Cloud assignments require a cloud profile reference.")
            }
        }
        let candidate = RouteCandidate(
            id: record.id,
            role: record.role,
            engine: record.engine,
            harness: record.harness,
            launchMode: record.launchMode,
            executionPlace: record.executionPlace,
            providerKind: record.providerKind,
            modelArtifact: record.modelArtifact,
            engineVersion: record.engineVersion,
            modelFormat: record.modelFormat,
            protocolImplementation: record.protocolImplementation,
            protocolVersion: record.protocolVersion,
            configurationDigest: record.configurationDigest,
            qualificationStatus: record.qualificationStatus,
            allowedPersonIDs: Set(record.allowedPersonIDs),
            cloudProfileReference: cloudReference?.isEmpty == true ? nil : cloudReference,
            connectionProfileName: record.connectionProfileName,
            qualificationEvidenceReference: record.qualificationEvidenceReference,
            available: record.available,
            publishedPriority: record.publishedPriority
        )
        guard supportedCells.contains(CellKey(candidate: candidate)) else {
            throw StateStoreError("The assignment registry names a cell outside the launch support matrix.")
        }
        return candidate
    }

    private static func isCleanRequiredText(_ value: String) -> Bool {
        !value.isEmpty
            && value.trimmingCharacters(in: .whitespacesAndNewlines) == value
            && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }
}

private struct CellKey: Hashable {
    let role: ModelRole
    let engine: EngineFamily
    let harness: HarnessKind
    let launchMode: LaunchMode
    let executionPlace: ExecutionPlace

    init(_ entry: SupportMatrixEntry) {
        role = entry.role
        engine = entry.engine
        harness = entry.harness
        launchMode = entry.launchMode
        executionPlace = entry.executionPlace
    }

    init(candidate: RouteCandidate) {
        role = candidate.role
        engine = candidate.engine
        harness = candidate.harness
        launchMode = candidate.launchMode
        executionPlace = candidate.executionPlace
    }
}

private struct AssignmentRegistryDocument: Codable {
    let schemaVersion: Int
    let assignments: [AssignmentRecord]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case assignments
    }
}

private struct AssignmentRecord: Codable {
    let id: String
    let role: ModelRole
    let engine: EngineFamily
    let harness: HarnessKind
    let launchMode: LaunchMode
    let executionPlace: ExecutionPlace
    let providerKind: ProviderKind
    let modelArtifact: String
    let engineVersion: String
    let modelFormat: String
    let protocolImplementation: String
    let protocolVersion: String
    let configurationDigest: String
    let qualificationStatus: QualificationStatus
    let allowedPersonIDs: [String]
    let cloudProfileReference: String?
    let connectionProfileName: String?
    let qualificationEvidenceReference: String?
    let available: Bool
    let publishedPriority: Int

    init(candidate: RouteCandidate) {
        id = candidate.id
        role = candidate.role
        engine = candidate.engine
        harness = candidate.harness
        launchMode = candidate.launchMode
        executionPlace = candidate.executionPlace
        providerKind = candidate.providerKind
        modelArtifact = candidate.modelArtifact
        engineVersion = candidate.engineVersion
        modelFormat = candidate.modelFormat
        protocolImplementation = candidate.protocolImplementation
        protocolVersion = candidate.protocolVersion
        configurationDigest = candidate.configurationDigest
        qualificationStatus = candidate.qualificationStatus
        allowedPersonIDs = candidate.allowedPersonIDs.sorted()
        cloudProfileReference = candidate.cloudProfileReference
        connectionProfileName = candidate.connectionProfileName
        qualificationEvidenceReference = candidate.qualificationEvidenceReference
        available = candidate.available
        publishedPriority = candidate.publishedPriority
    }

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case engine
        case harness
        case launchMode = "launch_mode"
        case executionPlace = "execution_place"
        case providerKind = "provider_kind"
        case modelArtifact = "model_artifact"
        case engineVersion = "engine_version"
        case modelFormat = "model_format"
        case protocolImplementation = "protocol_implementation"
        case protocolVersion = "protocol_version"
        case configurationDigest = "configuration_digest"
        case qualificationStatus = "qualification_status"
        case allowedPersonIDs = "allowed_person_ids"
        case cloudProfileReference = "cloud_profile_reference"
        case connectionProfileName = "connection_profile_name"
        case qualificationEvidenceReference = "qualification_evidence_reference"
        case available
        case publishedPriority = "published_priority"
    }
}
