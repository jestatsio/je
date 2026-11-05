import Foundation

public enum QualificationCheckStatus: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case passed
    case failed
}

public struct QualificationCheck: Codable, Equatable, Sendable {
    public let id: String
    public let status: QualificationCheckStatus
    public let detailCode: String

    public init(id: String, status: QualificationCheckStatus, detailCode: String) {
        self.id = id
        self.status = status
        self.detailCode = detailCode
    }
}

public struct QualificationTaskResult: Codable, Equatable, Sendable {
    public let taskID: String
    public let status: QualificationCheckStatus
    public let detailCode: String
    public let outputSHA256: String?
    public let harnessExitCode: Int32?
    public let durationMs: Int64?

    public init(
        taskID: String,
        status: QualificationCheckStatus,
        detailCode: String,
        outputSHA256: String? = nil,
        harnessExitCode: Int32? = nil,
        durationMs: Int64? = nil
    ) {
        self.taskID = taskID
        self.status = status
        self.detailCode = detailCode
        self.outputSHA256 = outputSHA256
        self.harnessExitCode = harnessExitCode
        self.durationMs = durationMs
    }
}

public struct QualificationEvidenceRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let evidenceReference: String
    public let recordedDay: String
    public let producerVersion: String
    public let candidate: RouteCandidate
    public let checks: [QualificationCheck]
    public let overallResult: String
    public let taskID: String
    public let taskResults: [QualificationTaskResult]
    public let taskOutputSHA256: String?
    public let harnessExitCode: Int32?
    public let durationMs: Int64?

    public init(
        schemaVersion: Int,
        evidenceReference: String,
        recordedDay: String,
        producerVersion: String,
        candidate: RouteCandidate,
        checks: [QualificationCheck],
        overallResult: String,
        taskID: String,
        taskResults: [QualificationTaskResult] = [],
        taskOutputSHA256: String?,
        harnessExitCode: Int32?,
        durationMs: Int64?
    ) {
        self.schemaVersion = schemaVersion
        self.evidenceReference = evidenceReference
        self.recordedDay = recordedDay
        self.producerVersion = producerVersion
        self.candidate = candidate
        self.checks = checks
        self.overallResult = overallResult
        self.taskID = taskID
        self.taskResults = taskResults
        self.taskOutputSHA256 = taskOutputSHA256
        self.harnessExitCode = harnessExitCode
        self.durationMs = durationMs
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case evidenceReference
        case recordedDay
        case producerVersion
        case candidate
        case checks
        case overallResult
        case taskID
        case taskResults
        case taskOutputSHA256
        case harnessExitCode
        case durationMs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        evidenceReference = try container.decode(String.self, forKey: .evidenceReference)
        recordedDay = try container.decode(String.self, forKey: .recordedDay)
        producerVersion = try container.decode(String.self, forKey: .producerVersion)
        candidate = try container.decode(RouteCandidate.self, forKey: .candidate)
        checks = try container.decode([QualificationCheck].self, forKey: .checks)
        overallResult = try container.decode(String.self, forKey: .overallResult)
        taskID = try container.decode(String.self, forKey: .taskID)
        taskResults = try container.decodeIfPresent(
            [QualificationTaskResult].self,
            forKey: .taskResults
        ) ?? []
        taskOutputSHA256 = try container.decodeIfPresent(String.self, forKey: .taskOutputSHA256)
        harnessExitCode = try container.decodeIfPresent(Int32.self, forKey: .harnessExitCode)
        durationMs = try container.decodeIfPresent(Int64.self, forKey: .durationMs)
    }

    public var passed: Bool {
        overallResult == "bounded_task_passed" && checks.allSatisfy { $0.status == .passed }
    }

    public func withReference(_ reference: String) -> QualificationEvidenceRecord {
        QualificationEvidenceRecord(
            schemaVersion: schemaVersion,
            evidenceReference: reference,
            recordedDay: recordedDay,
            producerVersion: producerVersion,
            candidate: candidate,
            checks: checks,
            overallResult: overallResult,
            taskID: taskID,
            taskResults: taskResults,
            taskOutputSHA256: taskOutputSHA256,
            harnessExitCode: harnessExitCode,
            durationMs: durationMs
        )
    }

    public static func reference(for record: QualificationEvidenceRecord) -> String {
        let payload = record.withReference("")
        let data: Data
        if record.schemaVersion == 1 {
            let legacy = ReferencePayloadV1(
                schemaVersion: payload.schemaVersion,
                evidenceReference: payload.evidenceReference,
                recordedDay: payload.recordedDay,
                producerVersion: payload.producerVersion,
                candidate: payload.candidate,
                checks: payload.checks,
                overallResult: payload.overallResult,
                taskID: payload.taskID,
                taskOutputSHA256: payload.taskOutputSHA256,
                harnessExitCode: payload.harnessExitCode,
                durationMs: payload.durationMs
            )
            data = (try? StableJSON.encodeLine(legacy)) ?? Data()
        } else {
            data = (try? StableJSON.encodeLine(payload)) ?? Data()
        }
        return "evidence:qualification:" + SHA256.hexDigest(data)
    }

    private struct ReferencePayloadV1: Encodable {
        let schemaVersion: Int
        let evidenceReference: String
        let recordedDay: String
        let producerVersion: String
        let candidate: RouteCandidate
        let checks: [QualificationCheck]
        let overallResult: String
        let taskID: String
        let taskOutputSHA256: String?
        let harnessExitCode: Int32?
        let durationMs: Int64?
    }
}

public struct QualificationEvidenceStore: Sendable {
    public let directory: URL
    private let stateStore: ProfileStore

    public init(directory: URL) {
        self.directory = directory.standardizedFileURL
        self.stateStore = ProfileStore(directory: directory)
    }

    public var evidenceDirectory: URL {
        directory.appendingPathComponent("qualification", isDirectory: true)
    }

    public func url(for reference: String) throws -> URL {
        evidenceDirectory.appendingPathComponent(try digest(from: reference) + ".json")
    }

    @discardableResult
    public func store(_ record: QualificationEvidenceRecord) throws -> Bool {
        guard record.evidenceReference == QualificationEvidenceRecord.reference(for: record) else {
            throw StateStoreError("The qualification evidence reference does not match its contents.")
        }
        let path = try url(for: record.evidenceReference)
        try stateStore.ensurePrivateDirectory(directory)
        try stateStore.ensurePrivateDirectory(evidenceDirectory)
        if pathExists(path) {
            let existing = try load(reference: record.evidenceReference)
            guard existing == record else {
                throw StateStoreError("The qualification evidence store contains a conflicting record.")
            }
            return false
        }
        let data: Data
        do {
            data = Data(try StableJSON.encode(record).utf8)
        } catch {
            throw StateStoreError("The qualification evidence could not be encoded.")
        }
        let temporary = evidenceDirectory.appendingPathComponent(
            ".pending-\(UUID().uuidString.lowercased())"
        )
        do {
            guard FileManager.default.createFile(
                atPath: temporary.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw StateStoreError("The qualification evidence could not be saved.")
            }
            do {
                try FileManager.default.linkItem(at: temporary, to: path)
            } catch {
                let existing = try load(reference: record.evidenceReference)
                guard existing == record else {
                    throw StateStoreError("The qualification evidence store contains a conflicting record.")
                }
                try? FileManager.default.removeItem(at: temporary)
                return false
            }
            try? FileManager.default.removeItem(at: temporary)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: path.path
            )
            return true
        } catch let error as StateStoreError {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw StateStoreError("The qualification evidence could not be saved.")
        }
    }

    public func load(reference: String) throws -> QualificationEvidenceRecord {
        let path = try url(for: reference)
        guard try stateStore.checkPrivateDirectory(directory),
              try stateStore.checkPrivateDirectory(evidenceDirectory) else {
            throw StateStoreError("The requested qualification evidence does not exist.")
        }
        let data = try stateStore.readPrivateData(path, limit: 256 * 1024)
        let record: QualificationEvidenceRecord
        do {
            record = try JSONDecoder().decode(QualificationEvidenceRecord.self, from: data)
        } catch {
            throw StateStoreError("The qualification evidence is invalid; no contents were displayed.")
        }
        guard record.evidenceReference == reference,
              record.evidenceReference == QualificationEvidenceRecord.reference(for: record) else {
            throw StateStoreError("The qualification evidence reference does not match its contents.")
        }
        return record
    }

    public func validate(reference: String, for candidate: RouteCandidate) throws {
        let record = try load(reference: reference)
        let normalizedRecordCandidate = record.candidate.withQualification(
            status: candidate.qualificationStatus,
            evidenceReference: candidate.qualificationEvidenceReference
        )
        guard record.passed, normalizedRecordCandidate == candidate else {
            throw StateStoreError("The qualification evidence does not match the assignment identity.")
        }
    }

    private func digest(from reference: String) throws -> String {
        let prefix = "evidence:qualification:"
        guard reference.hasPrefix(prefix) else {
            throw StateStoreError("The qualification evidence reference is invalid.")
        }
        let digest = String(reference.dropFirst(prefix.count))
        guard digest.count == 64,
              digest.allSatisfy({ ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") }) else {
            throw StateStoreError("The qualification evidence reference is invalid.")
        }
        return digest
    }

    private func pathExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}

public struct QualificationEvidenceProducer: Sendable {
    public let directory: URL
    private let secretStore: SecretStoring
    private let harnessRunner: HarnessRunning
    private let recordedDay: String
    private let musePhysicalMemoryBytes: UInt64?

    public init(
        directory: URL,
        secretStore: SecretStoring,
        harnessRunner: HarnessRunning,
        recordedDay: String? = nil,
        musePhysicalMemoryBytes: UInt64? = nil
    ) {
        self.directory = directory.standardizedFileURL
        self.secretStore = secretStore
        self.harnessRunner = harnessRunner
        self.recordedDay = recordedDay ?? Self.currentUTCDay()
        self.musePhysicalMemoryBytes = musePhysicalMemoryBytes
    }

    public func produce(
        candidate: RouteCandidate,
        environment: [String: String],
        executableOverride: String?
    ) -> QualificationEvidenceRecord {
        var checks: [QualificationCheck] = []
        var outputDigest: String?
        var harnessExitCode: Int32?
        var durationMs: Int64?

        let supported = SupportMatrix.launchEntries.contains {
            $0.role == candidate.role
                && $0.engine == candidate.engine
                && $0.harness == candidate.harness
                && $0.launchMode == candidate.launchMode
                && $0.executionPlace == candidate.executionPlace
        }
        checks.append(check(
            "support_cell",
            passed: supported,
            detail: supported ? "listed" : "outside_support_matrix"
        ))
        let identityValid = !candidate.id.isEmpty
            && !candidate.modelArtifact.isEmpty
            && !candidate.engineVersion.isEmpty
            && !candidate.modelFormat.isEmpty
            && !candidate.protocolImplementation.isEmpty
            && !candidate.protocolVersion.isEmpty
            && candidate.configurationDigest.count == 64
        checks.append(check(
            "assignment_identity",
            passed: identityValid,
            detail: identityValid ? "exact_identity_present" : "identity_incomplete"
        ))

        let isMuseLocal = HarnessLaunchPreparer.isMuseLocal(candidate)
        var museReport: MuseContractReport?
        if candidate.harness == .muse {
            do {
                let discovery = musePhysicalMemoryBytes.map {
                    MuseContractDiscovery(physicalMemoryBytes: $0)
                } ?? MuseContractDiscovery()
                let report = try discovery.discover(
                    executableOverride: executableOverride,
                    environment: environment
                )
                museReport = report
                let passed = report.localContractStatus == "builtin_glimmer_contract_discovered_not_qualified"
                checks.append(check(
                    "muse_contract",
                    passed: passed,
                    detail: report.localContractStatus
                ))
            } catch {
                checks.append(check("muse_contract", passed: false, detail: "discovery_failed"))
            }
            if !isMuseLocal {
                checks.append(check("connection_profile", passed: false, detail: "not_applicable"))
                checks.append(check("secret_resolution", passed: false, detail: "not_applicable"))
                appendSuiteFailures(to: &checks, launchDetail: "unsupported_harness", taskDetail: "unsupported_harness")
                return record(
                    candidate: candidate,
                    checks: checks,
                    outputDigest: nil,
                    harnessExitCode: nil,
                    durationMs: nil
                )
            }
            checks.append(check("connection_profile", passed: true, detail: "not_required"))
            checks.append(check("secret_resolution", passed: true, detail: "not_required"))
            guard museReport?.localContractStatus == "builtin_glimmer_contract_discovered_not_qualified" else {
                appendSuiteFailures(
                    to: &checks,
                    launchDetail: museReport?.localContractStatus ?? "discovery_failed",
                    taskDetail: museReport?.localContractStatus ?? "discovery_failed"
                )
                return record(
                    candidate: candidate,
                    checks: checks,
                    outputDigest: nil,
                    harnessExitCode: nil,
                    durationMs: nil
                )
            }
        }

        if candidate.harness == .builtIn {
            checks.append(check("connection_profile", passed: false, detail: "not_applicable"))
            checks.append(check("secret_resolution", passed: false, detail: "not_applicable"))
            appendSuiteFailures(to: &checks, launchDetail: "unsupported_harness", taskDetail: "unsupported_harness")
            return record(
                candidate: candidate,
                checks: checks,
                outputDigest: nil,
                harnessExitCode: nil,
                durationMs: nil
            )
        }

        var profile: ResolvedConnectionProfile?
        if !isMuseLocal {
            guard let profileName = candidate.connectionProfileName else {
                checks.append(check("connection_profile", passed: false, detail: "missing"))
                checks.append(check("secret_resolution", passed: false, detail: "missing_profile"))
                appendSuiteFailures(to: &checks, launchDetail: "missing_profile", taskDetail: "missing_profile")
                return record(
                    candidate: candidate,
                    checks: checks,
                    outputDigest: nil,
                    harnessExitCode: nil,
                    durationMs: nil
                )
            }

            do {
                profile = try ProfileStore(directory: directory)
                    .loadResolvedProfile(name: profileName, secretStore: secretStore)
                checks.append(check("connection_profile", passed: true, detail: "loaded"))
                checks.append(check("secret_resolution", passed: true, detail: "resolved_without_recording_secret"))
            } catch {
                checks.append(check("connection_profile", passed: false, detail: "load_failed"))
                checks.append(check("secret_resolution", passed: false, detail: "load_failed"))
                appendSuiteFailures(to: &checks, launchDetail: "load_failed", taskDetail: "load_failed")
                return record(
                    candidate: candidate,
                    checks: checks,
                    outputDigest: nil,
                    harnessExitCode: nil,
                    durationMs: nil
                )
            }
        }

        guard candidate.launchMode == .headless else {
            appendSuiteFailures(to: &checks, launchDetail: "headless_task_required", taskDetail: "headless_task_required")
            return record(
                candidate: candidate,
                checks: checks,
                outputDigest: nil,
                harnessExitCode: nil,
                durationMs: nil
            )
        }

        let suiteRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("je-qualification-" + UUID().uuidString.lowercased(), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: suiteRoot) }

        var taskResults: [QualificationTaskResult] = []
        var taskChecks: [QualificationCheck] = []
        var preparationPassed = true
        var totalDuration: Int64 = 0
        do {
            try FileManager.default.createDirectory(
                at: suiteRoot,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            appendSuiteFailures(to: &checks, launchDetail: "preparation_failed", taskDetail: "preparation_failed")
            return record(
                candidate: candidate,
                checks: checks,
                outputDigest: nil,
                harnessExitCode: nil,
                durationMs: nil
            )
        }

        for definition in taskDefinitions() {
            let taskDirectory = suiteRoot.appendingPathComponent(definition.directoryName, isDirectory: true)
            var taskExit: Int32?
            var taskDuration: Int64?
            var taskOutputDigest: String?
            let taskPassed: Bool
            let taskDetail: String
            do {
                try FileManager.default.createDirectory(
                    at: taskDirectory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                for name in definition.files.keys.sorted() {
                    guard let contents = definition.files[name],
                          FileManager.default.createFile(
                            atPath: taskDirectory.appendingPathComponent(name).path,
                            contents: contents,
                            attributes: [.posixPermissions: 0o600]
                          ) else {
                        throw HarnessLaunchError.preparationFailed
                    }
                }
                let prepared: PreparedHarnessLaunch
                if let profile {
                    prepared = try HarnessLaunchPreparer().prepare(
                        candidate: candidate,
                        profile: profile,
                        prompt: definition.prompt,
                        environment: environment,
                        executableOverride: executableOverride,
                        currentDirectoryURL: taskDirectory
                    )
                } else {
                    prepared = try HarnessLaunchPreparer().prepareMuseLocal(
                        candidate: candidate,
                        prompt: definition.prompt,
                        environment: environment,
                        executableOverride: executableOverride,
                        currentDirectoryURL: taskDirectory,
                        discoveryReport: museReport,
                        physicalMemoryBytes: musePhysicalMemoryBytes
                    )
                }
                let started = Date()
                do {
                    taskExit = try harnessRunner.run(prepared.spec)
                } catch {
                    taskExit = nil
                }
                prepared.cleanup()
                taskDuration = Int64(max(0, Date().timeIntervalSince(started) * 1000).rounded())
                totalDuration += taskDuration ?? 0

                let output = try? Data(contentsOf: taskDirectory.appendingPathComponent(definition.outputName))
                if let output {
                    taskOutputDigest = SHA256.hexDigest(output)
                }
                let outputText = output.flatMap { String(data: $0, encoding: .utf8) }
                let unchanged = definition.unchangedFiles.allSatisfy { name, expected in
                    (try? Data(contentsOf: taskDirectory.appendingPathComponent(name))) == expected
                }
                taskPassed = taskExit == 0
                    && unchanged
                    && (output?.count ?? Int.max) <= 64 * 1024
                    && outputText?.trimmingCharacters(in: .whitespacesAndNewlines)
                        == definition.expectedText.trimmingCharacters(in: .whitespacesAndNewlines)
                if taskPassed {
                    taskDetail = "exact_output_verified"
                } else if taskExit == nil {
                    taskDetail = "launch_failed"
                } else if taskExit != 0 {
                    taskDetail = "nonzero_exit"
                } else {
                    taskDetail = "output_mismatch"
                }
            } catch let error as HarnessLaunchError {
                preparationPassed = false
                taskPassed = false
                taskDetail = detailCode(for: error)
            } catch {
                preparationPassed = false
                taskPassed = false
                taskDetail = "preparation_failed"
            }
            taskResults.append(QualificationTaskResult(
                taskID: definition.id,
                status: taskPassed ? .passed : .failed,
                detailCode: taskDetail,
                outputSHA256: taskOutputDigest,
                harnessExitCode: taskExit,
                durationMs: taskDuration
            ))
            taskChecks.append(check("task:" + definition.id, passed: taskPassed, detail: taskDetail))
        }

        checks.append(check(
            "launch_preparation",
            passed: preparationPassed,
            detail: preparationPassed ? "prepared" : "preparation_failed"
        ))
        checks.append(contentsOf: taskChecks)
        let digests = taskResults.compactMap(\.outputSHA256)
        outputDigest = digests.count == taskResults.count
            ? SHA256.hexDigest(Data(digests.joined(separator: "\n").utf8))
            : nil
        harnessExitCode = aggregateExitCode(taskResults)
        durationMs = totalDuration

        return record(
            candidate: candidate,
            checks: checks,
            taskResults: taskResults,
            outputDigest: outputDigest,
            harnessExitCode: harnessExitCode,
            durationMs: durationMs
        )
    }

    private func record(
        candidate: RouteCandidate,
        checks: [QualificationCheck],
        taskResults: [QualificationTaskResult] = [],
        outputDigest: String?,
        harnessExitCode: Int32?,
        durationMs: Int64?
    ) -> QualificationEvidenceRecord {
        let passed = checks.allSatisfy { $0.status == .passed }
        let draft = QualificationEvidenceRecord(
            schemaVersion: 2,
            evidenceReference: "",
            recordedDay: recordedDay,
            producerVersion: JEVersion.current,
            candidate: candidate,
            checks: checks,
            overallResult: passed ? "bounded_task_passed" : "bounded_task_failed",
            taskID: "bounded-file-tasks-v2",
            taskResults: taskResults,
            taskOutputSHA256: outputDigest,
            harnessExitCode: harnessExitCode,
            durationMs: durationMs
        )
        return draft.withReference(QualificationEvidenceRecord.reference(for: draft))
    }

    private static let suiteTaskIDs = [
        "copy-input-to-output-v1",
        "extract-key-value-v1",
        "select-matching-lines-v1",
        "replace-placeholder-v1"
    ]

    private func appendSuiteFailures(
        to checks: inout [QualificationCheck],
        launchDetail: String,
        taskDetail: String
    ) {
        checks.append(check("launch_preparation", passed: false, detail: launchDetail))
        for id in Self.suiteTaskIDs {
            checks.append(check("task:" + id, passed: false, detail: taskDetail))
        }
    }

    private struct TaskDefinition {
        let id: String
        let directoryName: String
        let prompt: String
        let files: [String: Data]
        let outputName: String
        let expectedText: String
        let unchangedFiles: [String: Data]
    }

    private func taskDefinitions() -> [TaskDefinition] {
        let copyMarker = "JE-QUALIFICATION-" + UUID().uuidString.lowercased()
        let copyInput = Data((copyMarker + "\n").utf8)

        let answerValue = "VALUE-" + UUID().uuidString.lowercased()
        let spec = Data((
            "decoy_a=VALUE-" + UUID().uuidString.lowercased() + "\n"
                + "answer_key=" + answerValue + "\n"
                + "decoy_b=VALUE-" + UUID().uuidString.lowercased() + "\n"
        ).utf8)

        let needle = "NEEDLE-" + UUID().uuidString.lowercased()
        let selectedFirst = needle + " first " + UUID().uuidString.lowercased()
        let selectedSecond = needle + " second " + UUID().uuidString.lowercased()
        let lines = Data([
            "alpha " + UUID().uuidString.lowercased(),
            selectedFirst,
            "beta " + UUID().uuidString.lowercased(),
            selectedSecond,
            "gamma " + UUID().uuidString.lowercased()
        ].joined(separator: "\n").appending("\n").utf8)

        let replacement = "REPLACEMENT-" + UUID().uuidString.lowercased()
        let keepLine = "Keep: " + UUID().uuidString.lowercased()
        let notes = Data(("Status: <TOKEN>\n" + keepLine + "\n").utf8)
        let replacementData = Data((replacement + "\n").utf8)
        let expectedNotes = "Status: " + replacement + "\n" + keepLine

        return [
            TaskDefinition(
                id: Self.suiteTaskIDs[0],
                directoryName: "copy",
                prompt: "Read input.txt and write its exact contents to output.txt. Do not modify input.txt.",
                files: ["input.txt": copyInput],
                outputName: "output.txt",
                expectedText: copyMarker,
                unchangedFiles: ["input.txt": copyInput]
            ),
            TaskDefinition(
                id: Self.suiteTaskIDs[1],
                directoryName: "extract",
                prompt: "Read spec.txt. Write only the value assigned to answer_key, followed by a newline, to answer.txt. Do not modify spec.txt.",
                files: ["spec.txt": spec],
                outputName: "answer.txt",
                expectedText: answerValue,
                unchangedFiles: ["spec.txt": spec]
            ),
            TaskDefinition(
                id: Self.suiteTaskIDs[2],
                directoryName: "select",
                prompt: "Read lines.txt. Write every line containing \"\(needle)\" to selected.txt, preserving order. Do not modify lines.txt.",
                files: ["lines.txt": lines],
                outputName: "selected.txt",
                expectedText: selectedFirst + "\n" + selectedSecond,
                unchangedFiles: ["lines.txt": lines]
            ),
            TaskDefinition(
                id: Self.suiteTaskIDs[3],
                directoryName: "replace",
                prompt: "Replace the exact text <TOKEN> in notes.txt with the trimmed contents of replacement.txt. Save notes.txt and do not modify replacement.txt.",
                files: [
                    "notes.txt": notes,
                    "replacement.txt": replacementData
                ],
                outputName: "notes.txt",
                expectedText: expectedNotes,
                unchangedFiles: ["replacement.txt": replacementData]
            )
        ]
    }

    private func aggregateExitCode(_ results: [QualificationTaskResult]) -> Int32? {
        for result in results {
            guard let code = result.harnessExitCode else { return nil }
            if code != 0 { return code }
        }
        return results.isEmpty ? nil : 0
    }

    private func check(_ id: String, passed: Bool, detail: String) -> QualificationCheck {
        QualificationCheck(
            id: id,
            status: passed ? .passed : .failed,
            detailCode: detail
        )
    }

    private func detailCode(for error: HarnessLaunchError) -> String {
        switch error {
        case .unsupportedHarness:
            return "unsupported_harness"
        case .unsupportedPlace:
            return "unsupported_place"
        case .connectionProfileRequired:
            return "connection_profile_required"
        case .modelMismatch:
            return "model_mismatch"
        case .executableUnavailable:
            return "executable_unavailable"
        case .catalogLaunchNotPorted:
            return "catalog_not_ported"
        case .catalogInvalid:
            return "catalog_invalid"
        case .catalogVersionMismatch:
            return "catalog_version_mismatch"
        case .secretInArguments:
            return "secret_in_arguments"
        case .authenticationFailed:
            return "authentication_failed"
        case .localModelUnavailable:
            return "local_model_unavailable"
        case .localContractUnknown:
            return "local_contract_unknown"
        case .preparationFailed:
            return "preparation_failed"
        case .launchFailed:
            return "launch_failed"
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
}
