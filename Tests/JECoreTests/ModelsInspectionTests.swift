import Foundation
import XCTest
@testable import JECore

final class ModelsInspectionTests: XCTestCase {
    private var temporary: URL!
    private var stateDirectory: URL!
    private var homeDirectory: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("je-models-tests-" + UUID().uuidString, isDirectory: true)
        stateDirectory = temporary.appendingPathComponent("state", isDirectory: true)
        homeDirectory = temporary.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stateDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: homeDirectory, withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: stateDirectory.path)
    }

    override func tearDownWithError() throws {
        if let temporary {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    func testEmptyStateReportsAllEnginesAndMatrix() throws {
        let report = try ModelsInspectionBuilder.build(
            stateDirectory: stateDirectory,
            environment: ["PATH": ""],
            homeDirectory: homeDirectory
        )
        XCTAssertEqual(report.engines.map(\.engine), ["ollama", "mlx_native", "lm_studio", "llama_cpp"])
        XCTAssertTrue(report.engines.allSatisfy { $0.executablePath == nil })
        XCTAssertTrue(report.artifacts.isEmpty)
        XCTAssertTrue(report.assignments.isEmpty)
        XCTAssertEqual(report.supportMatrix.totalCells, 112)
        XCTAssertEqual(report.supportMatrix.countsByStatus["qualified"], 1)
        let ollama = try XCTUnwrap(report.engines.first { $0.engine == "ollama" })
        XCTAssertEqual(ollama.matrixCells, 28)
        XCTAssertEqual(ollama.matrixCountsByStatus["qualified"], 1)
        XCTAssertEqual(ollama.storePresent, false)
        XCTAssertNil(ollama.storeBytes)
        let llama = try XCTUnwrap(report.engines.first { $0.engine == "llama_cpp" })
        XCTAssertNil(llama.storePath)
    }

    func testAssignmentsRollUpIntoEnginesAndArtifacts() throws {
        try publish(candidate(
            id: "a-qualified", status: .qualified, engine: .ollama,
            artifact: "local/model", evidence: "evidence:test"
        ))
        try publish(candidate(
            id: "b-planned", status: .planned, engine: .ollama,
            artifact: "local/model", evidence: nil, harness: .codex, launchMode: .interactive
        ))
        try publish(candidate(
            id: "c-mlx", status: .planned, engine: .mlxNative,
            artifact: "mlx/model", evidence: nil, harness: .codex, launchMode: .interactive
        ))
        let report = try ModelsInspectionBuilder.build(
            stateDirectory: stateDirectory,
            environment: ["PATH": ""],
            homeDirectory: homeDirectory
        )
        XCTAssertEqual(report.assignments.map(\.id), ["a-qualified", "b-planned", "c-mlx"])
        XCTAssertEqual(report.assignments.first?.cell, "fast/ollama/built_in/single_step/personal_machine")
        XCTAssertEqual(report.assignments.first?.qualificationEvidenceReference, "evidence:test")
        let ollama = try XCTUnwrap(report.engines.first { $0.engine == "ollama" })
        XCTAssertEqual(ollama.assignmentCountsByStatus["qualified"], 1)
        XCTAssertEqual(ollama.assignmentCountsByStatus["planned"], 1)
        XCTAssertEqual(report.artifacts.count, 2)
        let shared = try XCTUnwrap(report.artifacts.first { $0.modelArtifact == "local/model" })
        XCTAssertEqual(shared.assignments, 2)
        XCTAssertEqual(shared.qualifiedAssignments, 1)
        XCTAssertEqual(shared.roles, ["fast"])
    }

    func testStoreBytesSumRegularFilesAndSkipSymlinks() throws {
        let models = homeDirectory.appendingPathComponent(".ollama/models", isDirectory: true)
        let nested = models.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 1000).write(to: nested.appendingPathComponent("a.bin"))
        try Data(repeating: 9, count: 24).write(to: models.appendingPathComponent("b.bin"))
        let outside = temporary.appendingPathComponent("outside.bin")
        try Data(repeating: 3, count: 5000).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: models.appendingPathComponent("link.bin"), withDestinationURL: outside
        )
        let report = try ModelsInspectionBuilder.build(
            stateDirectory: stateDirectory,
            environment: ["PATH": ""],
            homeDirectory: homeDirectory
        )
        let ollama = try XCTUnwrap(report.engines.first { $0.engine == "ollama" })
        XCTAssertEqual(ollama.storePresent, true)
        XCTAssertEqual(ollama.storeBytes, 1024)
        XCTAssertEqual(ollama.storeComplete, true)
    }

    func testExecutableDiscoveryUsesPathOnly() throws {
        let bin = temporary.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("ollama")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let report = try ModelsInspectionBuilder.build(
            stateDirectory: stateDirectory,
            environment: ["PATH": bin.path],
            homeDirectory: homeDirectory
        )
        let ollama = try XCTUnwrap(report.engines.first { $0.engine == "ollama" })
        XCTAssertEqual(ollama.executableName, "ollama")
        XCTAssertEqual(ollama.executablePath, fake.path)
    }

    func testStorageAreasReportStateBytes() throws {
        let profiles = stateDirectory.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(
            at: profiles, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(repeating: 1, count: 100).write(to: profiles.appendingPathComponent("x.json"))
        let report = try ModelsInspectionBuilder.build(
            stateDirectory: stateDirectory,
            environment: ["PATH": ""],
            homeDirectory: homeDirectory
        )
        let area = try XCTUnwrap(report.storage.areas.first { $0.name == "profiles" })
        XCTAssertEqual(area.bytes, 100)
        XCTAssertGreaterThanOrEqual(report.storage.totalBytes, 100)
    }

    func testModelsCommandJSONAndHumanOutput() throws {
        let jsonResult = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "models", "--json"],
            environment: ["PATH": "", "HOME": homeDirectory.path]
        )
        XCTAssertEqual(jsonResult.code, 0, jsonResult.stderr)
        let object = try JSONSerialization.jsonObject(with: Data(jsonResult.stdout.utf8)) as? [String: Any]
        XCTAssertEqual((object?["engines"] as? [Any])?.count, 4)
        XCTAssertNotNil(object?["storage"])
        XCTAssertFalse(jsonResult.stdout.contains("api_key"))

        let human = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "models"],
            environment: ["PATH": "", "HOME": homeDirectory.path]
        )
        XCTAssertEqual(human.code, 0, human.stderr)
        XCTAssertTrue(human.stdout.contains("Engines"))
        XCTAssertTrue(human.stdout.contains("ollama"))
        XCTAssertTrue(human.stdout.contains("Qualification"))

        let invalid = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "models", "--bogus"],
            environment: ["PATH": "", "HOME": homeDirectory.path]
        )
        XCTAssertEqual(invalid.code, 2)
    }

    private func candidate(
        id: String,
        status: QualificationStatus,
        engine: EngineFamily,
        artifact: String,
        evidence: String?,
        harness: HarnessKind = .builtIn,
        launchMode: LaunchMode = .singleStep
    ) -> RouteCandidate {
        RouteCandidate(
            id: id,
            role: .fast,
            engine: engine,
            harness: harness,
            launchMode: launchMode,
            executionPlace: .personalMachine,
            providerKind: .local,
            modelArtifact: artifact,
            engineVersion: "0.40.14",
            modelFormat: "ollama",
            protocolImplementation: "ollama-native-chat",
            protocolVersion: "0.40.14",
            configurationDigest: String(repeating: "c", count: 64),
            qualificationStatus: status,
            allowedPersonIDs: ["alice"],
            connectionProfileName: "laptop",
            qualificationEvidenceReference: evidence,
            publishedPriority: 10
        )
    }

    private func publish(_ candidate: RouteCandidate) throws {
        _ = try AssignmentRegistry(directory: stateDirectory).publish(candidate)
    }
}
