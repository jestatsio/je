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
        XCTAssertEqual(record.schemaVersion, 2)
        XCTAssertEqual(record.taskID, "bounded-file-tasks-v2")
        XCTAssertEqual(record.taskResults.count, 4)
        XCTAssertTrue(record.taskResults.allSatisfy { $0.status == .passed })
        XCTAssertTrue(record.taskResults.allSatisfy { $0.outputSHA256 != nil })
        XCTAssertNotNil(record.taskOutputSHA256)
        XCTAssertEqual(record.harnessExitCode, 0)
        XCTAssertTrue(record.evidenceReference.hasPrefix("evidence:qualification:"))

        let file = try XCTUnwrap(evidenceFiles().first)
        XCTAssertEqual(try permissions(of: file), 0o600)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains(secret))
        XCTAssertFalse(text.contains("JE-QUALIFICATION-"))
        XCTAssertFalse(text.contains("NEEDLE-"))
        XCTAssertFalse(text.contains("VALUE-"))
        XCTAssertEqual(runner.specs.count, 4)
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

    func testOneWrongSuiteTaskFailsOverallButOtherTasksStillRun() throws {
        try publish(candidate(id: "fast-codex"))
        let executable = try writeExecutable()
        let runner = CopyTaskRunner(exitCode: 0, wrongSelectedLines: true)

        let result = runQualify(
            id: "fast-codex",
            executable: executable,
            runner: runner,
            markQualified: true
        )
        XCTAssertEqual(result.code, 2)
        XCTAssertEqual(runner.specs.count, 4)
        let record = try XCTUnwrap(evidenceRecords().first)
        XCTAssertFalse(record.passed)
        XCTAssertEqual(record.taskResults.map(\.status), [.passed, .passed, .failed, .passed])
        XCTAssertEqual(record.taskResults[2].detailCode, "output_mismatch")
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
    private let wrongSelectedLines: Bool
    private var capturedSpecs: [HarnessLaunchSpec] = []

    init(exitCode: Int32, wrongSelectedLines: Bool = false) {
        self.exitCode = exitCode
        self.wrongSelectedLines = wrongSelectedLines
    }

    var spec: HarnessLaunchSpec? {
        lock.withLock { capturedSpecs.first }
    }

    var specs: [HarnessLaunchSpec] {
        lock.withLock { capturedSpecs }
    }

    func run(_ spec: HarnessLaunchSpec) throws -> Int32 {
        lock.withLock { capturedSpecs.append(spec) }
        guard exitCode == 0, let directory = spec.currentDirectoryURL else {
            return exitCode
        }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directory.appendingPathComponent("input.txt").path) {
            let input = try Data(contentsOf: directory.appendingPathComponent("input.txt"))
            try input.write(to: directory.appendingPathComponent("output.txt"))
        } else if fileManager.fileExists(atPath: directory.appendingPathComponent("spec.txt").path) {
            let specText = try String(
                contentsOf: directory.appendingPathComponent("spec.txt"),
                encoding: .utf8
            )
            let line = specText.split(separator: "\n").first { $0.hasPrefix("answer_key=") } ?? ""
            let value = line.dropFirst("answer_key=".count)
            try Data((String(value) + "\n").utf8)
                .write(to: directory.appendingPathComponent("answer.txt"))
        } else if fileManager.fileExists(atPath: directory.appendingPathComponent("lines.txt").path) {
            let prompt = spec.arguments.last ?? ""
            let quoted = prompt.split(separator: "\"")
            let needle = quoted.count >= 2 ? String(quoted[1]) : ""
            let lines = try String(
                contentsOf: directory.appendingPathComponent("lines.txt"),
                encoding: .utf8
            ).split(separator: "\n").map(String.init)
            var selected = lines.filter { $0.contains(needle) }
            if wrongSelectedLines, !selected.isEmpty {
                selected.removeLast()
            }
            try Data((selected.joined(separator: "\n") + "\n").utf8)
                .write(to: directory.appendingPathComponent("selected.txt"))
        } else if fileManager.fileExists(atPath: directory.appendingPathComponent("notes.txt").path) {
            let notes = try String(
                contentsOf: directory.appendingPathComponent("notes.txt"),
                encoding: .utf8
            )
            let replacement = try String(
                contentsOf: directory.appendingPathComponent("replacement.txt"),
                encoding: .utf8
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            try Data(notes.replacingOccurrences(of: "<TOKEN>", with: replacement).utf8)
                .write(to: directory.appendingPathComponent("notes.txt"))
        }
        return exitCode
    }
}
