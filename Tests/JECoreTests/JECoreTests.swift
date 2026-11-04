import XCTest
@testable import JECore

final class JECoreTests: XCTestCase {
    func testVersionCommand() {
        let result = JECommandLine.run(["--version"])
        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(result.stdout, "je \(JEVersion.current)\n")
        XCTAssertEqual(result.stderr, "")
    }

    func testInvalidArgumentsNeverEchoInput() {
        let canary = "synthetic-secret-canary"
        let result = JECommandLine.run([canary, "--also-not-echoed"])
        XCTAssertEqual(result.code, 2)
        XCTAssertFalse((result.stdout + result.stderr).contains(canary))
        XCTAssertFalse((result.stdout + result.stderr).contains("also-not-echoed"))
    }

    func testLegacyCommandIsReportedAsNotPortedWithoutEcho() {
        let canary = "synthetic-profile-name"
        let result = JECommandLine.run(["connect", "codex", "--profile", canary])
        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.stderr.contains("not ported"))
        XCTAssertFalse((result.stdout + result.stderr).contains(canary))
    }

    func testWorkspaceIsHostOnlyWithoutEchoingPath() {
        let path = "/private/example.json"
        let result = JECommandLine.run(["workspace", "plan", "--config", path])
        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.stderr.contains("host-only"))
        XCTAssertFalse((result.stdout + result.stderr).contains(path))
    }

    func testUserArtifactBoundaryExcludesHostModules() {
        let userNames = Set(ArtifactBoundary.userArtifactModules.map(\.name))
        let hostNames = Set(ArtifactBoundary.hostOnlyModules.map(\.name))
        XCTAssertTrue(userNames.isDisjoint(with: hostNames))
        XCTAssertEqual(
            ArtifactBoundary.userArtifactViolations(moduleNames: ["cli", "workspaces", "service_control"]),
            ["service_control", "workspaces"]
        )
    }

    func testLaunchSupportMatrixShape() {
        let entries = SupportMatrix.launchEntries
        XCTAssertEqual(entries.count, 112)
        XCTAssertEqual(SupportMatrix.duplicateIDs(in: entries), [])
        XCTAssertEqual(Set(entries.map(\.role)), Set(ModelRole.allCases))
        XCTAssertEqual(Set(entries.map(\.engine)), Set(EngineFamily.allCases))
        XCTAssertEqual(Set(entries.map(\.harness)), Set(HarnessKind.allCases))
        XCTAssertEqual(Set(entries.map(\.executionPlace)), Set(ExecutionPlace.allCases))
    }

    func testMuseHeadlessCellsNameTheContractGap() {
        let gaps = SupportMatrix.launchEntries.filter {
            $0.harness == .muse && $0.launchMode == .headless
        }
        XCTAssertEqual(gaps.count, 16)
        XCTAssertTrue(gaps.allSatisfy { $0.status == .blockedOnContractDiscovery })
    }

    func testProfileNameValidatorMatchesFrozenOracleShape() {
        XCTAssertTrue(ProfileNameValidator.isValid("studio-main"))
        XCTAssertTrue(ProfileNameValidator.isValid("A.1_2"))
        XCTAssertFalse(ProfileNameValidator.isValid(""))
        XCTAssertFalse(ProfileNameValidator.isValid("-starts-with-dash"))
        XCTAssertFalse(ProfileNameValidator.isValid("has space"))
        XCTAssertFalse(ProfileNameValidator.isValid(String(repeating: "a", count: 65)))
    }

    func testStatusJSONIsStableAndContainsNoCredentialFieldNames() throws {
        let first = try StableJSON.encode(StatusReport.current)
        let second = try StableJSON.encode(StatusReport.current)
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.contains("api_key"))
        XCTAssertFalse(first.contains("token"))
        XCTAssertTrue(first.contains("supportMatrix"))
    }

    func testStatusJSONCommand() {
        let result = JECommandLine.run(["status", "--json"])
        XCTAssertEqual(result.code, 0)
        XCTAssertTrue(result.stdout.contains("\"artifact\" : \"user\""))
        XCTAssertEqual(result.stderr, "")
    }
}
