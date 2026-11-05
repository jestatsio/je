import Foundation
import XCTest
@testable import JECore

final class GatewayCheckTests: XCTestCase {
    private var temporary: URL!
    private var stateDirectory: URL!
    private var fakeSecrets: GatewayCheckFakeSecretStore!
    private let secret = "synthetic-gateway-check-key"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("je-gateway-check-tests-" + UUID().uuidString, isDirectory: true)
        stateDirectory = temporary.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        fakeSecrets = GatewayCheckFakeSecretStore()
    }

    override func tearDownWithError() throws {
        if let temporary {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    func testCheckerPassesAndIgnoresNonObjectEntries() throws {
        let transport = FakeTransport(
            response: OllamaHTTPResponse(
                statusCode: 200,
                data: Data("{\"data\":[{\"id\":\"other\"},42,{\"id\":\"local-fast\"}]}".utf8)
            )
        )
        let report = try GatewayConnectionChecker.check(profile: resolvedProfile(), transport: transport)
        XCTAssertTrue(report.passed)
        XCTAssertTrue(report.authenticated)
        XCTAssertEqual(report.model, "local-fast")
        XCTAssertTrue(report.modelAvailable)
        XCTAssertEqual(transport.url?.absoluteString, "https://models.example.test/v1/models")
        XCTAssertEqual(transport.bearerToken, secret)
    }

    func testCheckerReportsUnavailableForEmptyListing() throws {
        let transport = FakeTransport(
            response: OllamaHTTPResponse(statusCode: 200, data: Data("{\"data\":[]}".utf8))
        )
        let report = try GatewayConnectionChecker.check(profile: resolvedProfile(), transport: transport)
        XCTAssertFalse(report.passed)
        XCTAssertFalse(report.modelAvailable)
    }

    func testCheckerRejectsInvalidListingShape() {
        let transport = FakeTransport(
            response: OllamaHTTPResponse(statusCode: 200, data: Data("{\"models\":[]}".utf8))
        )
        XCTAssertThrowsError(
            try GatewayConnectionChecker.check(profile: resolvedProfile(), transport: transport)
        ) { error in
            XCTAssertEqual(
                (error as? GatewayCheckError)?.message,
                "The gateway did not return a valid model listing."
            )
            XCTAssertFalse(String(describing: error).contains(secret))
        }
    }

    func testCheckerHTTPFailureExposesStatusOnly() {
        let transport = FakeTransport(
            response: OllamaHTTPResponse(statusCode: 403, data: Data(secret.utf8))
        )
        XCTAssertThrowsError(
            try GatewayConnectionChecker.check(profile: resolvedProfile(), transport: transport)
        ) { error in
            XCTAssertEqual(
                (error as? GatewayCheckError)?.message,
                "Gateway connection failed with HTTP 403."
            )
            XCTAssertFalse(String(describing: error).contains(secret))
        }
    }

    func testCheckerRejectsOversizedListing() {
        let transport = FakeTransport(
            response: OllamaHTTPResponse(statusCode: 200, data: Data(repeating: 32, count: 1_048_577))
        )
        XCTAssertThrowsError(
            try GatewayConnectionChecker.check(profile: resolvedProfile(), transport: transport)
        ) { error in
            XCTAssertEqual(
                (error as? GatewayCheckError)?.message,
                "The gateway model listing exceeded the supported size."
            )
        }
    }

    func testDoctorCommandPassesAndUnavailableReturnsOne() throws {
        try saveProfile()
        let passing = FakeTransport(
            response: OllamaHTTPResponse(
                statusCode: 200,
                data: Data("{\"data\":[{\"id\":\"local-fast\"}]}".utf8)
            )
        )
        let passed = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "doctor", "--profile", "alice"],
            environment: [:],
            secretStore: fakeSecrets,
            gatewayTransport: passing
        )
        XCTAssertEqual(passed.code, 0, passed.stderr)
        XCTAssertEqual(passed.stdout, "Connected. Model local-fast is available.\n")
        XCTAssertFalse((passed.stdout + passed.stderr).contains(secret))

        let unavailableTransport = FakeTransport(
            response: OllamaHTTPResponse(statusCode: 200, data: Data("{\"data\":[]}".utf8))
        )
        let unavailable = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "doctor", "--profile=alice"],
            environment: [:],
            secretStore: fakeSecrets,
            gatewayTransport: unavailableTransport
        )
        XCTAssertEqual(unavailable.code, 1)
        XCTAssertEqual(
            unavailable.stderr,
            "Connected, but the selected model is not available to this key.\n"
        )
    }

    func testDoctorProbeAndHarnessStayOutOfNativeSlice() throws {
        try saveProfile()
        let transport = FakeTransport(
            response: OllamaHTTPResponse(statusCode: 200, data: Data("{\"data\":[]}".utf8))
        )
        let probe = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "doctor", "--profile", "alice", "--probe"],
            environment: [:],
            secretStore: fakeSecrets,
            gatewayTransport: transport
        )
        XCTAssertEqual(probe.code, 2)
        XCTAssertTrue(probe.stderr.contains("protocol probes are not ported"))
        XCTAssertEqual(transport.callCount, 0)

        let harness = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "doctor", "--profile", "alice",
             "--harness", "codex"],
            environment: [:],
            secretStore: fakeSecrets,
            gatewayTransport: transport
        )
        XCTAssertEqual(harness.code, 2)
        XCTAssertTrue(harness.stderr.contains("Use --harness only with --probe."))
        XCTAssertEqual(transport.callCount, 0)
        XCTAssertFalse((probe.stderr + harness.stderr).contains(secret))
    }

    private func resolvedProfile() -> ResolvedConnectionProfile {
        ResolvedConnectionProfile(
            name: "alice",
            endpoint: "https://models.example.test",
            secret: secret,
            model: "local-fast",
            contextWindow: 32768,
            codexCatalog: nil
        )
    }

    private func saveProfile() throws {
        try ProfileStore(directory: stateDirectory).saveNativeProfile(
            name: "alice",
            endpoint: "https://models.example.test",
            secret: secret,
            model: "local-fast",
            contextWindow: 32768,
            secretStore: fakeSecrets
        )
    }
}

private final class FakeTransport: OllamaHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let response: OllamaHTTPResponse
    private var capturedURL: URL?
    private var capturedBearerToken: String?
    private var calls = 0

    init(response: OllamaHTTPResponse) {
        self.response = response
    }

    var url: URL? {
        lock.withLock { capturedURL }
    }

    var bearerToken: String? {
        lock.withLock { capturedBearerToken }
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    func get(url: URL, bearerToken: String) throws -> OllamaHTTPResponse {
        lock.withLock {
            capturedURL = url
            capturedBearerToken = bearerToken
            calls += 1
        }
        return response
    }
}

private final class GatewayCheckFakeSecretStore: SecretStoring, @unchecked Sendable {
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
