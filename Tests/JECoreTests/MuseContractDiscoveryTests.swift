import Foundation
import XCTest
@testable import JECore

final class MuseContractDiscoveryTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("je-muse-discovery-tests-" + UUID().uuidString, isDirectory: true)
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

    func testKnownVersionBelowMemoryGateReportsBuiltinGlimmerUnavailable() throws {
        let executable = try writeFakeMuse()
        let report = try MuseContractDiscovery(
            physicalMemoryBytes: 36 * 1024 * 1024 * 1024
        ).discover(executableOverride: executable.path, environment: environment(version: "1.4.14"))

        XCTAssertEqual(report.version, "1.4.14")
        XCTAssertEqual(report.interactiveProviders, ["echo", "meta", "local"])
        XCTAssertEqual(report.headlessProviders, ["echo", "meta"])
        XCTAssertEqual(report.authenticationProviders, ["meta"])
        XCTAssertEqual(report.localContractStatus, "builtin_glimmer_unavailable_memory")
        XCTAssertEqual(report.experimentEnvironmentVariable, "MUSE_EXPERIMENTAL_LOCAL_MODELS")
        XCTAssertEqual(report.headlessLocalParserAccepted, true)
        XCTAssertFalse(report.arbitraryLocalEndpointContractDiscovered)
        XCTAssertTrue(report.evidenceReference.hasPrefix("evidence:muse-contract:"))
    }

    func testKnownVersionAtStudioMemoryIsDiscoveredButNotQualified() throws {
        let executable = try writeFakeMuse()
        let report = try MuseContractDiscovery(
            physicalMemoryBytes: 512 * 1024 * 1024 * 1024
        ).discover(executableOverride: executable.path, environment: environment(version: "1.4.14"))
        XCTAssertEqual(report.localContractStatus, "builtin_glimmer_contract_discovered_not_qualified")
        XCTAssertEqual(report.minimumKnownLocalMemoryBytes, 64 * 1024 * 1024 * 1024)
    }

    func testUnknownVersionDoesNotInheritKnownLocalContract() throws {
        let executable = try writeFakeMuse()
        let report = try MuseContractDiscovery(
            physicalMemoryBytes: 512 * 1024 * 1024 * 1024
        ).discover(executableOverride: executable.path, environment: environment(version: "9.0.0"))
        XCTAssertEqual(report.localContractStatus, "unknown_version_contract_unqualified")
        XCTAssertNil(report.experimentEnvironmentVariable)
        XCTAssertNil(report.headlessLocalParserAccepted)
        XCTAssertNil(report.minimumKnownLocalMemoryBytes)
    }

    func testMissingExecutableFailsClosed() {
        XCTAssertThrowsError(try MuseContractDiscovery().discover(
            executableOverride: temporary.appendingPathComponent("missing").path,
            environment: environment(version: "1.4.14")
        ))
    }

    func testDoctorMuseJSONUsesPublicProbesAndDoesNotEchoEnvironmentSecrets() throws {
        let executable = try writeFakeMuse()
        let secret = "synthetic-discovery-environment-secret"
        var environment = environment(version: "1.4.14")
        environment["JE_UNUSED_SECRET"] = secret
        let result = JECommandLine.run(
            ["doctor", "muse", "--json", "--executable", executable.path],
            environment: environment
        )
        XCTAssertEqual(result.code, 0, result.stderr)
        let report = try JSONDecoder().decode(MuseContractReport.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(report.version, "1.4.14")
        XCTAssertFalse((result.stdout + result.stderr).contains(secret))
        XCTAssertFalse((result.stdout + result.stderr).contains(executable.path))
    }

    func testUnknownDoctorTargetIsInvalid() {
        let result = JECommandLine.run(["doctor", "codex"], environment: [:])
        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.stderr.contains("Invalid arguments."))
    }

    private func environment(version: String) -> [String: String] {
        [
            "PATH": temporary.path,
            "JE_FAKE_MUSE_VERSION": version
        ]
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
