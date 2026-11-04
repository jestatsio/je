import Foundation
import XCTest
@testable import JECore

final class AskWhyAssignmentRegistryTests: XCTestCase {
    private var temporary: URL!
    private var stateDirectory: URL!
    private let promptCanary = "synthetic-prompt-canary"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("je-ask-tests-" + UUID().uuidString, isDirectory: true)
        stateDirectory = temporary.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDirectory.path)
    }

    override func tearDownWithError() throws {
        if let temporary {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    func testRegistryBuildsExactCandidateIdentity() throws {
        try writeRegistry(records: [record(id: "fast-codex")])
        let candidates = try AssignmentRegistry(directory: stateDirectory).loadCandidates()
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidate.id, "fast-codex")
        XCTAssertEqual(candidate.engineVersion, "0.40.14")
        XCTAssertEqual(candidate.modelFormat, "gguf")
        XCTAssertEqual(candidate.protocolImplementation, "ollama-native")
        XCTAssertEqual(candidate.protocolVersion, "native-v1")
        XCTAssertEqual(candidate.configurationDigest, String(repeating: "a", count: 64))
        XCTAssertEqual(candidate.allowedPersonIDs, ["alice"])
        XCTAssertEqual(candidate.connectionProfileName, "alice")
        XCTAssertEqual(candidate.qualificationEvidenceReference, "evidence:test")
    }

    func testRegistryRejectsDuplicateOutsideCellAndCloudWithoutReference() throws {
        let duplicate = registryData(records: [record(id: "same"), record(id: "same")])
        XCTAssertThrowsError(try AssignmentRegistry.decodeCandidates(from: duplicate))

        let outsideCell = registryData(records: [
            record(id: "outside", harness: "built_in", launchMode: "interactive")
        ])
        XCTAssertThrowsError(try AssignmentRegistry.decodeCandidates(from: outsideCell))

        let cloud = registryData(records: [
            record(id: "cloud", provider: "cloud", cloudReference: nil)
        ])
        XCTAssertThrowsError(try AssignmentRegistry.decodeCandidates(from: cloud))
    }

    func testWhyWithoutRegistryExplainsUnavailableAndWritesNothing() throws {
        let result = run(["why", "--person", "alice", "--role", "fast", "--json", "--", promptCanary])
        XCTAssertEqual(result.code, 0)
        let explanation = try JSONDecoder().decode(RouteExplanation.self, from: Data(result.stdout.utf8))
        XCTAssertNil(explanation.selectedCandidate)
        XCTAssertNil(explanation.decision.selectedCandidateID)
        XCTAssertFalse((result.stdout + result.stderr).contains(promptCanary))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerURL.path))
    }

    func testWhySelectsQualifiedAssignmentWithoutWritingLedger() throws {
        try writeRegistry(records: [record(id: "fast-codex", status: "qualified")])
        let result = run(["why", "--person", "alice", "--role", "fast", "--", promptCanary])
        XCTAssertEqual(result.code, 0)
        XCTAssertTrue(result.stdout.contains("Route: fast-codex"))
        XCTAssertTrue(result.stdout.contains("Person: alice"))
        XCTAssertFalse((result.stdout + result.stderr).contains(promptCanary))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerURL.path))
    }

    func testAskRecordsFailedTraceOnceAndNeverStoresPrompt() throws {
        try writeRegistry(records: [record(id: "fast-codex", status: "qualified")])
        let arguments = ["ask", "--person", "alice", "--role", "fast", "--json", "--", promptCanary]
        let first = run(arguments)
        XCTAssertEqual(first.code, 2)
        XCTAssertFalse(first.stderr.isEmpty)
        XCTAssertTrue(first.stdout.contains("\"usageTraceRecorded\" : true"))
        XCTAssertFalse((first.stdout + first.stderr).contains(promptCanary))

        let text = try String(contentsOf: ledgerURL, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 1)
        XCTAssertTrue(text.contains("\"outcome\":\"failed\""))
        XCTAssertFalse(text.contains(promptCanary))
        XCTAssertEqual(try permissions(of: ledgerURL), 0o600)
        XCTAssertEqual(try permissions(of: ledgerURL.deletingLastPathComponent()), 0o700)

        let second = run(arguments)
        XCTAssertEqual(second.code, 2)
        XCTAssertTrue(second.stdout.contains("\"usageTraceRecorded\" : false"))
        XCTAssertEqual(try String(contentsOf: ledgerURL, encoding: .utf8).split(separator: "\n").count, 1)
    }

    func testAskWithOnlyPlannedAssignmentRecordsNoTrace() throws {
        try writeRegistry(records: [record(id: "planned", status: "planned")])
        let result = run(["ask", "--person", "alice", "--role", "fast", "--", promptCanary])
        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.stdout.contains("Route: unavailable"))
        XCTAssertTrue(result.stdout.contains("not_qualified"))
        XCTAssertFalse((result.stdout + result.stderr).contains(promptCanary))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerURL.path))
    }

    func testInsecureRegistryIsRejectedWithoutContents() throws {
        let path = try writeRegistry(records: [record(id: "fast-codex", status: "qualified")])
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
        let result = run(["why", "--person", "alice", "--role", "fast", "--", promptCanary])
        XCTAssertEqual(result.code, 2)
        XCTAssertFalse((result.stdout + result.stderr).contains("synthetic-model"))
        XCTAssertFalse((result.stdout + result.stderr).contains(promptCanary))
    }

    private var ledgerURL: URL {
        stateDirectory.appendingPathComponent("usage/detailed.jsonl")
    }

    private func run(_ suffix: [String]) -> CLIResult {
        JECommandLine.run(
            ["--state-dir", stateDirectory.path] + suffix,
            environment: [:],
            recordedDay: "2026-11-04",
            runID: "run-fixed-for-test"
        )
    }

    private func permissions(of url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        return value?.intValue ?? -1
    }

    @discardableResult
    private func writeRegistry(records: [String]) throws -> URL {
        let path = stateDirectory.appendingPathComponent("assignments.json")
        try registryData(records: records).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        return path
    }

    private func registryData(records: [String]) -> Data {
        Data("{\"schema_version\":1,\"assignments\":[\(records.joined(separator: ","))]}".utf8)
    }

    private func record(
        id: String,
        status: String = "qualified",
        harness: String = "codex",
        launchMode: String = "interactive",
        provider: String = "local",
        cloudReference: String? = nil
    ) -> String {
        let digest = String(repeating: "a", count: 64)
        let cloud = cloudReference.map { "\"\($0)\"" } ?? "null"
        return "{\"id\":\"\(id)\",\"role\":\"fast\",\"engine\":\"ollama\""
            + ",\"harness\":\"\(harness)\",\"launch_mode\":\"\(launchMode)\""
            + ",\"execution_place\":\"personal_machine\",\"provider_kind\":\"\(provider)\""
            + ",\"model_artifact\":\"synthetic-model\",\"engine_version\":\"0.40.14\""
            + ",\"model_format\":\"gguf\",\"protocol_implementation\":\"ollama-native\""
            + ",\"protocol_version\":\"native-v1\",\"configuration_digest\":\"\(digest)\""
            + ",\"qualification_status\":\"\(status)\",\"allowed_person_ids\":[\"alice\"]"
            + ",\"cloud_profile_reference\":\(cloud),\"connection_profile_name\":\"alice\""
            + ",\"qualification_evidence_reference\":\"evidence:test\""
            + ",\"available\":true,\"published_priority\":10}"
    }
}
