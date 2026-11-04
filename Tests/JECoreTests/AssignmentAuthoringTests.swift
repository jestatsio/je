import Foundation
import XCTest
@testable import JECore

final class AssignmentAuthoringTests: XCTestCase {
    private var temporary: URL!
    private var stateDirectory: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("je-authoring-tests-" + UUID().uuidString, isDirectory: true)
        stateDirectory = temporary.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    override func tearDownWithError() throws {
        if let temporary {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    func testAddListShowValidateAndRemoveLocalAssignment() throws {
        let added = run(addArguments(id: "fast-codex"))
        XCTAssertEqual(added.code, 0, added.stderr)
        XCTAssertTrue(added.stdout.contains("Published assignment fast-codex"))
        XCTAssertEqual(try permissions(of: registryURL), 0o600)
        XCTAssertEqual(try permissions(of: stateDirectory), 0o700)
        XCTAssertTrue(try temporaryFiles().isEmpty)

        let listed = run(["assignments", "list"])
        XCTAssertEqual(listed.stdout, "fast-codex\n")

        let shown = run(["assignments", "show", "fast-codex"])
        let candidate = try JSONDecoder().decode(RouteCandidate.self, from: Data(shown.stdout.utf8))
        XCTAssertEqual(candidate.connectionProfileName, "alice")
        XCTAssertEqual(candidate.qualificationEvidenceReference, "evidence:bounded-task-1")

        let validated = run(["assignments", "validate"])
        XCTAssertEqual(validated.stdout, "Assignment registry valid: 1 assignments.\n")

        let removed = run(["assignments", "remove", "fast-codex"])
        XCTAssertEqual(removed.code, 0)
        XCTAssertEqual(run(["assignments", "list"]).stdout, "No assignments are published.\n")
    }

    func testDuplicateRequiresReplace() {
        XCTAssertEqual(run(addArguments(id: "same")).code, 0)
        XCTAssertEqual(run(addArguments(id: "same")).code, 2)
        XCTAssertEqual(run(addArguments(id: "same") + ["--replace"]).code, 0)
    }

    func testQualifiedRequiresEvidence() {
        var arguments = addArguments(id: "missing-evidence")
        if let index = arguments.firstIndex(of: "--evidence") {
            arguments.removeSubrange(index...(index + 1))
        }
        let result = run(arguments)
        XCTAssertEqual(result.code, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: registryURL.path))
    }

    func testStudioAssignmentCannotBePublishedByUserArtifact() {
        var arguments = addArguments(id: "studio-one")
        if let index = arguments.firstIndex(of: "--place") {
            arguments[index + 1] = "studio_workspace"
        }
        let result = run(arguments)
        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.stderr.contains("operator host build"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: registryURL.path))
    }

    func testPublishedAssignmentIsSelectableByWhy() throws {
        XCTAssertEqual(run(addArguments(id: "fast-codex")).code, 0)
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "why", "--person", "alice", "--role", "fast", "--", "synthetic prompt"],
            environment: [:]
        )
        XCTAssertEqual(result.code, 0)
        XCTAssertTrue(result.stdout.contains("Route: fast-codex"))
        XCTAssertFalse((result.stdout + result.stderr).contains("synthetic prompt"))
    }

    private var registryURL: URL {
        stateDirectory.appendingPathComponent("assignments.json")
    }

    private func run(_ suffix: [String]) -> CLIResult {
        JECommandLine.run(["--state-dir", stateDirectory.path] + suffix, environment: [:])
    }

    private func addArguments(id: String) -> [String] {
        [
            "assignments", "add", id,
            "--role", "fast",
            "--engine", "ollama",
            "--harness", "codex",
            "--launch-mode", "interactive",
            "--place", "personal_machine",
            "--provider", "local",
            "--model", "synthetic-model",
            "--engine-version", "0.40.14",
            "--model-format", "gguf",
            "--protocol", "ollama-native",
            "--protocol-version", "native-v1",
            "--configuration-digest", String(repeating: "b", count: 64),
            "--status", "qualified",
            "--person", "alice",
            "--connection-profile", "alice",
            "--evidence", "evidence:bounded-task-1",
            "--priority", "10"
        ]
    }

    private func permissions(of url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        return value?.intValue ?? -1
    }

    private func temporaryFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: stateDirectory.path)
            .filter { $0.hasPrefix(".assignments-") }
    }
}
