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

private struct AssignmentRegistryDocument: Decodable {
    let schemaVersion: Int
    let assignments: [AssignmentRecord]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case assignments
    }
}

private struct AssignmentRecord: Decodable {
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
    let available: Bool
    let publishedPriority: Int

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
        case available
        case publishedPriority = "published_priority"
    }
}
