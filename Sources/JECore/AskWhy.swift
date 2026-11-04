import Foundation

public struct RouteExplanation: Codable, Equatable, Sendable {
    public let personID: String
    public let candidateCount: Int
    public let selectedCandidate: RouteCandidate?
    public let decision: RouteDecision
}

public struct AskResult: Codable, Equatable, Sendable {
    public let explanation: RouteExplanation
    public let runID: String?
    public let usageTraceRecorded: Bool
    public let launchStatus: String
    public let harnessExitCode: Int32?
}

public enum AskWhyCommand {
    private static let invalidArguments = "Invalid arguments. Run je --help or the command's --help.\n"

    public static func run(
        command: String,
        arguments: [String],
        stateDirectory: URL,
        environment: [String: String],
        recordedDay: String?,
        runID: String?,
        secretStore: SecretStoring? = nil,
        harnessRunner: HarnessRunning? = nil,
        stdoutSink: CLIOutputSink? = nil
    ) -> CLIResult {
        guard command == "why" || command == "ask" else {
            return invalid()
        }
        guard let parsed = ParsedArguments(arguments: Array(arguments.dropFirst())) else {
            return invalid()
        }
        if command == "ask" && parsed.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return invalid()
        }
        guard let personID = parsed.personID ?? clean(environment["JE_PERSON_ID"]) else {
            return CLIResult(
                code: 2,
                stderr: "Set --person or JE_PERSON_ID so je can show whose route this is.\n"
            )
        }
        guard let role = parsed.role else {
            return CLIResult(
                code: 2,
                stderr: "Set --role fast or --role strong for this route.\n"
            )
        }

        let candidates: [RouteCandidate]
        do {
            candidates = try AssignmentRegistry(directory: stateDirectory).loadCandidates()
        } catch let error as StateStoreError {
            return CLIResult(code: 2, stderr: error.message + "\n")
        } catch {
            return CLIResult(code: 2, stderr: "The assignment registry could not be read.\n")
        }

        let request = RouteRequest(
            personID: personID,
            explicitRole: role,
            neverCloud: parsed.neverCloud,
            cloudAuthorization: parsed.cloudProfileReference.map {
                CloudAuthorization.explicit(profileReference: $0)
            } ?? .none,
            explicitPreferences: RoutePreferences(
                candidateID: parsed.candidateID,
                harness: parsed.harness,
                engine: parsed.engine,
                executionPlace: parsed.executionPlace
            ),
            promptSizeBucket: bucket(for: parsed.prompt)
        )
        let decision = RoutingPolicy().evaluate(request: request, candidates: candidates)
        let selected = candidates.first { $0.id == decision.selectedCandidateID }
        let explanation = RouteExplanation(
            personID: personID,
            candidateCount: candidates.count,
            selectedCandidate: selected,
            decision: decision
        )

        if command == "why" {
            if parsed.json {
                return encode(explanation, code: 0)
            }
            return CLIResult(code: 0, stdout: humanExplanation(explanation))
        }
        return ask(
            explanation: explanation,
            parsed: parsed,
            stateDirectory: stateDirectory,
            environment: environment,
            recordedDay: recordedDay,
            suppliedRunID: runID,
            secretStore: secretStore,
            harnessRunner: harnessRunner,
            stdoutSink: stdoutSink
        )
    }

    private static func ask(
        explanation: RouteExplanation,
        parsed: ParsedArguments,
        stateDirectory: URL,
        environment: [String: String],
        recordedDay: String?,
        suppliedRunID: String?,
        secretStore: SecretStoring?,
        harnessRunner: HarnessRunning?,
        stdoutSink: CLIOutputSink?
    ) -> CLIResult {
        guard let candidate = explanation.selectedCandidate else {
            let result = AskResult(
                explanation: explanation,
                runID: nil,
                usageTraceRecorded: false,
                launchStatus: "no_qualified_route",
                harnessExitCode: nil
            )
            if parsed.json {
                return encode(result, code: 2, stderr: "No qualified route is available for this request.\n")
            }
            return CLIResult(
                code: 2,
                stdout: humanExplanation(explanation),
                stderr: "No qualified route is available for this request.\n"
            )
        }

        let effectiveRunID = suppliedRunID ?? UUID().uuidString.lowercased()
        let started = Date()
        var harnessExitCode: Int32?
        var launchStatus = "failed"
        var launchError: String?
        var emittedRoute = false

        do {
            guard let profileName = candidate.connectionProfileName else {
                throw HarnessLaunchError.connectionProfileRequired
            }
            let store = secretStore ?? ProcessSecretStore.default(environment: environment)
            let profile = try ProfileStore(directory: stateDirectory)
                .loadResolvedProfile(name: profileName, secretStore: store)
            let prepared = try HarnessLaunchPreparer().prepare(
                candidate: candidate,
                profile: profile,
                prompt: parsed.prompt,
                environment: environment,
                executableOverride: parsed.executableOverride
            )
            if !parsed.json, let stdoutSink {
                stdoutSink(humanExplanation(explanation))
                emittedRoute = true
            }
            let runner = harnessRunner ?? ProcessHarnessRunner()
            harnessExitCode = try runner.run(prepared.spec)
            prepared.cleanup()
            launchStatus = harnessExitCode == 0 ? "completed" : "failed"
        } catch let error as HarnessLaunchError {
            launchError = error.message
            switch error {
            case .unsupportedHarness, .catalogLaunchNotPorted:
                launchStatus = "not_ported"
            case .connectionProfileRequired:
                launchStatus = "connection_profile_required"
            case .executableUnavailable:
                launchStatus = "executable_unavailable"
            default:
                launchStatus = "failed"
            }
        } catch let error as StateStoreError {
            launchError = error.message
        } catch {
            launchError = HarnessLaunchError.launchFailed.message
        }

        let durationMs = Int64(max(0, Date().timeIntervalSince(started) * 1000).rounded())
        let trace = DetailedUsageTrace(
            runID: effectiveRunID,
            recordedDay: recordedDay ?? currentUTCDay(),
            personID: explanation.personID,
            harness: candidate.harness,
            launchMode: candidate.launchMode,
            role: candidate.role,
            engine: candidate.engine,
            executionPlace: candidate.executionPlace,
            providerKind: candidate.providerKind,
            assignmentID: candidate.id,
            policyVersion: explanation.decision.policyVersion,
            winningLayer: explanation.decision.winningLayer,
            durationMs: durationMs,
            outcome: launchStatus == "completed" ? .succeeded : .failed
        )
        var recorded = false
        do {
            recorded = try UsageLedgerFile(directory: stateDirectory).append(trace)
        } catch {
            recorded = false
        }

        let result = AskResult(
            explanation: explanation,
            runID: effectiveRunID,
            usageTraceRecorded: recorded,
            launchStatus: launchStatus,
            harnessExitCode: harnessExitCode
        )
        let resultCode = harnessExitCode ?? 2
        let stderr = launchError.map { $0 + "\n" } ?? ""
        if parsed.json {
            return encode(result, code: resultCode, stderr: stderr)
        }
        let routeText = emittedRoute ? "" : humanExplanation(explanation)
        let traceLine = recorded ? "Usage trace: recorded.\n" : "Usage trace: not recorded.\n"
        let launchLine = "Launch: \(launchStatus).\n"
        return CLIResult(
            code: resultCode,
            stdout: routeText + traceLine + launchLine,
            stderr: stderr
        )
    }

    private static func encode<T: Encodable>(
        _ value: T,
        code: Int32,
        stderr: String = ""
    ) -> CLIResult {
        do {
            return CLIResult(code: code, stdout: try StableJSON.encode(value), stderr: stderr)
        } catch {
            return CLIResult(code: 1, stderr: "Could not encode the requested report.\n")
        }
    }

    private static func humanExplanation(_ explanation: RouteExplanation) -> String {
        var lines = [
            "Person: \(explanation.personID)",
            "Role: \(explanation.decision.resolvedRole?.rawValue ?? "unresolved")",
            "Prompt size bucket: \(explanation.decision.promptSizeBucket.rawValue)",
            "Candidates considered: \(explanation.candidateCount)",
            "Policy: \(explanation.decision.policyVersion)",
            "Winning layer: \(explanation.decision.winningLayer)"
        ]
        if let candidate = explanation.selectedCandidate {
            lines.append("Route: \(candidate.id)")
            lines.append("Harness: \(candidate.harness.rawValue) (\(candidate.launchMode.rawValue))")
            lines.append("Engine: \(candidate.engine.rawValue) \(candidate.engineVersion)")
            lines.append("Model: \(candidate.modelArtifact) (\(candidate.modelFormat))")
            lines.append("Place: \(candidate.executionPlace.rawValue)")
            lines.append("Provider: \(candidate.providerKind.rawValue)")
            lines.append("Protocol: \(candidate.protocolImplementation) \(candidate.protocolVersion)")
        } else {
            lines.append("Route: unavailable")
            for result in explanation.decision.filterResults where !result.passed {
                let reasons = result.reasons.map(\.rawValue).joined(separator: ",")
                lines.append("Rejected \(result.candidateID): \(reasons)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func bucket(for prompt: String) -> PromptSizeBucket {
        switch prompt.count {
        case 0:
            return .unknown
        case 1...1000:
            return .small
        case 1001...8000:
            return .medium
        default:
            return .large
        }
    }

    private static func currentUTCDay() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed != value ? nil : trimmed
    }

    private static func invalid() -> CLIResult {
        CLIResult(code: 2, stderr: invalidArguments)
    }

    private struct ParsedArguments {
        var json = false
        var neverCloud = false
        var personID: String?
        var role: ModelRole?
        var harness: HarnessKind?
        var engine: EngineFamily?
        var executionPlace: ExecutionPlace?
        var candidateID: String?
        var cloudProfileReference: String?
        var executableOverride: String?
        var prompt = ""

        init?(arguments: [String]) {
            var index = 0
            var promptParts: [String] = []
            while index < arguments.count {
                let argument = arguments[index]
                if argument == "--" {
                    promptParts.append(contentsOf: arguments.dropFirst(index + 1))
                    break
                }
                if argument == "--json" {
                    json = true
                    index += 1
                    continue
                }
                if argument == "--never-cloud" {
                    neverCloud = true
                    index += 1
                    continue
                }
                if let pair = flagValue(argument: argument, arguments: arguments, index: &index) {
                    guard apply(flag: pair.0, value: pair.1) else { return nil }
                    continue
                }
                if argument.hasPrefix("-") {
                    return nil
                }
                promptParts.append(contentsOf: arguments.dropFirst(index))
                break
            }
            prompt = promptParts.joined(separator: " ")
        }

        private func flagValue(
            argument: String,
            arguments: [String],
            index: inout Int
        ) -> (String, String)? {
            let flags = ["--person", "--role", "--harness", "--engine", "--place", "--candidate", "--cloud-profile", "--executable"]
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

        private mutating func apply(flag: String, value: String) -> Bool {
            guard !value.isEmpty else { return false }
            switch flag {
            case "--person":
                personID = value
            case "--role":
                guard let parsed = ModelRole(rawValue: value) else { return false }
                role = parsed
            case "--harness":
                guard let parsed = HarnessKind(rawValue: value) else { return false }
                harness = parsed
            case "--engine":
                guard let parsed = EngineFamily(rawValue: value) else { return false }
                engine = parsed
            case "--place":
                guard let parsed = ExecutionPlace(rawValue: value) else { return false }
                executionPlace = parsed
            case "--candidate":
                candidateID = value
            case "--cloud-profile":
                cloudProfileReference = value
            case "--executable":
                executableOverride = value
            default:
                return false
            }
            return true
        }
    }
}
