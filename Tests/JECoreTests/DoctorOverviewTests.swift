import Foundation
import XCTest
@testable import JECore

final class DoctorOverviewTests: XCTestCase {
    private var temporary: URL!
    private var stateDirectory: URL!
    private var fakeSecrets: DoctorFakeSecretStore!
    private let gatewaySecret = "synthetic-doctor-gateway-key"
    private let memorySecret = "synthetic-doctor-memory-token"
    private let ollamaSecret = "synthetic-doctor-ollama-key"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("je-doctor-tests-" + UUID().uuidString, isDirectory: true)
        stateDirectory = temporary.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        fakeSecrets = DoctorFakeSecretStore()
    }

    override func tearDownWithError() throws {
        if let temporary {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    func testOverviewReportsProfilesWarningsAndUsage() throws {
        try saveWarningFixture()
        let report = try buildReport(environment: ["PATH": try fakeBinDirectory()])

        XCTAssertEqual(report.profiles.gateway.map(\.name), ["alice"])
        XCTAssertEqual(report.profiles.gateway.first?.secretStorage, "secret_reference")
        XCTAssertEqual(report.profiles.memory.map(\.name), ["alice-memory"])
        XCTAssertEqual(report.profiles.ollama.map(\.name), ["laptop"])
        XCTAssertEqual(report.profiles.ollama.first?.secretStorage, "embedded_legacy")
        XCTAssertEqual(report.profiles.ollama.first?.model, "local/model")

        XCTAssertEqual(report.assignments.total, 2)
        XCTAssertEqual(report.assignments.qualified, 1)
        XCTAssertEqual(report.supportMatrix.totalCells, 112)
        XCTAssertEqual(report.usage.detailedTraces, 1)
        XCTAssertEqual(report.usage.latestRecordedDay, "2026-11-04")

        XCTAssertEqual(report.warnings.map(\.code), [
            "embedded_secret", "unloadable_profile", "dangling_assignment_profile"
        ])
        XCTAssertFalse(report.healthy)

        let executablePaths = Dictionary(
            uniqueKeysWithValues: report.executables.map { ($0.name, $0.path) })
        XCTAssertEqual(executablePaths["ollama"] ?? nil, try fakeBinDirectory() + "/ollama")
        XCTAssertEqual(executablePaths["codex"] ?? nil, try fakeBinDirectory() + "/codex")
        XCTAssertNil(executablePaths["claude"] ?? nil)
        XCTAssertNil(executablePaths["muse"] ?? nil)

        let rendered = DoctorOverviewRenderer.render(report)
        XCTAssertTrue(rendered.hasPrefix("je doctor\n"))
        XCTAssertTrue(rendered.contains("Profiles\n"))
        XCTAssertTrue(rendered.contains("laptop"))
        XCTAssertTrue(rendered.contains("embedded key"))
        XCTAssertTrue(rendered.contains("Warnings\n"))
        XCTAssertTrue(rendered.contains("3 warnings to review."))
        XCTAssertFalse(rendered.contains(gatewaySecret))
        XCTAssertFalse(rendered.contains(memorySecret))
        XCTAssertFalse(rendered.contains(ollamaSecret))
        let encoded = try StableJSON.encode(report)
        XCTAssertFalse(encoded.contains(gatewaySecret))
        XCTAssertFalse(encoded.contains(ollamaSecret))
    }

    func testOverviewHealthyFixtureHasNoWarnings() throws {
        try saveNativeGatewayProfile()
        try publish(candidate(
            id: "fast-builtin-healthy",
            status: .qualified,
            connectionProfileName: "alice",
            evidence: "evidence:test"))
        let report = try buildReport(environment: ["PATH": ""])
        XCTAssertTrue(report.warnings.isEmpty, "\(report.warnings)")
        XCTAssertTrue(report.healthy)
        let rendered = DoctorOverviewRenderer.render(report)
        XCTAssertTrue(rendered.contains("Healthy."))
        XCTAssertFalse(rendered.contains("Warnings\n"))
    }

    func testDoctorCommandBareAndJSON() throws {
        try saveWarningFixture()
        let environment = ["PATH": try fakeBinDirectory()]
        let bare = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "doctor"],
            environment: environment,
            secretStore: fakeSecrets
        )
        XCTAssertEqual(bare.code, 1, bare.stderr)
        XCTAssertTrue(bare.stdout.hasPrefix("je doctor\n"))
        XCTAssertTrue(bare.stdout.contains("Warnings\n"))
        XCTAssertEqual(bare.stderr, "")

        let json = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "doctor", "--json"],
            environment: environment,
            secretStore: fakeSecrets
        )
        XCTAssertEqual(json.code, 1, json.stderr)
        let decoded = try JSONDecoder().decode(
            DoctorOverviewReport.self, from: Data(json.stdout.utf8))
        XCTAssertFalse(decoded.healthy)
        XCTAssertEqual(decoded.warnings.count, 3)
        XCTAssertFalse((bare.stdout + json.stdout).contains(gatewaySecret))
        XCTAssertFalse((bare.stdout + json.stdout).contains(ollamaSecret))
        XCTAssertFalse((bare.stdout + json.stdout).contains(memorySecret))
    }

    func testDoctorEmptyStateIsHealthy() throws {
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "doctor"],
            environment: ["PATH": ""],
            secretStore: fakeSecrets
        )
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("none saved"))
        XCTAssertTrue(result.stdout.contains("none published"))
        XCTAssertTrue(result.stdout.contains("Healthy."))
    }

    func testDoctorProfileFormStillChecksGateway() throws {
        try saveNativeGatewayProfile()
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "doctor", "--profile", "alice"],
            environment: [:],
            secretStore: fakeSecrets,
            gatewayTransport: DoctorFakeGatewayTransport()
        )
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertEqual(result.stdout, "Connected. Model local-fast is available.\n")
    }

    private func buildReport(environment: [String: String]) throws -> DoctorOverviewReport {
        try DoctorOverviewBuilder.build(
            stateDirectory: stateDirectory,
            environment: environment,
            machineOS: "macOS 26.0",
            machineArch: "arm64",
            memoryBytes: 36_000_000_000
        )
    }

    private func saveWarningFixture() throws {
        try saveNativeGatewayProfile()
        try saveNativeMemoryProfile()
        try saveLegacyOllamaProfile()
        try saveBrokenGatewayProfile()
        try publish(candidate(
            id: "fast-builtin-ollama-laptop",
            status: .qualified,
            connectionProfileName: "laptop",
            evidence: "evidence:test"))
        try publish(candidate(
            id: "fast-codex-ghost",
            status: .planned,
            connectionProfileName: "ghost",
            evidence: nil,
            harness: .codex,
            launchMode: .interactive))
        try UsageLedgerFile(directory: stateDirectory).append(DetailedUsageTrace(
            runID: "run-doctor-1",
            recordedDay: "2026-11-04",
            personID: "alice",
            harness: .builtIn,
            launchMode: .singleStep,
            role: .fast,
            engine: .ollama,
            executionPlace: .personalMachine,
            providerKind: .local,
            assignmentID: "fast-builtin-ollama-laptop",
            policyVersion: "routing-policy-v1",
            winningLayer: "explicit",
            durationMs: 120,
            inputTokens: 10,
            outputTokens: 5,
            actualCost: nil,
            estimatedCost: nil,
            costEstimateSource: nil,
            outcome: .succeeded
        ))
    }

    private func candidate(
        id: String,
        status: QualificationStatus,
        connectionProfileName: String,
        evidence: String?,
        harness: HarnessKind = .builtIn,
        launchMode: LaunchMode = .singleStep
    ) -> RouteCandidate {
        RouteCandidate(
            id: id,
            role: .fast,
            engine: .ollama,
            harness: harness,
            launchMode: launchMode,
            executionPlace: .personalMachine,
            providerKind: .local,
            modelArtifact: "local/model",
            engineVersion: "0.40.14",
            modelFormat: "ollama",
            protocolImplementation: "ollama-native-chat",
            protocolVersion: "0.40.14",
            configurationDigest: String(repeating: "c", count: 64),
            qualificationStatus: status,
            allowedPersonIDs: ["alice"],
            connectionProfileName: connectionProfileName,
            qualificationEvidenceReference: evidence,
            publishedPriority: 10
        )
    }

    private func publish(_ candidate: RouteCandidate) throws {
        _ = try AssignmentRegistry(directory: stateDirectory).publish(candidate)
    }

    private func saveNativeGatewayProfile() throws {
        try ProfileStore(directory: stateDirectory).saveNativeProfile(
            name: "alice",
            endpoint: "https://models.example.test",
            secret: gatewaySecret,
            model: "local-fast",
            contextWindow: 32768,
            secretStore: fakeSecrets
        )
    }

    private func saveNativeMemoryProfile() throws {
        try ProfileStore(directory: stateDirectory).saveNativeMemoryProfile(
            name: "alice-memory",
            endpoint: "https://memory.example.test/mcp",
            secret: memorySecret,
            secretStore: fakeSecrets
        )
    }

    private func saveLegacyOllamaProfile() throws {
        let folder = stateDirectory.appendingPathComponent(
            "ollama-profiles", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = folder.appendingPathComponent("laptop.json")
        let json = "{\"schema_version\":1,\"endpoint\":\"http://127.0.0.1:11434\","
            + "\"api_key\":\"\(ollamaSecret)\",\"model\":\"local/model\"}"
        try Data(json.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func saveBrokenGatewayProfile() throws {
        let folder = stateDirectory.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = folder.appendingPathComponent("broken.json")
        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func fakeBinDirectory() throws -> String {
        let bin = temporary.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bin, withIntermediateDirectories: true)
        for name in ["ollama", "codex"] {
            let url = bin.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        }
        return bin.path
    }
}

private final class DoctorFakeGatewayTransport: OllamaHTTPTransport, @unchecked Sendable {
    func get(url: URL, bearerToken: String) throws -> OllamaHTTPResponse {
        OllamaHTTPResponse(
            statusCode: 200,
            data: Data("{\"data\":[{\"id\":\"local-fast\"}]}".utf8))
    }
}

private final class DoctorFakeSecretStore: SecretStoring, @unchecked Sendable {
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
