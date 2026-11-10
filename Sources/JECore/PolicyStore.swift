import Foundation

/// Versioned routing policy loading (Q5/Q7). The authoritative store is
/// `policy.json` in the je state directory. A repository may carry
/// `.je/policy.json`, but an untrusted repository file may only narrow a
/// route (never-cloud, allowed places). Widening fields apply only from
/// the authoritative store, including its trusted-project entries.
/// Loading never copies secrets into route traces: sources name layers
/// and field names only, plus non-secret references already used by
/// assignments.

public struct PolicyLayer: Equatable, Sendable {
    public var role: ModelRole?
    public var candidateID: String?
    public var harness: HarnessKind?
    public var engine: EngineFamily?
    public var executionPlace: ExecutionPlace?
    public var neverCloud: Bool?
    public var cloudProfile: String?
    public var cloudBudgetCeilingUSD: Double?
    public var cloudContextBoundary: String?
    public var allowedExecutionPlaces: [ExecutionPlace]?
    public var presentFields: [String] = []

    public var preferences: RoutePreferences {
        RoutePreferences(
            candidateID: candidateID,
            harness: harness,
            engine: engine,
            executionPlace: executionPlace
        )
    }
}

public struct TrustedProjectPolicy: Equatable, Sendable {
    public let identity: String
    public let layer: PolicyLayer
}

public struct StatePolicy: Equatable, Sendable {
    public let operatorDefaults: PolicyLayer
    public let personalDefaults: [String: PolicyLayer]
    public let trustedProjects: [TrustedProjectPolicy]
}

public struct PolicySourceRecord: Codable, Equatable, Sendable {
    public let layer: String
    public let source: String
    public let applied: [String]
    public let ignored: [String]

    public init(layer: String, source: String, applied: [String], ignored: [String]) {
        self.layer = layer
        self.source = source
        self.applied = applied
        self.ignored = ignored
    }
}

public struct EffectivePolicy: Equatable, Sendable {
    public let projectRole: ModelRole?
    public let personRole: ModelRole?
    public let operatorRole: ModelRole?
    public let projectPreferences: RoutePreferences
    public let personPreferences: RoutePreferences
    public let operatorPreferences: RoutePreferences
    public let neverCloud: Bool
    public let cloudAuthorization: CloudAuthorization
    public let allowedExecutionPlaces: Set<ExecutionPlace>
    public let sources: [PolicySourceRecord]
}

public struct PolicyLoadResult: Equatable, Sendable {
    public let effective: EffectivePolicy
    public let statePolicyPresent: Bool
    public let projectFileRoot: String?
}

public enum PolicyLoader {
    private static let invalidMessage = "The routing policy file is invalid; no contents were displayed."
    private static let fieldOrder = [
        "role", "candidate_id", "harness", "engine", "execution_place",
        "never_cloud", "cloud_profile", "cloud_budget_ceiling_usd",
        "cloud_context_boundary", "allowed_execution_places"
    ]

    public static func load(
        stateDirectory: URL,
        currentDirectory: URL,
        personID: String,
        explicitNeverCloud: Bool,
        explicitCloudProfile: String?
    ) throws -> PolicyLoadResult {
        let store = ProfileStore(directory: stateDirectory)
        let statePolicy = try loadStatePolicy(store: store, stateDirectory: stateDirectory)
        let canonicalCWD = currentDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let discovered = discoverProjectFile(from: canonicalCWD)
        let projectFileLayer = try discovered.map { try loadProjectFile(at: $0.file) }

        let trustedMatch = statePolicy.flatMap { policy in
            policy.trustedProjects
                .filter { isSameOrAncestor(identity: $0.identity, path: canonicalCWD.path) }
                .max { $0.identity.count < $1.identity.count }
        }
        let discoveredRootTrusted = discovered.map { found in
            trustedMatch.map { canonicalIdentity($0.identity) == found.root.path } ?? false
        } ?? false

        var sources: [PolicySourceRecord] = []
        var projectTrustedLayer: PolicyLayer?
        var projectTrustedSource = ""
        if let trustedMatch, !trustedMatch.layer.presentFields.isEmpty {
            projectTrustedLayer = trustedMatch.layer
            projectTrustedSource = "state:policy.json#trusted_projects"
        } else if discoveredRootTrusted, let projectFileLayer {
            projectTrustedLayer = projectFileLayer
            projectTrustedSource = "project:.je/policy.json"
        }

        let operatorLayer = statePolicy?.operatorDefaults ?? PolicyLayer()
        let personLayer = statePolicy?.personalDefaults[personID] ?? PolicyLayer()

        if !operatorLayer.presentFields.isEmpty {
            var ignored: [String] = []
            if operatorLayer.cloudProfile != nil {
                ignored.append("cloud_profile")
            }
            sources.append(PolicySourceRecord(
                layer: "operator",
                source: "state:policy.json",
                applied: operatorLayer.presentFields.filter { !ignored.contains($0) },
                ignored: ignored
            ))
        }
        if !personLayer.presentFields.isEmpty {
            sources.append(PolicySourceRecord(
                layer: "person",
                source: "state:policy.json",
                applied: personLayer.presentFields,
                ignored: []
            ))
        }
        if let projectTrustedLayer, !projectTrustedLayer.presentFields.isEmpty {
            sources.append(PolicySourceRecord(
                layer: "project",
                source: projectTrustedSource,
                applied: projectTrustedLayer.presentFields,
                ignored: []
            ))
        }
        var untrustedNeverCloud = false
        var untrustedPlaces: [ExecutionPlace]?
        if let projectFileLayer, projectTrustedSource != "project:.je/policy.json" {
            var applied: [String] = []
            if projectFileLayer.neverCloud == true {
                applied.append("never_cloud")
                untrustedNeverCloud = true
            }
            if let places = projectFileLayer.allowedExecutionPlaces {
                applied.append("allowed_execution_places")
                untrustedPlaces = places
            }
            let ignored = projectFileLayer.presentFields.filter { !applied.contains($0) }
            if !projectFileLayer.presentFields.isEmpty {
                sources.append(PolicySourceRecord(
                    layer: "project_untrusted",
                    source: "project:.je/policy.json",
                    applied: applied,
                    ignored: ignored
                ))
            }
        }

        let neverCloud = explicitNeverCloud
            || operatorLayer.neverCloud == true
            || personLayer.neverCloud == true
            || projectTrustedLayer?.neverCloud == true
            || untrustedNeverCloud

        var allowed: Set<ExecutionPlace>?
        for places in [
            operatorLayer.allowedExecutionPlaces,
            personLayer.allowedExecutionPlaces,
            projectTrustedLayer?.allowedExecutionPlaces,
            untrustedPlaces
        ] {
            guard let places else { continue }
            allowed = allowed.map { $0.intersection(places) } ?? Set(places)
        }

        let cloudAuthorization: CloudAuthorization
        if let explicitCloudProfile {
            cloudAuthorization = .explicit(profileReference: explicitCloudProfile)
        } else if let reference = projectTrustedLayer?.cloudProfile {
            cloudAuthorization = .configuredDefault(profileReference: reference)
        } else if let reference = personLayer.cloudProfile {
            cloudAuthorization = .configuredDefault(profileReference: reference)
        } else {
            cloudAuthorization = .none
        }

        return PolicyLoadResult(
            effective: EffectivePolicy(
                projectRole: projectTrustedLayer?.role,
                personRole: personLayer.role,
                operatorRole: operatorLayer.role,
                projectPreferences: projectTrustedLayer?.preferences ?? RoutePreferences(),
                personPreferences: personLayer.preferences,
                operatorPreferences: operatorLayer.preferences,
                neverCloud: neverCloud,
                cloudAuthorization: cloudAuthorization,
                allowedExecutionPlaces: allowed ?? Set(ExecutionPlace.allCases),
                sources: sources
            ),
            statePolicyPresent: statePolicy != nil,
            projectFileRoot: discovered?.root.path
        )
    }

    public static func loadStatePolicy(
        store: ProfileStore,
        stateDirectory: URL
    ) throws -> StatePolicy? {
        let url = stateDirectory.standardizedFileURL.appendingPathComponent("policy.json")
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path)
            && (try? manager.destinationOfSymbolicLink(atPath: url.path)) == nil {
            return nil
        }
        let raw = try store.readPrivateData(url)
        return try parseStatePolicy(raw)
    }

    public static func discoverProjectFile(
        from start: URL
    ) -> (root: URL, file: URL)? {
        // Walk path strings, not URL parent operations. On current
        // Foundation versions, deletingLastPathComponent on an
        // append-built root URL yields "/.." and grows without bound.
        var path = start.standardizedFileURL.resolvingSymlinksInPath().path
        if path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        for _ in 0..<128 {
            let root = URL(fileURLWithPath: path, isDirectory: true)
            let candidate = root
                .appendingPathComponent(".je", isDirectory: true)
                .appendingPathComponent("policy.json")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                return (root, candidate)
            }
            if path == "/" {
                return nil
            }
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path || parent.isEmpty {
                return nil
            }
            path = parent
        }
        return nil
    }

    public static func loadProjectFile(at url: URL) throws -> PolicyLayer {
        let manager = FileManager.default
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else {
            throw StateStoreError(invalidMessage)
        }
        _ = manager
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: 64 * 1024 + 1) ?? Data()
        } catch {
            throw StateStoreError(invalidMessage)
        }
        guard data.count <= 64 * 1024 else {
            throw StateStoreError(invalidMessage)
        }
        let object = try rootObject(data)
        guard Set(object.keys).isSubset(of: Set(["schema_version"] + fieldOrder)),
              exactInt(object["schema_version"]) == 1 else {
            throw StateStoreError(invalidMessage)
        }
        var layerObject = object
        layerObject.removeValue(forKey: "schema_version")
        return try parseLayer(layerObject)
    }

    private static func parseStatePolicy(_ raw: Data) throws -> StatePolicy {
        let object = try rootObject(raw)
        let allowedKeys: Set<String> = [
            "schema_version", "operator_defaults", "personal_defaults", "trusted_projects"
        ]
        guard Set(object.keys).isSubset(of: allowedKeys),
              exactInt(object["schema_version"]) == 1 else {
            throw StateStoreError(invalidMessage)
        }
        var operatorLayer = PolicyLayer()
        if let rawLayer = object["operator_defaults"] {
            guard let layerObject = rawLayer as? [String: Any] else {
                throw StateStoreError(invalidMessage)
            }
            operatorLayer = try parseLayer(layerObject)
        }
        var personal: [String: PolicyLayer] = [:]
        if let rawPersonal = object["personal_defaults"] {
            guard let map = rawPersonal as? [String: Any], map.count <= 64 else {
                throw StateStoreError(invalidMessage)
            }
            for (person, rawLayer) in map {
                guard isCleanIdentifier(person),
                      let layerObject = rawLayer as? [String: Any] else {
                    throw StateStoreError(invalidMessage)
                }
                personal[person] = try parseLayer(layerObject)
            }
        }
        var trusted: [TrustedProjectPolicy] = []
        if let rawTrusted = object["trusted_projects"] {
            guard let list = rawTrusted as? [Any], list.count <= 64 else {
                throw StateStoreError(invalidMessage)
            }
            for item in list {
                guard let entry = item as? [String: Any],
                      Set(entry.keys) == ["identity", "policy"],
                      let identity = entry["identity"] as? String,
                      identity.hasPrefix("/"), isCleanPath(identity),
                      let layerObject = entry["policy"] as? [String: Any] else {
                    throw StateStoreError(invalidMessage)
                }
                trusted.append(TrustedProjectPolicy(
                    identity: canonicalIdentity(identity),
                    layer: try parseLayer(layerObject)
                ))
            }
        }
        return StatePolicy(
            operatorDefaults: operatorLayer,
            personalDefaults: personal,
            trustedProjects: trusted
        )
    }

    private static func parseLayer(_ object: [String: Any]) throws -> PolicyLayer {
        guard Set(object.keys).isSubset(of: Set(fieldOrder)) else {
            throw StateStoreError(invalidMessage)
        }
        var layer = PolicyLayer()
        layer.presentFields = fieldOrder.filter { object[$0] != nil }
        if let raw = object["role"] {
            guard let value = raw as? String, let role = ModelRole(rawValue: value) else {
                throw StateStoreError(invalidMessage)
            }
            layer.role = role
        }
        if let raw = object["candidate_id"] {
            guard let value = raw as? String, isCleanIdentifier(value, allowPathChars: true) else {
                throw StateStoreError(invalidMessage)
            }
            layer.candidateID = value
        }
        if let raw = object["harness"] {
            guard let value = raw as? String, let harness = HarnessKind(rawValue: value) else {
                throw StateStoreError(invalidMessage)
            }
            layer.harness = harness
        }
        if let raw = object["engine"] {
            guard let value = raw as? String, let engine = EngineFamily(rawValue: value) else {
                throw StateStoreError(invalidMessage)
            }
            layer.engine = engine
        }
        if let raw = object["execution_place"] {
            guard let value = raw as? String, let place = ExecutionPlace(rawValue: value) else {
                throw StateStoreError(invalidMessage)
            }
            layer.executionPlace = place
        }
        if let raw = object["never_cloud"] {
            guard let value = exactBool(raw) else {
                throw StateStoreError(invalidMessage)
            }
            layer.neverCloud = value
        }
        if let raw = object["cloud_profile"] {
            guard let value = raw as? String, isCleanIdentifier(value, allowPathChars: true) else {
                throw StateStoreError(invalidMessage)
            }
            layer.cloudProfile = value
        }
        if let raw = object["cloud_budget_ceiling_usd"] {
            guard let number = raw as? NSNumber, !isBool(number),
                  number.doubleValue >= 0, number.doubleValue.isFinite else {
                throw StateStoreError(invalidMessage)
            }
            layer.cloudBudgetCeilingUSD = number.doubleValue
        }
        if let raw = object["cloud_context_boundary"] {
            guard let value = raw as? String, isCleanIdentifier(value, allowPathChars: true) else {
                throw StateStoreError(invalidMessage)
            }
            layer.cloudContextBoundary = value
        }
        if let raw = object["allowed_execution_places"] {
            guard let list = raw as? [Any], !list.isEmpty, list.count <= 2 else {
                throw StateStoreError(invalidMessage)
            }
            var places: [ExecutionPlace] = []
            for item in list {
                guard let value = item as? String, let place = ExecutionPlace(rawValue: value),
                      !places.contains(place) else {
                    throw StateStoreError(invalidMessage)
                }
                places.append(place)
            }
            layer.allowedExecutionPlaces = places
        }
        return layer
    }

    private static func rootObject(_ raw: Data) throws -> [String: Any] {
        guard !hasDuplicateTopLevelKeys(raw),
              let object = try? JSONSerialization.jsonObject(with: raw, options: []),
              let value = object as? [String: Any] else {
            throw StateStoreError(invalidMessage)
        }
        return value
    }

    private static func canonicalIdentity(_ identity: String) -> String {
        URL(fileURLWithPath: (identity as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static func isSameOrAncestor(identity: String, path: String) -> Bool {
        path == identity || path.hasPrefix(identity.hasSuffix("/") ? identity : identity + "/")
    }

    private static func isCleanIdentifier(_ value: String, allowPathChars: Bool = false) -> Bool {
        guard (1...128).contains(value.count),
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !value.contains(where: \.isWhitespace) else {
            return false
        }
        if allowPathChars {
            return true
        }
        return value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (65...90).contains($0.value)
                || (97...122).contains($0.value) || $0 == "." || $0 == "_" || $0 == "-"
        }
    }

    private static func isCleanPath(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 4096
            && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
            && !value.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    private static func isBool(_ number: NSNumber) -> Bool {
        let type = String(cString: number.objCType)
        return type == "c" || type == "B"
    }

    private static func exactBool(_ raw: Any) -> Bool? {
        guard let number = raw as? NSNumber, isBool(number) else { return nil }
        return number.boolValue
    }

    private static func exactInt(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber, !isBool(number) else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, double >= Double(Int.min), double <= Double(Int.max) else {
            return nil
        }
        return number.intValue
    }

    private static func hasDuplicateTopLevelKeys(_ raw: Data) -> Bool {
        guard let text = String(data: raw, encoding: .utf8) else { return false }
        var keys: Set<String> = []
        var depth = 0
        var inString = false
        var escaped = false
        var expectingKey = false
        var currentIsKey = false
        var current = ""
        for character in text {
            if inString {
                current.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                    if currentIsKey && !keys.insert(current).inserted {
                        return true
                    }
                    current = ""
                    currentIsKey = false
                }
                continue
            }
            switch character {
            case "\"":
                inString = true
                current = "\""
                currentIsKey = expectingKey && depth == 1
            case "{", "[":
                depth += 1
                if character == "{" && depth == 1 { expectingKey = true }
            case "}", "]":
                depth = max(0, depth - 1)
                expectingKey = false
            case ",":
                if depth == 1 { expectingKey = true }
            case ":":
                if depth == 1 { expectingKey = false }
            default:
                break
            }
        }
        return false
    }
}
