public enum ProviderKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case local
    case cloud
}

public enum PromptSizeBucket: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case unknown
    case small
    case medium
    case large
}

public struct RouteCandidate: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let role: ModelRole
    public let engine: EngineFamily
    public let harness: HarnessKind
    public let launchMode: LaunchMode
    public let executionPlace: ExecutionPlace
    public let providerKind: ProviderKind
    public let modelArtifact: String
    public let engineVersion: String
    public let modelFormat: String
    public let protocolImplementation: String
    public let protocolVersion: String
    public let configurationDigest: String
    public let qualificationStatus: QualificationStatus
    public let allowedPersonIDs: Set<String>
    public let cloudProfileReference: String?
    public let connectionProfileName: String?
    public let qualificationEvidenceReference: String?
    public let available: Bool
    public let publishedPriority: Int

    public init(
        id: String,
        role: ModelRole,
        engine: EngineFamily,
        harness: HarnessKind,
        launchMode: LaunchMode,
        executionPlace: ExecutionPlace,
        providerKind: ProviderKind,
        modelArtifact: String,
        engineVersion: String = "",
        modelFormat: String = "",
        protocolImplementation: String = "",
        protocolVersion: String = "",
        configurationDigest: String = "",
        qualificationStatus: QualificationStatus,
        allowedPersonIDs: Set<String>,
        cloudProfileReference: String? = nil,
        connectionProfileName: String? = nil,
        qualificationEvidenceReference: String? = nil,
        available: Bool = true,
        publishedPriority: Int = 100
    ) {
        self.id = id
        self.role = role
        self.engine = engine
        self.harness = harness
        self.launchMode = launchMode
        self.executionPlace = executionPlace
        self.providerKind = providerKind
        self.modelArtifact = modelArtifact
        self.engineVersion = engineVersion
        self.modelFormat = modelFormat
        self.protocolImplementation = protocolImplementation
        self.protocolVersion = protocolVersion
        self.configurationDigest = configurationDigest
        self.qualificationStatus = qualificationStatus
        self.allowedPersonIDs = allowedPersonIDs
        self.cloudProfileReference = cloudProfileReference
        self.connectionProfileName = connectionProfileName
        self.qualificationEvidenceReference = qualificationEvidenceReference
        self.available = available
        self.publishedPriority = publishedPriority
    }

    public func withQualification(
        status: QualificationStatus,
        evidenceReference: String?
    ) -> RouteCandidate {
        RouteCandidate(
            id: id,
            role: role,
            engine: engine,
            harness: harness,
            launchMode: launchMode,
            executionPlace: executionPlace,
            providerKind: providerKind,
            modelArtifact: modelArtifact,
            engineVersion: engineVersion,
            modelFormat: modelFormat,
            protocolImplementation: protocolImplementation,
            protocolVersion: protocolVersion,
            configurationDigest: configurationDigest,
            qualificationStatus: status,
            allowedPersonIDs: allowedPersonIDs,
            cloudProfileReference: cloudProfileReference,
            connectionProfileName: connectionProfileName,
            qualificationEvidenceReference: evidenceReference,
            available: available,
            publishedPriority: publishedPriority
        )
    }
}

public enum CloudAuthorization: Codable, Equatable, Sendable {
    case none
    case explicit(profileReference: String)
    case configuredDefault(profileReference: String)

    public var profileReference: String? {
        switch self {
        case .none:
            return nil
        case .explicit(let reference), .configuredDefault(let reference):
            return reference
        }
    }
}

public struct RoutePreferences: Codable, Equatable, Sendable {
    public let candidateID: String?
    public let harness: HarnessKind?
    public let engine: EngineFamily?
    public let executionPlace: ExecutionPlace?

    public init(
        candidateID: String? = nil,
        harness: HarnessKind? = nil,
        engine: EngineFamily? = nil,
        executionPlace: ExecutionPlace? = nil
    ) {
        self.candidateID = candidateID
        self.harness = harness
        self.engine = engine
        self.executionPlace = executionPlace
    }

    public var hasSelections: Bool {
        candidateID != nil || harness != nil || engine != nil || executionPlace != nil
    }

    public func matches(_ candidate: RouteCandidate) -> Bool {
        if let candidateID, candidate.id != candidateID { return false }
        if let harness, candidate.harness != harness { return false }
        if let engine, candidate.engine != engine { return false }
        if let executionPlace, candidate.executionPlace != executionPlace { return false }
        return true
    }
}

public struct AdvisoryScore: Codable, Equatable, Sendable {
    public let candidateID: String
    public let score: Double
    public let scorerVersion: String

    public init(candidateID: String, score: Double, scorerVersion: String) {
        self.candidateID = candidateID
        self.score = score
        self.scorerVersion = scorerVersion
    }
}

public struct RouteRequest: Equatable, Sendable {
    public let personID: String
    public let explicitRole: ModelRole?
    public let projectRole: ModelRole?
    public let personDefaultRole: ModelRole?
    public let operatorDefaultRole: ModelRole?
    public let allowedExecutionPlaces: Set<ExecutionPlace>
    public let neverCloud: Bool
    public let cloudAuthorization: CloudAuthorization
    public let explicitPreferences: RoutePreferences
    public let projectPreferences: RoutePreferences
    public let personPreferences: RoutePreferences
    public let operatorPreferences: RoutePreferences
    public let promptSizeBucket: PromptSizeBucket
    public let advisoryScores: [AdvisoryScore]

    public init(
        personID: String,
        explicitRole: ModelRole? = nil,
        projectRole: ModelRole? = nil,
        personDefaultRole: ModelRole? = nil,
        operatorDefaultRole: ModelRole? = nil,
        allowedExecutionPlaces: Set<ExecutionPlace> = Set(ExecutionPlace.allCases),
        neverCloud: Bool = false,
        cloudAuthorization: CloudAuthorization = .none,
        explicitPreferences: RoutePreferences = RoutePreferences(),
        projectPreferences: RoutePreferences = RoutePreferences(),
        personPreferences: RoutePreferences = RoutePreferences(),
        operatorPreferences: RoutePreferences = RoutePreferences(),
        promptSizeBucket: PromptSizeBucket = .unknown,
        advisoryScores: [AdvisoryScore] = []
    ) {
        self.personID = personID
        self.explicitRole = explicitRole
        self.projectRole = projectRole
        self.personDefaultRole = personDefaultRole
        self.operatorDefaultRole = operatorDefaultRole
        self.allowedExecutionPlaces = allowedExecutionPlaces
        self.neverCloud = neverCloud
        self.cloudAuthorization = cloudAuthorization
        self.explicitPreferences = explicitPreferences
        self.projectPreferences = projectPreferences
        self.personPreferences = personPreferences
        self.operatorPreferences = operatorPreferences
        self.promptSizeBucket = promptSizeBucket
        self.advisoryScores = advisoryScores
    }

    public var resolvedRole: ModelRole? {
        explicitRole ?? projectRole ?? personDefaultRole ?? operatorDefaultRole
    }
}

public enum HardFilterReason: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case personNotPermitted = "person_not_permitted"
    case roleMismatch = "role_mismatch"
    case notQualified = "not_qualified"
    case unavailable
    case executionPlaceNotAllowed = "execution_place_not_allowed"
    case neverCloud = "never_cloud"
    case cloudNotAuthorized = "cloud_not_authorized"
}

public struct CandidateFilterResult: Codable, Equatable, Sendable {
    public let candidateID: String
    public let passed: Bool
    public let reasons: [HardFilterReason]
}

public struct RouteDecision: Codable, Equatable, Sendable {
    public let policyVersion: String
    public let resolvedRole: ModelRole?
    public let selectedCandidateID: String?
    public let winningLayer: String
    public let promptSizeBucket: PromptSizeBucket
    public let filterResults: [CandidateFilterResult]
    public let advisoryScores: [AdvisoryScore]
    public let advisoryApplied: Bool
}

public struct RoutingPolicy: Sendable {
    public let version: String

    public init(version: String = "routing-policy-v1") {
        self.version = version
    }

    public func evaluate(
        request: RouteRequest,
        candidates: [RouteCandidate]
    ) -> RouteDecision {
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.publishedPriority != rhs.publishedPriority {
                return lhs.publishedPriority < rhs.publishedPriority
            }
            return lhs.id < rhs.id
        }
        let filterResults = ordered.map { candidate in
            let reasons = hardFilterReasons(candidate: candidate, request: request)
            return CandidateFilterResult(
                candidateID: candidate.id,
                passed: reasons.isEmpty,
                reasons: reasons
            )
        }
        let passedIDs = Set(filterResults.filter(\.passed).map(\.candidateID))
        var remaining = ordered.filter { passedIDs.contains($0.id) }
        var winningLayer = "candidate_priority"

        if request.explicitPreferences.hasSelections {
            let narrowed = remaining.filter { request.explicitPreferences.matches($0) }
            remaining = narrowed
            winningLayer = "explicit"
        }
        let softLayers: [(String, RoutePreferences)] = [
            ("project", request.projectPreferences),
            ("person", request.personPreferences),
            ("operator", request.operatorPreferences)
        ]
        for (layer, preferences) in softLayers where preferences.hasSelections && !remaining.isEmpty {
            let narrowed = remaining.filter { preferences.matches($0) }
            if !narrowed.isEmpty {
                remaining = narrowed
                winningLayer = layer
            }
        }

        return RouteDecision(
            policyVersion: version,
            resolvedRole: request.resolvedRole,
            selectedCandidateID: remaining.first?.id,
            winningLayer: remaining.isEmpty ? "none" : winningLayer,
            promptSizeBucket: request.promptSizeBucket,
            filterResults: filterResults,
            advisoryScores: request.advisoryScores.sorted { $0.candidateID < $1.candidateID },
            advisoryApplied: false
        )
    }

    private func hardFilterReasons(
        candidate: RouteCandidate,
        request: RouteRequest
    ) -> [HardFilterReason] {
        var reasons: [HardFilterReason] = []
        if !candidate.allowedPersonIDs.contains(request.personID) {
            reasons.append(.personNotPermitted)
        }
        if let role = request.resolvedRole, candidate.role != role {
            reasons.append(.roleMismatch)
        }
        if candidate.qualificationStatus != .qualified {
            reasons.append(.notQualified)
        }
        if !candidate.available {
            reasons.append(.unavailable)
        }
        if !request.allowedExecutionPlaces.contains(candidate.executionPlace) {
            reasons.append(.executionPlaceNotAllowed)
        }
        if candidate.providerKind == .cloud {
            if request.neverCloud {
                reasons.append(.neverCloud)
            }
            if request.cloudAuthorization.profileReference == nil
                || request.cloudAuthorization.profileReference != candidate.cloudProfileReference {
                reasons.append(.cloudNotAuthorized)
            }
        }
        return reasons
    }
}
