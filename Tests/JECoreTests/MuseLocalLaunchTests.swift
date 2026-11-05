import Foundation
import XCTest
@testable import JECore

final class MuseLocalLaunchTests: XCTestCase {
    private var temporary: URL!
    private var stateDirectory: URL!
    private let prompt = "synthetic muse local prompt"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("je-muse-local-tests-" + UUID().uuidString, isDirectory: true)
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

    func testHeadlessPreparationUsesLocalProviderAndExperiment() throws {
        let executable = try writeFakeMuse()
        let prepared = try HarnessLaunchPreparer().prepareMuseLocal(
            candidate: candidate(),
            prompt: prompt,
            environment: [
                "PATH": temporary.path,
                "JE_STUDIO_API_KEY": "stale",
                "JE_GATEWAY_API_KEY": "stale"
            ],
            executableOverride: executable.path,
            currentDirectoryURL: temporary,
            discoveryReport: report(status: "builtin_glimmer_contract_discovered_not_qualified")
        )
        XCTAssertEqual(
            prepared.spec.arguments,
            ["exec", "--provider", "local", "--model", "local", prompt]
        )
        XCTAssertEqual(prepared.spec.environment["MUSE_EXPERIMENTAL_LOCAL_MODELS"], "1")
        XCTAssertNil(prepared.spec.environment["JE_STUDIO_API_KEY"])
        XCTAssertNil(prepared.spec.environment["JE_GATEWAY_API_KEY"])
        XCTAssertEqual(prepared.spec.currentDirectoryURL, temporary)
    }

    func testInteractivePreparationUsesTopLevelProviderArguments() throws {
        let executable = try writeFakeMuse()
        let prepared = try HarnessLaunchPreparer().prepareMuseLocal(
            candidate: candidate(mode: .interactive, model: "glimmer"),
            prompt: prompt,
            environment: ["PATH": temporary.path],
            executableOverride: executable.path,
            discoveryReport: report(status: "builtin_glimmer_contract_discovered_not_qualified")
        )
        XCTAssertEqual(
            prepared.spec.arguments,
            ["--provider", "local", "--model", "glimmer", prompt]
        )
    }

    func testMemoryGateAndWrongIdentityFailClosed() throws {
        let executable = try writeFakeMuse()
        XCTAssertThrowsError(try HarnessLaunchPreparer().prepareMuseLocal(
            candidate: candidate(),
            prompt: prompt,
            environment: ["PATH": temporary.path],
            executableOverride: executable.path,
            discoveryReport: report(status: "builtin_glimmer_unavailable_memory")
        )) { error in
            XCTAssertEqual(error as? HarnessLaunchError, .localModelUnavailable)
        }

        var wrong = candidate()
        wrong = RouteCandidate(
            id: wrong.id,
            role: wrong.role,
            engine: .ollama,
            harness: wrong.harness,
            launchMode: wrong.launchMode,
            executionPlace: wrong.executionPlace,
            providerKind: wrong.providerKind,
            modelArtifact: wrong.modelArtifact,
            engineVersion: wrong.engineVersion,
            modelFormat: wrong.modelFormat,
            protocolImplementation: wrong.protocolImplementation,
            protocolVersion: wrong.protocolVersion,
            configurationDigest: wrong.configurationDigest,
            qualificationStatus: wrong.qualificationStatus,
            allowedPersonIDs: wrong.allowedPersonIDs,
            qualificationEvidenceReference: wrong.qualificationEvidenceReference
        )
        XCTAssertThrowsError(try HarnessLaunchPreparer().prepareMuseLocal(
            candidate: wrong,
            prompt: prompt,
            environment: ["PATH": temporary.path],
            executableOverride: executable.path,
            discoveryReport: report(status: "builtin_glimmer_contract_discovered_not_qualified")
        )) { error in
            XCTAssertEqual(error as? HarnessLaunchError, .localContractUnknown)
        }
    }

    func testAskLaunchesMuseLocalWithFakeRunner() throws {
        try publish(candidate(status: .qualified))
        let executable = try writeFakeMuse()
        let runner = CapturingRunner(exitCode: 0)
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "ask", "--person", "alice", "--role", "fast",
             "--executable", executable.path, "--json", "--", prompt],
            environment: ["PATH": temporary.path, "JE_FAKE_MUSE_VERSION": "1.4.14"],
            recordedDay: "2026-11-04",
            runID: "run-muse-local",
            harnessRunner: runner,
            musePhysicalMemoryBytes: 512 * 1024 * 1024 * 1024
        )
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("\"launchStatus\" : \"completed\""))
        XCTAssertEqual(runner.spec?.arguments.last, prompt)
        XCTAssertFalse((result.stdout + result.stderr).contains(prompt))
        let ledger = try String(contentsOf: ledgerURL, encoding: .utf8)
        XCTAssertTrue(ledger.contains("\"outcome\":\"succeeded\""))
        XCTAssertFalse(ledger.contains(prompt))
    }

    func testQualificationRunsSuiteForMuseLocal() throws {
        try publish(candidate(status: .planned))
        let executable = try writeFakeMuse()
        let runner = SuiteRunner()
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "assignments", "qualify", "fast-muse-local",
             "--executable", executable.path, "--mark-qualified"],
            environment: ["PATH": temporary.path, "JE_FAKE_MUSE_VERSION": "1.4.14"],
            recordedDay: "2026-11-04",
            harnessRunner: runner,
            musePhysicalMemoryBytes: 512 * 1024 * 1024 * 1024
        )
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("Assignment marked qualified."))
        XCTAssertEqual(runner.specs.count, 4)
        let loaded = try AssignmentRegistry(directory: stateDirectory).loadCandidates()
        XCTAssertEqual(loaded.first?.qualificationStatus, .qualified)

        let evidenceDirectory = stateDirectory.appendingPathComponent("qualification", isDirectory: true)
        let evidenceFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: evidenceDirectory, includingPropertiesForKeys: nil).first
        )
        let record = try JSONDecoder().decode(
            QualificationEvidenceRecord.self,
            from: Data(contentsOf: evidenceFile)
        )
        XCTAssertTrue(record.passed)
        XCTAssertEqual(record.checks.first { $0.id == "muse_contract" }?.status, .passed)
        XCTAssertEqual(record.checks.first { $0.id == "connection_profile" }?.detailCode, "not_required")
        XCTAssertEqual(record.taskResults.count, 4)
    }

    private var ledgerURL: URL {
        stateDirectory.appendingPathComponent("usage/detailed.jsonl")
    }

    private func publish(_ candidate: RouteCandidate) throws {
        _ = try AssignmentRegistry(directory: stateDirectory).publish(candidate)
    }

    private func candidate(
        mode: LaunchMode = .headless,
        model: String = "local",
        status: QualificationStatus = .qualified
    ) -> RouteCandidate {
        RouteCandidate(
            id: "fast-muse-local",
            role: .fast,
            engine: .mlxNative,
            harness: .muse,
            launchMode: mode,
            executionPlace: .personalMachine,
            providerKind: .local,
            modelArtifact: model,
            engineVersion: "1.4.14",
            modelFormat: "built-in",
            protocolImplementation: HarnessLaunchPreparer.museLocalProtocolImplementation,
            protocolVersion: "1.4.14",
            configurationDigest: String(repeating: "c", count: 64),
            qualificationStatus: status,
            allowedPersonIDs: ["alice"],
            qualificationEvidenceReference: status == .qualified ? "evidence:test" : nil,
            publishedPriority: 10
        )
    }

    private func report(status: String) -> MuseContractReport {
        MuseContractReport(
            schemaVersion: 1,
            version: "1.4.14",
            interactiveProviders: ["echo", "meta", "local"],
            headlessProviders: ["echo", "meta"],
            authenticationProviders: ["meta"],
            physicalMemoryBytes: 512 * 1024 * 1024 * 1024,
            minimumKnownLocalMemoryBytes: 64 * 1024 * 1024 * 1024,
            experimentEnvironmentVariable: "MUSE_EXPERIMENTAL_LOCAL_MODELS",
            headlessLocalParserAccepted: true,
            arbitraryLocalEndpointContractDiscovered: false,
            localContractStatus: status,
            evidenceCodes: ["known_version_local_models_experiment"],
            evidenceReference: "evidence:muse-contract:test"
        )
    }

    private func writeFakeMuse() throws -> URL {
        let script = """
        #!/bin/sh
        case "$*" in
          "--version") printf '%s\n' "Muse Code $JE_FAKE_MUSE_VERSION (test)" ;;
          "exec --help") printf '%s\n' 'Startup provider: echo or meta (default: meta)' ;;
          "auth set --help") printf '%s\n' '[possible values: meta]' ;;
          "--help") printf '%s\n' 'Startup provider: echo, meta, or local (default: meta)' ;;
          *) exit 9 ;;
        esac
        """
        let path = temporary.appendingPathComponent("muse")
        try Data(script.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }
}

private final class CapturingRunner: HarnessRunning, @unchecked Sendable {
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

private final class SuiteRunner: HarnessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var capturedSpecs: [HarnessLaunchSpec] = []

    var specs: [HarnessLaunchSpec] {
        lock.withLock { capturedSpecs }
    }

    func run(_ spec: HarnessLaunchSpec) throws -> Int32 {
        lock.withLock { capturedSpecs.append(spec) }
        guard let directory = spec.currentDirectoryURL else { return 9 }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directory.appendingPathComponent("input.txt").path) {
            let input = try Data(contentsOf: directory.appendingPathComponent("input.txt"))
            try input.write(to: directory.appendingPathComponent("output.txt"))
        } else if fileManager.fileExists(atPath: directory.appendingPathComponent("spec.txt").path) {
            let text = try String(contentsOf: directory.appendingPathComponent("spec.txt"), encoding: .utf8)
            let line = text.split(separator: "\n").first { $0.hasPrefix("answer_key=") } ?? ""
            try Data((String(line.dropFirst("answer_key=".count)) + "\n").utf8)
                .write(to: directory.appendingPathComponent("answer.txt"))
        } else if fileManager.fileExists(atPath: directory.appendingPathComponent("lines.txt").path) {
            let prompt = spec.arguments.last ?? ""
            let quoted = prompt.split(separator: "\"")
            let needle = quoted.count >= 2 ? String(quoted[1]) : ""
            let lines = try String(contentsOf: directory.appendingPathComponent("lines.txt"), encoding: .utf8)
                .split(separator: "\n").map(String.init)
            try Data((lines.filter { $0.contains(needle) }.joined(separator: "\n") + "\n").utf8)
                .write(to: directory.appendingPathComponent("selected.txt"))
        } else if fileManager.fileExists(atPath: directory.appendingPathComponent("notes.txt").path) {
            let notes = try String(contentsOf: directory.appendingPathComponent("notes.txt"), encoding: .utf8)
            let replacement = try String(
                contentsOf: directory.appendingPathComponent("replacement.txt"),
                encoding: .utf8
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            try Data(notes.replacingOccurrences(of: "<TOKEN>", with: replacement).utf8)
                .write(to: directory.appendingPathComponent("notes.txt"))
        } else {
            return 9
        }
        return 0
    }
}
