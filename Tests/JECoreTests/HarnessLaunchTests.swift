import Foundation
import XCTest
@testable import JECore

final class HarnessLaunchTests: XCTestCase {
    private var temporary: URL!
    private var stateDirectory: URL!
    private let secret = "synthetic-launch-secret"
    private let prompt = "synthetic launch prompt"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("je-launch-tests-" + UUID().uuidString, isDirectory: true)
        stateDirectory = temporary.appendingPathComponent("state", isDirectory: true)
        let profiles = stateDirectory.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(
            at: profiles,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDirectory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: profiles.path)
    }

    override func tearDownWithError() throws {
        if let temporary {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    func testAskLaunchesCodexWithFakeRunnerAndRecordsSuccess() throws {
        try writeProfile()
        try writeAssignment()
        let executable = try writeExecutable(name: "codex")
        let runner = FakeHarnessRunner(exitCode: 0)

        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "ask", "--person", "alice", "--role", "fast",
             "--executable", executable.path, "--json", "--", prompt],
            environment: ["PATH": temporary.path],
            recordedDay: "2026-11-04",
            runID: "run-launch-test",
            harnessRunner: runner
        )

        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("\"launchStatus\" : \"completed\""))
        XCTAssertTrue(result.stdout.contains("\"harnessExitCode\" : 0"))
        let spec = try XCTUnwrap(runner.spec)
        XCTAssertEqual(spec.environment["JE_STUDIO_API_KEY"], secret)
        XCTAssertNil(spec.environment["JE_GATEWAY_API_KEY"])
        XCTAssertEqual(spec.arguments.last, prompt)
        XCTAssertTrue(spec.arguments.contains("exec"))
        XCTAssertFalse(spec.arguments.joined(separator: "\n").contains(secret))
        XCTAssertFalse((result.stdout + result.stderr).contains(secret))
        XCTAssertFalse((result.stdout + result.stderr).contains(prompt))

        let ledger = try String(contentsOf: ledgerURL, encoding: .utf8)
        XCTAssertTrue(ledger.contains("\"outcome\":\"succeeded\""))
        XCTAssertFalse(ledger.contains(secret))
        XCTAssertFalse(ledger.contains(prompt))
    }

    func testCodexInteractiveSpecMatchesOracleConfiguration() throws {
        let executable = try writeExecutable(name: "codex")
        let prepared = try HarnessLaunchPreparer().prepare(
            candidate: candidate(harness: .codex, mode: .interactive),
            profile: resolvedProfile(),
            prompt: prompt,
            environment: ["PATH": temporary.path, "JE_GATEWAY_API_KEY": "stale"],
            executableOverride: executable.path
        )
        XCTAssertEqual(prepared.spec.arguments.last, prompt)
        XCTAssertTrue(prepared.spec.arguments.contains("model_context_window=32768"))
        XCTAssertTrue(prepared.spec.arguments.contains("model_providers.je_studio.wire_api=\"responses\""))
        XCTAssertFalse(prepared.spec.arguments.contains("exec"))
        XCTAssertNil(prepared.spec.environment["JE_GATEWAY_API_KEY"])
        XCTAssertFalse(prepared.spec.arguments.joined(separator: "\n").contains(secret))
    }

    func testClaudeSpecVerifiesHelperAuthenticationAndCleansSettings() throws {
        let script = """
        #!/bin/sh
        printf '%s' '{"loggedIn":true,"authMethod":"oauth_token","apiProvider":"firstParty"}'
        """
        let executable = try writeExecutable(name: "claude", contents: script)
        let prepared = try HarnessLaunchPreparer().prepare(
            candidate: candidate(harness: .claudeCode, mode: .headless),
            profile: resolvedProfile(),
            prompt: prompt,
            environment: ["PATH": temporary.path, "ANTHROPIC_API_KEY": "stale"],
            executableOverride: executable.path
        )
        XCTAssertEqual(prepared.spec.arguments.suffix(2), ["--print", prompt])
        XCTAssertEqual(prepared.spec.environment["CLAUDE_CODE_OAUTH_TOKEN"], secret)
        XCTAssertNil(prepared.spec.environment["ANTHROPIC_API_KEY"])
        let settingsPath = try XCTUnwrap(prepared.spec.arguments.dropFirst().first)
        let settingsURL = URL(fileURLWithPath: settingsPath)
        XCTAssertEqual(try permissions(of: settingsURL), 0o600)
        XCTAssertFalse(try String(contentsOf: settingsURL, encoding: .utf8).contains(secret))
        let settingsDirectory = settingsURL.deletingLastPathComponent()
        prepared.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsDirectory.path))
    }

    func testUnsupportedAndCatalogBoundRoutesFailClosed() throws {
        let executable = try writeExecutable(name: "codex")
        XCTAssertThrowsError(try HarnessLaunchPreparer().prepare(
            candidate: candidate(harness: .muse, mode: .interactive),
            profile: resolvedProfile(),
            prompt: prompt,
            environment: ["PATH": temporary.path],
            executableOverride: executable.path
        )) { error in
            XCTAssertEqual(error as? HarnessLaunchError, .unsupportedHarness)
        }

        let catalog = CodexCatalogBinding(
            path: "/tmp/catalog.json",
            requiredVersion: "0.166.0",
            sha256: String(repeating: "0", count: 64)
        )
        XCTAssertThrowsError(try HarnessLaunchPreparer().prepare(
            candidate: candidate(harness: .codex, mode: .headless),
            profile: resolvedProfile(catalog: catalog),
            prompt: prompt,
            environment: ["PATH": temporary.path],
            executableOverride: executable.path
        )) { error in
            XCTAssertEqual(error as? HarnessLaunchError, .catalogLaunchNotPorted)
        }
    }

    func testPromptContainingSecretIsRejectedBeforeLaunchSpec() throws {
        let executable = try writeExecutable(name: "codex")
        XCTAssertThrowsError(try HarnessLaunchPreparer().prepare(
            candidate: candidate(harness: .codex, mode: .headless),
            profile: resolvedProfile(),
            prompt: "prefix " + secret,
            environment: ["PATH": temporary.path],
            executableOverride: executable.path
        )) { error in
            XCTAssertEqual(error as? HarnessLaunchError, .secretInArguments)
            XCTAssertFalse(String(describing: error).contains(secret))
        }
    }

    private var ledgerURL: URL {
        stateDirectory.appendingPathComponent("usage/detailed.jsonl")
    }

    private func resolvedProfile(catalog: CodexCatalogBinding? = nil) -> ResolvedConnectionProfile {
        ResolvedConnectionProfile(
            name: "alice",
            endpoint: "https://models.example.test",
            secret: secret,
            model: "synthetic-model",
            contextWindow: 32768,
            codexCatalog: catalog
        )
    }

    private func candidate(harness: HarnessKind, mode: LaunchMode) -> RouteCandidate {
        RouteCandidate(
            id: "fast-\(harness.rawValue)",
            role: .fast,
            engine: .ollama,
            harness: harness,
            launchMode: mode,
            executionPlace: .personalMachine,
            providerKind: .local,
            modelArtifact: "synthetic-model",
            engineVersion: "0.40.14",
            modelFormat: "gguf",
            protocolImplementation: "ollama-native",
            protocolVersion: "native-v1",
            configurationDigest: String(repeating: "a", count: 64),
            qualificationStatus: .qualified,
            allowedPersonIDs: ["alice"],
            connectionProfileName: "alice",
            qualificationEvidenceReference: "evidence:test",
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

    private func writeAssignment() throws {
        let digest = String(repeating: "a", count: 64)
        let record = "{\"id\":\"fast-codex\",\"role\":\"fast\",\"engine\":\"ollama\""
            + ",\"harness\":\"codex\",\"launch_mode\":\"headless\""
            + ",\"execution_place\":\"personal_machine\",\"provider_kind\":\"local\""
            + ",\"model_artifact\":\"synthetic-model\",\"engine_version\":\"0.40.14\""
            + ",\"model_format\":\"gguf\",\"protocol_implementation\":\"ollama-native\""
            + ",\"protocol_version\":\"native-v1\",\"configuration_digest\":\"\(digest)\""
            + ",\"qualification_status\":\"qualified\",\"allowed_person_ids\":[\"alice\"]"
            + ",\"cloud_profile_reference\":null,\"connection_profile_name\":\"alice\""
            + ",\"qualification_evidence_reference\":\"evidence:test\""
            + ",\"available\":true,\"published_priority\":10}"
        let path = stateDirectory.appendingPathComponent("assignments.json")
        try Data("{\"schema_version\":1,\"assignments\":[\(record)]}".utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    @discardableResult
    private func writeExecutable(name: String, contents: String = "#!/bin/sh\nexit 0\n") throws -> URL {
        let path = temporary.appendingPathComponent(name)
        try Data(contents.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    private func permissions(of url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        return value?.intValue ?? -1
    }
}

private final class FakeHarnessRunner: HarnessRunning, @unchecked Sendable {
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
        return exitCode
    }
}
