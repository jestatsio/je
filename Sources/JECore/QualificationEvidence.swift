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

public struct QualificationEvidenceRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let evidenceReference: String
    public let recordedDay: String
    public let producerVersion: String
    public let candidate: RouteCandidate
    public let checks: [QualificationCheck]
    public let overallResult: String
    public let taskID: String
    public let taskOutputSHA256: String?
    public let harnessExitCode: Int32?
    public let durationMs: Int64?

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
            taskOutputSHA256: taskOutputSHA256,
            harnessExitCode: harnessExitCode,
            durationMs: durationMs
        )
    }

    public static func reference(for record: QualificationEvidenceRecord) -> String {
        let payload = record.withReference("")
        let data = (try? StableJSON.encodeLine(payload)) ?? Data()
        return "evidence:qualification:" + SHA256.hexDigest(data)
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

    public init(
        directory: URL,
        secretStore: SecretStoring,
        harnessRunner: HarnessRunning,
        recordedDay: String? = nil
    ) {
        self.directory = directory.standardizedFileURL
        self.secretStore = secretStore
        self.harnessRunner = harnessRunner
        self.recordedDay = recordedDay ?? Self.currentUTCDay()
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

        if candidate.harness == .muse {
            do {
                let report = try MuseContractDiscovery().discover(
                    executableOverride: executableOverride,
                    environment: environment
                )
                let passed = report.localContractStatus == "builtin_glimmer_contract_discovered_not_qualified"
                checks.append(check(
                    "muse_contract",
                    passed: passed,
                    detail: report.localContractStatus
                ))
            } catch {
                checks.append(check("muse_contract", passed: false, detail: "discovery_failed"))
            }
            checks.append(check("connection_profile", passed: false, detail: "not_applicable"))
            checks.append(check("secret_resolution", passed: false, detail: "not_applicable"))
            checks.append(check("launch_preparation", passed: false, detail: "unsupported_harness"))
            checks.append(check("bounded_task", passed: false, detail: "unsupported_harness"))
            return record(
                candidate: candidate,
                checks: checks,
                outputDigest: nil,
                harnessExitCode: nil,
                durationMs: nil
            )
        }

        if candidate.harness == .builtIn {
            checks.append(check("connection_profile", passed: false, detail: "not_applicable"))
            checks.append(check("secret_resolution", passed: false, detail: "not_applicable"))
            checks.append(check("launch_preparation", passed: false, detail: "unsupported_harness"))
            checks.append(check("bounded_task", passed: false, detail: "unsupported_harness"))
            return record(
                candidate: candidate,
                checks: checks,
                outputDigest: nil,
                harnessExitCode: nil,
                durationMs: nil
            )
        }

        guard let profileName = candidate.connectionProfileName else {
            checks.append(check("connection_profile", passed: false, detail: "missing"))
            checks.append(check("secret_resolution", passed: false, detail: "missing_profile"))
            checks.append(check("launch_preparation", passed: false, detail: "missing_profile"))
            checks.append(check("bounded_task", passed: false, detail: "missing_profile"))
            return record(
                candidate: candidate,
                checks: checks,
                outputDigest: nil,
                harnessExitCode: nil,
                durationMs: nil
            )
        }

        let profile: ResolvedConnectionProfile
        do {
            profile = try ProfileStore(directory: directory)
                .loadResolvedProfile(name: profileName, secretStore: secretStore)
            checks.append(check("connection_profile", passed: true, detail: "loaded"))
            checks.append(check("secret_resolution", passed: true, detail: "resolved_without_recording_secret"))
        } catch {
            checks.append(check("connection_profile", passed: false, detail: "load_failed"))
            checks.append(check("secret_resolution", passed: false, detail: "load_failed"))
            checks.append(check("launch_preparation", passed: false, detail: "load_failed"))
            checks.append(check("bounded_task", passed: false, detail: "load_failed"))
            return record(
                candidate: candidate,
                checks: checks,
                outputDigest: nil,
                harnessExitCode: nil,
                durationMs: nil
            )
        }

        guard candidate.launchMode == .headless else {
            checks.append(check("launch_preparation", passed: false, detail: "headless_task_required"))
            checks.append(check("bounded_task", passed: false, detail: "headless_task_required"))
            return record(
                candidate: candidate,
                checks: checks,
                outputDigest: nil,
                harnessExitCode: nil,
                durationMs: nil
            )
        }

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("je-qualification-" + UUID().uuidString.lowercased(), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        do {
            try FileManager.default.createDirectory(
                at: workspace,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let marker = "JE-QUALIFICATION-" + UUID().uuidString.lowercased()
            let input = workspace.appendingPathComponent("input.txt")
            guard FileManager.default.createFile(
                atPath: input.path,
                contents: Data((marker + "\n").utf8),
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw HarnessLaunchError.preparationFailed
            }
            let prepared = try HarnessLaunchPreparer().prepare(
                candidate: candidate,
                profile: profile,
                prompt: "Read input.txt and write its exact contents to output.txt. Do not modify input.txt.",
                environment: environment,
                executableOverride: executableOverride,
                currentDirectoryURL: workspace
            )
            checks.append(check("launch_preparation", passed: true, detail: "prepared"))
            let started = Date()
            do {
                harnessExitCode = try harnessRunner.run(prepared.spec)
            } catch {
                harnessExitCode = nil
            }
            prepared.cleanup()
            durationMs = Int64(max(0, Date().timeIntervalSince(started) * 1000).rounded())

            let outputURL = workspace.appendingPathComponent("output.txt")
            let inputAfter = try? Data(contentsOf: input)
            let output = try? Data(contentsOf: outputURL)
            if let output {
                outputDigest = SHA256.hexDigest(output)
            }
            let outputText = output.flatMap { String(data: $0, encoding: .utf8) }
            let taskPassed = harnessExitCode == 0
                && inputAfter == Data((marker + "\n").utf8)
                && (output?.count ?? Int.max) <= 64 * 1024
                && outputText?.trimmingCharacters(in: .whitespacesAndNewlines) == marker
            let detail: String
            if taskPassed {
                detail = "exact_output_verified"
            } else if harnessExitCode == nil {
                detail = "launch_failed"
            } else if harnessExitCode != 0 {
                detail = "nonzero_exit"
            } else {
                detail = "output_mismatch"
            }
            checks.append(check("bounded_task", passed: taskPassed, detail: detail))
        } catch let error as HarnessLaunchError {
            checks.append(check(
                "launch_preparation",
                passed: false,
                detail: detailCode(for: error)
            ))
            checks.append(check("bounded_task", passed: false, detail: "preparation_failed"))
        } catch {
            checks.append(check("launch_preparation", passed: false, detail: "preparation_failed"))
            checks.append(check("bounded_task", passed: false, detail: "preparation_failed"))
        }

        return record(
            candidate: candidate,
            checks: checks,
            outputDigest: outputDigest,
            harnessExitCode: harnessExitCode,
            durationMs: durationMs
        )
    }

    private func record(
        candidate: RouteCandidate,
        checks: [QualificationCheck],
        outputDigest: String?,
        harnessExitCode: Int32?,
        durationMs: Int64?
    ) -> QualificationEvidenceRecord {
        let passed = checks.allSatisfy { $0.status == .passed }
        let draft = QualificationEvidenceRecord(
            schemaVersion: 1,
            evidenceReference: "",
            recordedDay: recordedDay,
            producerVersion: JEVersion.current,
            candidate: candidate,
            checks: checks,
            overallResult: passed ? "bounded_task_passed" : "bounded_task_failed",
            taskID: "copy-input-to-output-v1",
            taskOutputSHA256: outputDigest,
            harnessExitCode: harnessExitCode,
            durationMs: durationMs
        )
        return draft.withReference(QualificationEvidenceRecord.reference(for: draft))
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
