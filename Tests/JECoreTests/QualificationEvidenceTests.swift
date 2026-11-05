import Foundation
import XCTest
@testable import JECore

final class QualificationEvidenceTests: XCTestCase {
    private var temporary: URL!
    private var stateDirectory: URL!
    private let secret = "synthetic-qualification-secret"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("je-qualification-tests-" + UUID().uuidString, isDirectory: true)
        stateDirectory = temporary.appendingPathComponent("state", isDirectory: true)
        let profiles = stateDirectory.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(
            at: profiles,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDirectory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: profiles.path)
        try writeProfile()
    }

    override func tearDownWithError() throws {
        if let temporary {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    func testQualifyStoresPassingEvidenceWithoutMarkingByDefault() throws {
        try publish(candidate(id: "fast-codex"))
        let executable = try writeExecutable()
        let runner = CopyTaskRunner(exitCode: 0)

        let result = runQualify(id: "fast-codex", executable: executable, runner: runner)
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("Qualification: passed"))
        XCTAssertTrue(result.stdout.contains("Assignment status unchanged."))
        XCTAssertFalse((result.stdout + result.stderr).contains(secret))

        let loaded = try AssignmentRegistry(directory: stateDirectory).loadCandidates()
        XCTAssertEqual(loaded.first?.qualificationStatus, .planned)

        let records = try evidenceRecords()
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertTrue(record.passed)
        XCTAssertEqual(record.taskID, "copy-input-to-output-v1")
        XCTAssertNotNil(record.taskOutputSHA256)
        XCTAssertEqual(record.harnessExitCode, 0)
        XCTAssertTrue(record.evidenceReference.hasPrefix("evidence:qualification:"))

        let file = try XCTUnwrap(evidenceFiles().first)
        XCTAssertEqual(try permissions(of: file), 0o600)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains(secret))
        XCTAssertFalse(text.contains("JE-QUALIFICATION-"))
        let spec = try XCTUnwrap(runner.spec)
        XCTAssertNotNil(spec.currentDirectoryURL)
        XCTAssertFalse(spec.arguments.joined(separator: "\n").contains(secret))
    }

    func testMarkQualifiedPublishesValidatedEvidenceReference() throws {
        try publish(candidate(id: "fast-codex"))
        let executable = try writeExecutable()
        let runner = CopyTaskRunner(exitCode: 0)

        let result = runQualify(
            id: "fast-codex",
            executable: executable,
            runner: runner,
            markQualified: true
        )
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("Assignment marked qualified."))

        let loaded = try AssignmentRegistry(directory: stateDirectory).loadCandidates()
        let candidate = try XCTUnwrap(loaded.first)
        XCTAssertEqual(candidate.qualificationStatus, .qualified)
        XCTAssertTrue(candidate.qualificationEvidenceReference?.hasPrefix("evidence:qualification:") == true)
        XCTAssertEqual(try evidenceRecords().count, 1)
    }

    func testFailedTaskStoresFailedEvidenceAndLeavesCandidatePlanned() throws {
        try publish(candidate(id: "fast-codex"))
        let executable = try writeExecutable()
        let runner = CopyTaskRunner(exitCode: 7)

        let result = runQualify(
            id: "fast-codex",
            executable: executable,
            runner: runner,
            markQualified: true
        )
        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.stdout.contains("Qualification: failed"))
        let record = try XCTUnwrap(evidenceRecords().first)
        XCTAssertFalse(record.passed)
        XCTAssertEqual(record.harnessExitCode, 7)
        XCTAssertEqual(record.checks.last?.detailCode, "nonzero_exit")
        XCTAssertEqual(
            try AssignmentRegistry(directory: stateDirectory).loadCandidates().first?.qualificationStatus,
            .planned
        )
    }

    func testInteractiveAssignmentCannotPassHeadlessBoundedTask() throws {
        try publish(candidate(id: "interactive-codex", mode: .interactive))
        let executable = try writeExecutable()
        let runner = CopyTaskRunner(exitCode: 0)
        let result = runQualify(id: "interactive-codex", executable: executable, runner: runner)
        XCTAssertEqual(result.code, 2)
        XCTAssertNil(runner.spec)
        let record = try XCTUnwrap(evidenceRecords().first)
        XCTAssertEqual(record.checks.last?.detailCode, "headless_task_required")
    }

    func testTamperedEvidenceInvalidatesQualifiedAssignmentLoad() throws {
        try publish(candidate(id: "fast-codex"))
        let executable = try writeExecutable()
        let runner = CopyTaskRunner(exitCode: 0)
        XCTAssertEqual(runQualify(
            id: "fast-codex",
            executable: executable,
            runner: runner,
            markQualified: true
        ).code, 0)

        let file = try XCTUnwrap(evidenceFiles().first)
        let original = try String(contentsOf: file, encoding: .utf8)
        try Data(original.replacingOccurrences(
            of: "synthetic-model",
            with: "tampered-model"
        ).utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        XCTAssertThrowsError(try AssignmentRegistry(directory: stateDirectory).loadCandidates())
    }

    private func runQualify(
        id: String,
        executable: URL,
        runner: CopyTaskRunner,
        markQualified: Bool = false
    ) -> CLIResult {
        var arguments = [
            "--state-dir", stateDirectory.path,
            "assignments", "qualify", id,
            "--executable", executable.path
        ]
        if markQualified {
            arguments.append("--mark-qualified")
        }
        return JECommandLine.run(
            arguments,
            environment: ["PATH": temporary.path],
            recordedDay: "2026-11-04",
            harnessRunner: runner
        )
    }

    private func publish(_ candidate: RouteCandidate) throws {
        _ = try AssignmentRegistry(directory: stateDirectory).publish(candidate)
    }

    private func candidate(id: String, mode: LaunchMode = .headless) -> RouteCandidate {
        RouteCandidate(
            id: id,
            role: .fast,
            engine: .ollama,
            harness: .codex,
            launchMode: mode,
            executionPlace: .personalMachine,
            providerKind: .local,
            modelArtifact: "synthetic-model",
            engineVersion: "0.40.14",
            modelFormat: "gguf",
            protocolImplementation: "ollama-native",
            protocolVersion: "native-v1",
            configurationDigest: String(repeating: "a", count: 64),
            qualificationStatus: .planned,
            allowedPersonIDs: ["alice"],
            connectionProfileName: "alice",
            publishedPriority: 10
        )
    }

    private func writeProfile() throws {
        let path = stateDirectory.appendingPathComponent("profiles/alice.json")
        let json = "{\"schema_version\":1,\"endpoint\":\"https://models.example.test/v1\""
            + ",\"api_key\":\"\(secret)\",\"model\":\"synthetic-model\",\"context_window\":32768}"
        try Data(json.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    private func writeExecutable() throws -> URL {
        let path = temporary.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    private func evidenceFiles() throws -> [URL] {
        let directory = stateDirectory.appendingPathComponent("qualification", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func evidenceRecords() throws -> [QualificationEvidenceRecord] {
        try evidenceFiles().map {
            try JSONDecoder().decode(QualificationEvidenceRecord.self, from: Data(contentsOf: $0))
        }
    }

    private func permissions(of url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        return value?.intValue ?? -1
    }
}

private final class CopyTaskRunner: HarnessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let exitCode: Int32
    private var capturedSpec: HarnessLaunchSpec?

    init(exitCode: Int32) {
        self.exitCode = exitCode
    }

    var spec: HarnessLaunchSpec? {
        lock.withLock { capturedSpec }
    }

    func run(_ spec: HarnessLaunchSpec) throws -> Int32 {
        lock.withLock { capturedSpec = spec }
        guard exitCode == 0, let directory = spec.currentDirectoryURL else {
            return exitCode
        }
        let input = try Data(contentsOf: directory.appendingPathComponent("input.txt"))
        try input.write(to: directory.appendingPathComponent("output.txt"))
        return exitCode
    }
}
