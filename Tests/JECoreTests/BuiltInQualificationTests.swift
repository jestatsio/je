import Foundation
import XCTest
@testable import JECore

final class BuiltInQualificationTests: XCTestCase {
    private var temporary: URL!
    private var stateDirectory: URL!
    private var fakeSecrets: BuiltInQualificationFakeSecretStore!
    private let secret = "synthetic-builtin-qualification-key"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("je-builtin-qualification-tests-" + UUID().uuidString, isDirectory: true)
        stateDirectory = temporary.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        fakeSecrets = BuiltInQualificationFakeSecretStore()
    }

    override func tearDownWithError() throws {
        if let temporary {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    func testQualifyBuiltInRunsExactTasksAndMarksQualified() throws {
        try publish(candidate())
        try saveOllamaProfile()
        let transport = SolverTransport()
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "assignments", "qualify", "fast-builtin-ollama",
             "--mark-qualified"],
            environment: [:],
            recordedDay: "2026-11-04",
            secretStore: fakeSecrets,
            builtInTransport: transport
        )
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("Assignment marked qualified."))
        XCTAssertEqual(transport.callCount, 3)
        XCTAssertFalse((result.stdout + result.stderr).contains(secret))

        let loaded = try AssignmentRegistry(directory: stateDirectory).loadCandidates()
        let qualified = try XCTUnwrap(loaded.first)
        XCTAssertEqual(qualified.qualificationStatus, .qualified)
        let reference = try XCTUnwrap(qualified.qualificationEvidenceReference)
        XCTAssertTrue(reference.hasPrefix("evidence:qualification:"))

        let record = try QualificationEvidenceStore(directory: stateDirectory)
            .load(reference: reference)
        XCTAssertTrue(record.passed)
        XCTAssertEqual(record.taskID, "bounded-builtin-tasks-v1")
        XCTAssertEqual(record.taskResults.count, 3)
        XCTAssertEqual(
            record.taskResults.map(\.taskID),
            ["exact-token-v1", "extract-key-value-v1", "select-matching-line-v1"]
        )
        XCTAssertTrue(record.taskResults.allSatisfy { $0.status == .passed })
        XCTAssertTrue(record.taskResults.allSatisfy { $0.outputSHA256 != nil })
        XCTAssertTrue(record.taskResults.allSatisfy { $0.harnessExitCode == nil })
        XCTAssertEqual(record.checks.first { $0.id == "builtin_route" }?.status, .passed)
        XCTAssertEqual(record.checks.first { $0.id == "connection_profile" }?.detailCode, "loaded")
        XCTAssertNotNil(record.taskOutputSHA256)
        XCTAssertNil(record.harnessExitCode)
        XCTAssertNotNil(record.durationMs)
    }

    func testWrongTaskAnswerStoresFailedEvidenceAndLeavesCandidatePlanned() throws {
        try publish(candidate())
        try saveOllamaProfile()
        let transport = SolverTransport(wrongTaskID: "extract-key-value-v1")
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "assignments", "qualify", "fast-builtin-ollama",
             "--mark-qualified"],
            environment: [:],
            recordedDay: "2026-11-04",
            secretStore: fakeSecrets,
            builtInTransport: transport
        )
        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.stdout.contains("Assignment status unchanged."))
        XCTAssertEqual(transport.callCount, 3)

        let loaded = try AssignmentRegistry(directory: stateDirectory).loadCandidates()
        XCTAssertEqual(loaded.first?.qualificationStatus, .planned)
        XCTAssertNil(loaded.first?.qualificationEvidenceReference)

        let record = try firstEvidenceRecord()
        XCTAssertFalse(record.passed)
        XCTAssertEqual(record.taskResults.filter { $0.status == .passed }.count, 2)
        XCTAssertEqual(
            record.taskResults.first { $0.taskID == "extract-key-value-v1" }?.detailCode,
            "output_mismatch"
        )
    }

    func testUnsupportedBuiltInProtocolFailsBeforeTransport() throws {
        var wrong = candidate()
        wrong = RouteCandidate(
            id: wrong.id,
            role: wrong.role,
            engine: wrong.engine,
            harness: wrong.harness,
            launchMode: wrong.launchMode,
            executionPlace: wrong.executionPlace,
            providerKind: wrong.providerKind,
            modelArtifact: wrong.modelArtifact,
            engineVersion: wrong.engineVersion,
            modelFormat: wrong.modelFormat,
            protocolImplementation: "other-protocol",
            protocolVersion: wrong.protocolVersion,
            configurationDigest: wrong.configurationDigest,
            qualificationStatus: wrong.qualificationStatus,
            allowedPersonIDs: wrong.allowedPersonIDs,
            connectionProfileName: wrong.connectionProfileName,
            publishedPriority: wrong.publishedPriority
        )
        try publish(wrong)
        try saveOllamaProfile()
        let transport = SolverTransport()
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "assignments", "qualify", "fast-builtin-ollama",
             "--mark-qualified"],
            environment: [:],
            recordedDay: "2026-11-04",
            secretStore: fakeSecrets,
            builtInTransport: transport
        )
        XCTAssertEqual(result.code, 2)
        XCTAssertEqual(transport.callCount, 0)
        let record = try firstEvidenceRecord()
        XCTAssertFalse(record.passed)
        XCTAssertEqual(record.checks.first { $0.id == "builtin_route" }?.status, .failed)
        XCTAssertEqual(record.checks.first { $0.id == "builtin_route" }?.detailCode, "unsupported_route")
    }

    private func candidate() -> RouteCandidate {
        RouteCandidate(
            id: "fast-builtin-ollama",
            role: .fast,
            engine: .ollama,
            harness: .builtIn,
            launchMode: .singleStep,
            executionPlace: .personalMachine,
            providerKind: .local,
            modelArtifact: "local/model",
            engineVersion: "0.13.0",
            modelFormat: "ollama",
            protocolImplementation: "ollama-native-chat",
            protocolVersion: "0.13.0",
            configurationDigest: String(repeating: "c", count: 64),
            qualificationStatus: .planned,
            allowedPersonIDs: ["alice"],
            connectionProfileName: "alice",
            publishedPriority: 10
        )
    }

    private func publish(_ candidate: RouteCandidate) throws {
        _ = try AssignmentRegistry(directory: stateDirectory).publish(candidate)
    }

    private func saveOllamaProfile() throws {
        try ProfileStore(directory: stateDirectory).saveNativeOllamaProfile(
            name: "alice",
            endpoint: "https://native.example.test/ollama",
            secret: secret,
            model: "local/model",
            secretStore: fakeSecrets
        )
    }

    private func firstEvidenceRecord() throws -> QualificationEvidenceRecord {
        let directory = stateDirectory.appendingPathComponent("qualification", isDirectory: true)
        let file = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .first
        )
        return try JSONDecoder().decode(
            QualificationEvidenceRecord.self,
            from: Data(contentsOf: file)
        )
    }
}

private final class SolverTransport: BuiltInHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var capturedBodies: [Data] = []
    private let wrongTaskID: String?

    init(wrongTaskID: String? = nil) {
        self.wrongTaskID = wrongTaskID
    }

    var callCount: Int {
        lock.withLock { capturedBodies.count }
    }

    func postJSON(url: URL, bearerToken: String, body: Data) throws -> OllamaHTTPResponse {
        lock.withLock { capturedBodies.append(body) }
        let object = try JSONSerialization.jsonObject(with: body, options: []) as? [String: Any]
        XCTAssertEqual(object?["stream"] as? Bool, false)
        XCTAssertNil(object?["tools"])
        let messages = object?["messages"] as? [[String: Any]]
        let prompt = messages?.last?["content"] as? String ?? ""
        let answer = solve(prompt)
        let data = Data(
            "{\"message\":{\"role\":\"assistant\",\"content\":\(jsonString(answer))},\"done\":true}".utf8
        )
        return OllamaHTTPResponse(statusCode: 200, data: data)
    }

    private func solve(_ prompt: String) -> String {
        if prompt.contains("JE-BUILTIN-QUAL-") {
            if wrongTaskID == "exact-token-v1" { return "wrong" }
            return "JE-BUILTIN-QUAL-7F3A"
        }
        if prompt.contains("answer_key=") {
            if wrongTaskID == "extract-key-value-v1" { return "wrong" }
            let line = prompt.split(separator: "\n").first { $0.hasPrefix("answer_key=") } ?? ""
            return String(line.dropFirst("answer_key=".count))
        }
        if prompt.contains("NEEDLE-42") {
            if wrongTaskID == "select-matching-line-v1" { return "wrong" }
            return prompt.split(separator: "\n")
                .map(String.init)
                .first { $0.contains("NEEDLE-42") && !$0.contains("Reply with only") } ?? ""
        }
        return "unknown"
    }

    private func jsonString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value], options: [])
        let text = String(decoding: data, as: UTF8.self)
        return String(text.dropFirst().dropLast())
    }
}

private final class BuiltInQualificationFakeSecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func setSecret(_ secret: String, reference: String) throws {
        guard SecretReferenceValidator.isValid(reference) else {
            throw SecretStoreError.invalidReference
        }
        lock.withLock { storage[reference] = secret }
    }

    func secret(reference: String) throws -> String? {
        guard SecretReferenceValidator.isValid(reference) else {
            throw SecretStoreError.invalidReference
        }
        return lock.withLock { storage[reference] }
    }

    func deleteSecret(reference: String) throws {
        guard SecretReferenceValidator.isValid(reference) else {
            throw SecretStoreError.invalidReference
        }
        lock.withLock { storage[reference] = nil }
    }
}
