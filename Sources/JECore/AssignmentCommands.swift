import Foundation

public enum AssignmentCommands {
    private static let invalidArguments = "Invalid arguments. Run je --help or the command's --help.\n"

    public static func run(arguments: [String], stateDirectory: URL) -> CLIResult {
        guard arguments.first == "assignments", arguments.count >= 2 else {
            return invalid()
        }
        let registry = AssignmentRegistry(directory: stateDirectory)
        do {
            switch arguments[1] {
            case "list":
                guard arguments.count == 2 || arguments == ["assignments", "list", "--json"] else {
                    return invalid()
                }
                let candidates = try registry.loadCandidates()
                if arguments.contains("--json") {
                    return encode(candidates)
                }
                let output = candidates.isEmpty
                    ? "No assignments are published.\n"
                    : candidates.map(\.id).joined(separator: "\n") + "\n"
                return CLIResult(code: 0, stdout: output)
            case "show":
                guard arguments.count == 3 else { return invalid() }
                guard let candidate = try registry.loadCandidates().first(where: { $0.id == arguments[2] }) else {
                    return CLIResult(code: 2, stderr: "The requested assignment does not exist.\n")
                }
                return encode(candidate)
            case "validate":
                guard arguments.count == 2 else { return invalid() }
                let candidates = try registry.loadCandidates()
                return CLIResult(
                    code: 0,
                    stdout: "Assignment registry valid: \(candidates.count) assignments.\n"
                )
            case "remove":
                guard arguments.count == 3 else { return invalid() }
                _ = try registry.remove(id: arguments[2])
                return CLIResult(code: 0, stdout: "Removed assignment \(arguments[2]).\n")
            case "add":
                guard let parsed = AddArguments(arguments: Array(arguments.dropFirst(2))) else {
                    return invalid()
                }
                guard parsed.candidate.executionPlace == .personalMachine else {
                    return CLIResult(
                        code: 2,
                        stderr: "Studio assignment publication belongs to the operator host build.\n"
                    )
                }
                let published = try registry.publish(parsed.candidate, replace: parsed.replace)
                return CLIResult(code: 0, stdout: "Published assignment \(published.id).\n")
            default:
                return invalid()
            }
        } catch let error as StateStoreError {
            return CLIResult(code: 2, stderr: error.message + "\n")
        } catch {
            return CLIResult(code: 2, stderr: "The assignment registry could not be updated.\n")
        }
    }

    private static func encode<T: Encodable>(_ value: T) -> CLIResult {
        do {
            return CLIResult(code: 0, stdout: try StableJSON.encode(value))
        } catch {
            return CLIResult(code: 1, stderr: "Could not encode the requested report.\n")
        }
    }

    private static func invalid() -> CLIResult {
        CLIResult(code: 2, stderr: invalidArguments)
    }

    private struct AddArguments {
        let candidate: RouteCandidate
        let replace: Bool

        init?(arguments: [String]) {
            guard let id = arguments.first, !id.hasPrefix("-") else { return nil }
            var role: ModelRole?
            var engine: EngineFamily?
            var harness: HarnessKind?
            var launchMode: LaunchMode?
            var place: ExecutionPlace?
            var provider: ProviderKind?
            var model: String?
            var engineVersion: String?
            var modelFormat: String?
            var protocolImplementation: String?
            var protocolVersion: String?
            var digest: String?
            var status: QualificationStatus?
            var people: [String] = []
            var cloudReference: String?
            var connectionProfile: String?
            var evidence: String?
            var priority = 100
            var available = true
            var replace = false

            var index = 1
            while index < arguments.count {
                let argument = arguments[index]
                if argument == "--replace" {
                    replace = true
                    index += 1
                    continue
                }
                if argument == "--unavailable" {
                    available = false
                    index += 1
                    continue
                }
                guard let pair = Self.flagValue(argument: argument, arguments: arguments, index: &index),
                      !pair.1.isEmpty else {
                    return nil
                }
                switch pair.0 {
                case "--role":
                    guard let value = ModelRole(rawValue: pair.1) else { return nil }
                    role = value
                case "--engine":
                    guard let value = EngineFamily(rawValue: pair.1) else { return nil }
                    engine = value
                case "--harness":
                    guard let value = HarnessKind(rawValue: pair.1) else { return nil }
                    harness = value
                case "--launch-mode":
                    guard let value = LaunchMode(rawValue: pair.1) else { return nil }
                    launchMode = value
                case "--place":
                    guard let value = ExecutionPlace(rawValue: pair.1) else { return nil }
                    place = value
                case "--provider":
                    guard let value = ProviderKind(rawValue: pair.1) else { return nil }
                    provider = value
                case "--model":
                    model = pair.1
                case "--engine-version":
                    engineVersion = pair.1
                case "--model-format":
                    modelFormat = pair.1
                case "--protocol":
                    protocolImplementation = pair.1
                case "--protocol-version":
                    protocolVersion = pair.1
                case "--configuration-digest":
                    digest = pair.1
                case "--status":
                    guard let value = QualificationStatus(rawValue: pair.1) else { return nil }
                    status = value
                case "--person":
                    people.append(contentsOf: pair.1.split(separator: ",").map(String.init))
                case "--cloud-profile":
                    cloudReference = pair.1
                case "--connection-profile":
                    connectionProfile = pair.1
                case "--evidence":
                    evidence = pair.1
                case "--priority":
                    guard let value = Int(pair.1), value >= 0 else { return nil }
                    priority = value
                default:
                    return nil
                }
            }
            guard let role, let engine, let harness, let launchMode, let place, let provider,
                  let model, let engineVersion, let modelFormat, let protocolImplementation,
                  let protocolVersion, let digest, let status, !people.isEmpty else {
                return nil
            }
            if status == .qualified && evidence == nil {
                return nil
            }
            candidate = RouteCandidate(
                id: id,
                role: role,
                engine: engine,
                harness: harness,
                launchMode: launchMode,
                executionPlace: place,
                providerKind: provider,
                modelArtifact: model,
                engineVersion: engineVersion,
                modelFormat: modelFormat,
                protocolImplementation: protocolImplementation,
                protocolVersion: protocolVersion,
                configurationDigest: digest,
                qualificationStatus: status,
                allowedPersonIDs: Set(people),
                cloudProfileReference: cloudReference,
                connectionProfileName: connectionProfile,
                qualificationEvidenceReference: evidence,
                available: available,
                publishedPriority: priority
            )
            self.replace = replace
        }

        private static func flagValue(
            argument: String,
            arguments: [String],
            index: inout Int
        ) -> (String, String)? {
            let flags = [
                "--role", "--engine", "--harness", "--launch-mode", "--place", "--provider",
                "--model", "--engine-version", "--model-format", "--protocol",
                "--protocol-version", "--configuration-digest", "--status", "--person",
                "--cloud-profile", "--connection-profile", "--evidence", "--priority"
            ]
            for flag in flags {
                if argument == flag {
                    guard index + 1 < arguments.count else { return nil }
                    let value = arguments[index + 1]
                    index += 2
                    return (flag, value)
                }
                let prefix = flag + "="
                if argument.hasPrefix(prefix) {
                    index += 1
                    return (flag, String(argument.dropFirst(prefix.count)))
                }
            }
            return nil
        }
    }
}
