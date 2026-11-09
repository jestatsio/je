import Foundation
import XCTest
@testable import JECore

final class RunCommandTests: XCTestCase {
    private var temporary: URL!
    private var stateDirectory: URL!
    private var binDirectory: URL!
    private var fakeSecrets: RunFakeSecretStore!
    private let secret = "synthetic-run-key"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("je-run-tests-" + UUID().uuidString, isDirectory: true)
        stateDirectory = temporary.appendingPathComponent("state", isDirectory: true)
        binDirectory = temporary.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: binDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        fakeSecrets = RunFakeSecretStore()
    }

    override func tearDownWithError() throws {
        if let temporary {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    func testGenericCommandGetsModelEnvironmentAndPreservesStatus() throws {
        try saveNativeProfile()
        let tool = try makeExecutable(named: "agent-tool")
        let runner = RunCapturingRunner()
        runner.exitCode = 9
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "run", "--profile", "alice",
             "--", "agent-tool", "--model", "local-fast"],
            environment: [
                "PATH": binDirectory.path,
                "OPENAI_API_KEY": "stale-value",
                "JE_RUN_TEST_MARKER": "kept"
            ],
            secretStore: fakeSecrets,
            harnessRunner: runner
        )
        XCTAssertEqual(result.code, 9, result.stderr)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")
        let spec = try XCTUnwrap(runner.spec)
        XCTAssertEqual(spec.executableURL.path, tool)
        XCTAssertEqual(spec.arguments, ["--model", "local-fast"])
        XCTAssertEqual(spec.environment["OPENAI_BASE_URL"], "https://models.example.test/v1")
        XCTAssertEqual(spec.environment["OPENAI_API_KEY"], secret)
        XCTAssertEqual(spec.environment["OPENAI_MODEL"], "local-fast")
        XCTAssertEqual(spec.environment["JE_RUN_TEST_MARKER"], "kept")
        XCTAssertFalse(spec.arguments.contains { $0.contains(secret) })
        XCTAssertFalse(spec.executableURL.path.contains(secret))
    }

    func testGenericModelOverrideAppliesForSessionOnly() throws {
        try saveNativeProfile()
        _ = try makeExecutable(named: "agent-tool")
        let runner = RunCapturingRunner()
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "run", "--profile", "alice",
             "--model", "local-strong", "--", "agent-tool"],
            environment: ["PATH": binDirectory.path],
            secretStore: fakeSecrets,
            harnessRunner: runner
        )
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertEqual(runner.spec?.environment["OPENAI_MODEL"], "local-strong")
        let stored = try ProfileStore(directory: stateDirectory)
            .loadPublicProfile(name: "alice")
        XCTAssertEqual(stored.model, "local-fast")
        XCTAssertEqual(stored.contextWindow, 32768)
    }

    func testEmptyModelOverrideIsIgnoredLikeOracle() throws {
        try saveNativeProfile()
        _ = try makeExecutable(named: "agent-tool")
        let runner = RunCapturingRunner()
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "run", "--profile", "alice",
             "--model=", "--", "agent-tool"],
            environment: ["PATH": binDirectory.path],
            secretStore: fakeSecrets,
            harnessRunner: runner
        )
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertEqual(runner.spec?.environment["OPENAI_MODEL"], "local-fast")
    }

    func testGenericCommandRequiresACommandAfterProfileLoad() throws {
        try saveNativeProfile()
        let runner = RunCapturingRunner()
        for tail in [["run", "--profile", "alice", "--"], ["run", "--profile", "alice"]] {
            let result = JECommandLine.run(
                ["--state-dir", stateDirectory.path] + tail,
                environment: [:],
                secretStore: fakeSecrets,
                harnessRunner: runner
            )
            XCTAssertEqual(result.code, 2, tail.description)
            XCTAssertEqual(result.stderr, "Specify a command after --.\n", tail.description)
            XCTAssertEqual(result.stdout, "")
        }
        XCTAssertNil(runner.spec)

        let missing = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "run", "--profile", "nope", "--"],
            environment: [:],
            secretStore: fakeSecrets,
            harnessRunner: runner
        )
        XCTAssertEqual(missing.code, 2)
        XCTAssertTrue(missing.stderr.contains("The requested private file does not exist."))
        XCTAssertFalse(missing.stderr.contains("Specify a command"))
        XCTAssertNil(runner.spec)
    }

    func testSecretInCommandArgumentsIsRejectedWithoutEcho() throws {
        try saveNativeProfile()
        _ = try makeExecutable(named: "agent-tool")
        let runner = RunCapturingRunner()
        for tail in [["agent-tool", "--key", secret], [secret]] {
            let result = JECommandLine.run(
                ["--state-dir", stateDirectory.path, "run", "--profile", "alice", "--"] + tail,
                environment: ["PATH": binDirectory.path],
                secretStore: fakeSecrets,
                harnessRunner: runner
            )
            XCTAssertEqual(result.code, 2)
            XCTAssertEqual(
                result.stderr,
                "Do not place the gateway credential in command-line arguments.\n")
            XCTAssertFalse((result.stdout + result.stderr).contains(secret))
        }
        XCTAssertNil(runner.spec)
    }

    func testSecretInResolvedExecutablePathIsRejected() throws {
        try saveNativeProfile()
        let secretBin = temporary.appendingPathComponent(secret, isDirectory: true)
        try FileManager.default.createDirectory(
            at: secretBin, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let tool = secretBin.appendingPathComponent("agent-tool")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: tool)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let runner = RunCapturingRunner()
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "run", "--profile", "alice",
             "--", "agent-tool"],
            environment: ["PATH": secretBin.path],
            secretStore: fakeSecrets,
            harnessRunner: runner
        )
        XCTAssertEqual(result.code, 2)
        XCTAssertEqual(
            result.stderr,
            "Do not place the gateway credential in the executable path.\n")
        XCTAssertFalse((result.stdout + result.stderr).contains(secret))
        XCTAssertNil(runner.spec)
    }

    func testNulInCommandArgumentsIsRejected() throws {
        try saveNativeProfile()
        _ = try makeExecutable(named: "agent-tool")
        let runner = RunCapturingRunner()
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "run", "--profile", "alice",
             "--", "agent-tool", "bad\0argument"],
            environment: ["PATH": binDirectory.path],
            secretStore: fakeSecrets,
            harnessRunner: runner
        )
        XCTAssertEqual(result.code, 2)
        XCTAssertEqual(
            result.stderr,
            "The operation failed; no credential or response contents were displayed.\n")
        XCTAssertNil(runner.spec)
    }

    func testInvalidModelOverrideIsRejectedWithoutEcho() throws {
        try saveNativeProfile()
        _ = try makeExecutable(named: "agent-tool")
        let runner = RunCapturingRunner()
        let cases: [(String, String)] = [
            (" local-strong", "A nonempty model name without control characters is required."),
            ("local-strong ", "A nonempty model name without control characters is required."),
            (secret, "Keep gateway credentials separate from the endpoint and model name.")
        ]
        for (model, message) in cases {
            let result = JECommandLine.run(
                ["--state-dir", stateDirectory.path, "run", "--profile", "alice",
                 "--model", model, "--", "agent-tool"],
                environment: ["PATH": binDirectory.path],
                secretStore: fakeSecrets,
                harnessRunner: runner
            )
            XCTAssertEqual(result.code, 2, model)
            XCTAssertEqual(result.stderr, message + "\n", model)
            XCTAssertFalse((result.stdout + result.stderr).contains(secret), model)
        }
        XCTAssertNil(runner.spec)
    }

    func testInvalidArgumentShapesNeverRun() throws {
        try saveNativeProfile()
        _ = try makeExecutable(named: "agent-tool")
        let runner = RunCapturingRunner()
        let shapes: [[String]] = [
            ["run"],
            ["run", "--profile"],
            ["run", "--profile=", "--", "agent-tool"],
            ["run", "--profile", "alice", "agent-tool"],
            ["run", "--profile", "alice", "--profile", "alice", "--", "agent-tool"],
            ["run", "--profile", "alice", "--model"],
            ["run", "--model", "local-fast", "--", "agent-tool"],
            ["run", "--unknown", "--", "agent-tool"]
        ]
        for shape in shapes {
            let result = JECommandLine.run(
                ["--state-dir", stateDirectory.path] + shape,
                environment: ["PATH": binDirectory.path],
                secretStore: fakeSecrets,
                harnessRunner: runner
            )
            XCTAssertEqual(result.code, 2, "shape should be invalid: \(shape)")
            XCTAssertTrue(result.stderr.contains("Invalid arguments."), "shape: \(shape)")
            XCTAssertEqual(result.stdout, "")
            XCTAssertFalse((result.stdout + result.stderr).contains(secret))
        }
        XCTAssertNil(runner.spec)
    }

    func testUnknownProfileNeverRuns() throws {
        try saveNativeProfile()
        _ = try makeExecutable(named: "agent-tool")
        let runner = RunCapturingRunner()
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "run", "--profile", "nope",
             "--", "agent-tool"],
            environment: ["PATH": binDirectory.path],
            secretStore: fakeSecrets,
            harnessRunner: runner
        )
        XCTAssertEqual(result.code, 2)
        XCTAssertNil(runner.spec)
        XCTAssertFalse((result.stdout + result.stderr).contains(secret))
    }

    func testStartFailuresAreSanitized() throws {
        try saveNativeProfile()
        _ = try makeExecutable(named: "agent-tool")
        let notFound = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "run", "--profile", "alice",
             "--", "missing-tool"],
            environment: ["PATH": binDirectory.path],
            secretStore: fakeSecrets,
            harnessRunner: RunCapturingRunner()
        )
        XCTAssertEqual(notFound.code, 2)
        XCTAssertEqual(
            notFound.stderr,
            "The operation failed; no credential or response contents were displayed.\n")
        XCTAssertFalse((notFound.stdout + notFound.stderr).contains(secret))

        let throwing = RunCapturingRunner()
        throwing.error = HarnessLaunchError.launchFailed
        let failed = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "run", "--profile", "alice",
             "--", "agent-tool"],
            environment: ["PATH": binDirectory.path],
            secretStore: fakeSecrets,
            harnessRunner: throwing
        )
        XCTAssertEqual(failed.code, 2)
        XCTAssertEqual(failed.stderr, notFound.stderr)
        XCTAssertFalse((failed.stdout + failed.stderr).contains(secret))
    }

    func testRealProcessReceivesEnvironmentAndExitCode() throws {
        try saveNativeProfile()
        let output = temporary.appendingPathComponent("env.txt")
        let script = try makeExecutable(
            named: "capture-env",
            body: """
            #!/bin/sh
            printf '%s|%s|%s' "$OPENAI_BASE_URL" "$OPENAI_API_KEY" "$OPENAI_MODEL" > "$1"
            exit 9
            """)
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "run", "--profile", "alice",
             "--", script, output.path],
            environment: ["PATH": "/usr/bin:/bin"],
            secretStore: fakeSecrets
        )
        XCTAssertEqual(result.code, 9, result.stderr)
        let captured = try String(contentsOf: output, encoding: .utf8)
        XCTAssertEqual(
            captured, "https://models.example.test/v1|\(secret)|local-fast")
    }

    func testRealProcessSignalMapsTo128PlusSignal() throws {
        try saveNativeProfile()
        let script = try makeExecutable(
            named: "self-term", body: "#!/bin/sh\nkill -TERM $$\n")
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "run", "--profile", "alice",
             "--", script],
            environment: ["PATH": "/usr/bin:/bin"],
            secretStore: fakeSecrets
        )
        XCTAssertEqual(result.code, 128 + 15, result.stderr)
    }

    private func saveNativeProfile() throws {
        try ProfileStore(directory: stateDirectory).saveNativeProfile(
            name: "alice",
            endpoint: "https://models.example.test",
            secret: secret,
            model: "local-fast",
            contextWindow: 32768,
            secretStore: fakeSecrets
        )
    }

    private func makeExecutable(
        named name: String, body: String = "#!/bin/sh\nexit 0\n"
    ) throws -> String {
        let url = binDirectory.appendingPathComponent(name)
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }
}

private final class RunCapturingRunner: HarnessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: HarnessLaunchSpec?
    var exitCode: Int32 = 0
    var error: Error?

    var spec: HarnessLaunchSpec? {
        lock.withLock { captured }
    }

    func run(_ spec: HarnessLaunchSpec) throws -> Int32 {
        lock.withLock { captured = spec }
        if let error {
            throw error
        }
        return exitCode
    }
}

private final class RunFakeSecretStore: SecretStoring, @unchecked Sendable {
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
