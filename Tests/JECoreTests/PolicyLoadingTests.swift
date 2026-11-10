import Foundation
import XCTest
@testable import JECore

final class PolicyLoadingTests: XCTestCase {
    private var temporary: URL!
    private var stateDirectory: URL!
    private var projectDirectory: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("je-policy-tests-" + UUID().uuidString, isDirectory: true)
        stateDirectory = temporary.appendingPathComponent("state", isDirectory: true)
        projectDirectory = temporary.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stateDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: stateDirectory.path)
        try publish(candidate(id: "fast-local", role: .fast, provider: .local))
        try publish(candidate(id: "strong-local", role: .strong, provider: .local))
        try publish(candidate(
            id: "fast-cloud", role: .fast, provider: .cloud, cloudReference: "cloud-a"
        ))
    }

    override func tearDownWithError() throws {
        if let temporary {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    func testPersonalDefaultRoleAppliesWhenFlagOmitted() throws {
        try writeStatePolicy(
            #"{"schema_version":1,"personal_defaults":{"alice":{"role":"strong"}}}"#
        )
        let result = why()
        XCTAssertEqual(result.code, 0, result.stderr)
        let object = try jsonObject(result.stdout)
        XCTAssertEqual(selectedID(object), "strong-local")
        XCTAssertTrue(sources(object).contains { $0.contains("person") })
    }

    func testOperatorDefaultIsLastFallbackAndExplicitWins() throws {
        try writeStatePolicy(
            #"{"schema_version":1,"operator_defaults":{"role":"strong"},"# +
            #""personal_defaults":{"alice":{"role":"fast"}}}"#
        )
        XCTAssertEqual(selectedID(try jsonObject(why().stdout)), "fast-local")
        let explicit = why(extra: ["--role", "strong"])
        XCTAssertEqual(selectedID(try jsonObject(explicit.stdout)), "strong-local")
    }

    func testUntrustedProjectNarrowsOnly() throws {
        try writeStatePolicy(
            #"{"schema_version":1,"personal_defaults":{"alice":{"role":"fast","cloud_profile":"cloud-a"}}}"#
        )
        try writeProjectPolicy(
            #"{"schema_version":1,"never_cloud":true,"candidate_id":"fast-cloud"}"#
        )
        let result = why()
        XCTAssertEqual(result.code, 0, result.stderr)
        let object = try jsonObject(result.stdout)
        XCTAssertEqual(selectedID(object), "fast-local")
        let untrusted = try XCTUnwrap(
            policySources(object).first { ($0["layer"] as? String) == "project_untrusted" }
        )
        XCTAssertEqual(untrusted["applied"] as? [String], ["never_cloud"])
        XCTAssertTrue(((untrusted["ignored"] as? [String]) ?? []).contains("candidate_id"))
    }

    func testTrustedProjectPreferencesApply() throws {
        let canonical = projectDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        try writeStatePolicy(
            "{\"schema_version\":1,\"personal_defaults\":{\"alice\":{\"role\":\"fast\"}},"
            + "\"trusted_projects\":[{\"identity\":\"" + canonical
            + "\",\"policy\":{\"role\":\"strong\"}}]}"
        )
        let result = why()
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertEqual(selectedID(try jsonObject(result.stdout)), "strong-local")
    }

    func testPersonalCloudDefaultAuthorizesOnlyMatchingCandidate() throws {
        try writeStatePolicy(
            #"{"schema_version":1,"personal_defaults":{"alice":{"role":"fast","candidate_id":"fast-cloud","cloud_profile":"cloud-a"}}}"#
        )
        let result = why()
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertEqual(selectedID(try jsonObject(result.stdout)), "fast-cloud")
    }

    func testOperatorCloudProfileIsIgnored() throws {
        try writeStatePolicy(
            #"{"schema_version":1,"operator_defaults":{"role":"fast","candidate_id":"fast-cloud","cloud_profile":"cloud-a"}}"#
        )
        let result = why()
        XCTAssertEqual(result.code, 0, result.stderr)
        let object = try jsonObject(result.stdout)
        XCTAssertEqual(selectedID(object), "fast-local")
        let decision = try XCTUnwrap(object["decision"] as? [String: Any])
        let filters = try XCTUnwrap(decision["filterResults"] as? [[String: Any]])
        let cloud = try XCTUnwrap(filters.first { ($0["candidateID"] as? String) == "fast-cloud" })
        XCTAssertTrue(((cloud["reasons"] as? [String]) ?? []).contains("cloud_not_authorized"))
    }

    func testMalformedPolicyFailsClosedWithoutEcho() throws {
        let canary = "canary-policy-secret"
        try writeStatePolicy("{\"schema_version\":1,\"personal_defaults\":{\"alice\":{\"role\":\"\(canary)\"}}}")
        let result = why()
        XCTAssertEqual(result.code, 2)
        XCTAssertFalse((result.stdout + result.stderr).contains(canary))
    }

    func testUnresolvedRoleStillFailsWithoutPolicy() {
        let result = why()
        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.stderr.contains("--role"))
    }

    func testProjectDiscoveryTerminatesWithoutPolicyFile() {
        // Regression: append-built URLs must not walk into "/.." forever
        // when no ancestor carries .je/policy.json.
        XCTAssertNil(PolicyLoader.discoverProjectFile(from: projectDirectory))
    }

    func testPolicyShowReportsLoadedSources() throws {
        try writeStatePolicy(
            #"{"schema_version":1,"personal_defaults":{"alice":{"role":"fast"}}}"#
        )
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "policy", "show", "--json"],
            environment: ["PATH": ""],
            currentDirectoryURL: projectDirectory
        )
        XCTAssertEqual(result.code, 0, result.stderr)
        let object = try jsonObject(result.stdout)
        XCTAssertEqual(object["schema_version"] as? Int, 1)
        XCTAssertEqual(object["state_policy_present"] as? Bool, true)
    }

    func testHumanWhyNamesPolicySources() throws {
        try writeStatePolicy(
            #"{"schema_version":1,"personal_defaults":{"alice":{"role":"fast"}}}"#
        )
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "why", "--person", "alice", "--", "hello"],
            environment: ["PATH": ""],
            currentDirectoryURL: projectDirectory
        )
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("Policy sources"))
        XCTAssertTrue(result.stdout.contains("person"))
    }

    private func why(extra: [String] = []) -> CLIResult {
        JECommandLine.run(
            ["--state-dir", stateDirectory.path, "why", "--person", "alice", "--json"]
                + extra + ["--", "hello"],
            environment: ["PATH": ""],
            currentDirectoryURL: projectDirectory
        )
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try XCTUnwrap(value as? [String: Any])
    }

    private func selectedID(_ object: [String: Any]) -> String? {
        (object["selectedCandidate"] as? [String: Any])?["id"] as? String
    }

    private func policySources(_ object: [String: Any]) -> [[String: Any]] {
        (object["policySources"] as? [[String: Any]]) ?? []
    }

    private func sources(_ object: [String: Any]) -> [String] {
        policySources(object).map { ($0["layer"] as? String) ?? "" }
    }

    private func writeStatePolicy(_ json: String) throws {
        let url = stateDirectory.appendingPathComponent("policy.json")
        try Data(json.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func writeProjectPolicy(_ json: String) throws {
        let folder = projectDirectory.appendingPathComponent(".je", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: folder.appendingPathComponent("policy.json"))
    }

    private func candidate(
        id: String,
        role: ModelRole,
        provider: ProviderKind,
        cloudReference: String? = nil
    ) -> RouteCandidate {
        RouteCandidate(
            id: id,
            role: role,
            engine: .ollama,
            harness: .codex,
            launchMode: .interactive,
            executionPlace: .personalMachine,
            providerKind: provider,
            modelArtifact: "local/model",
            engineVersion: "0.40.14",
            modelFormat: "ollama",
            protocolImplementation: "responses",
            protocolVersion: "1",
            configurationDigest: String(repeating: "c", count: 64),
            qualificationStatus: .qualified,
            allowedPersonIDs: ["alice"],
            cloudProfileReference: cloudReference,
            connectionProfileName: "laptop",
            qualificationEvidenceReference: "evidence:test",
            publishedPriority: id == "fast-cloud" ? 5 : 10
        )
    }

    private func publish(_ candidate: RouteCandidate) throws {
        _ = try AssignmentRegistry(directory: stateDirectory).publish(candidate)
    }
}
