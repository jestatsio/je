import Foundation
import XCTest
@testable import JECore

final class OllamaCheckTests: XCTestCase {
    private var temporary: URL!
    private var stateDirectory: URL!
    private var fakeSecrets: OllamaCheckFakeSecretStore!
    private let secret = "synthetic-ollama-check-key"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("je-ollama-check-tests-" + UUID().uuidString, isDirectory: true)
        stateDirectory = temporary.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        fakeSecrets = OllamaCheckFakeSecretStore()
    }

    override func tearDownWithError() throws {
        if let temporary {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    func testCheckerPassesWithTaggedNameAndUsesBearerHeaderValue() throws {
        let transport = FakeTransport(
            response: OllamaHTTPResponse(
                statusCode: 200,
                data: Data("{\"models\":[{\"name\":\"local/model:latest\"}]}".utf8)
            )
        )
        let report = try OllamaConnectionChecker.check(profile: resolvedProfile(), transport: transport)
        XCTAssertTrue(report.passed)
        XCTAssertTrue(report.authenticated)
        XCTAssertEqual(report.model, "local/model")
        XCTAssertTrue(report.modelAvailable)
        XCTAssertEqual(transport.url?.absoluteString, "https://native.example.test/ollama/api/tags")
        XCTAssertEqual(transport.bearerToken, secret)
    }

    func testCheckerReportsUnavailableForEmptyListing() throws {
        let transport = FakeTransport(
            response: OllamaHTTPResponse(statusCode: 200, data: Data("{\"models\":[]}".utf8))
        )
        let report = try OllamaConnectionChecker.check(profile: resolvedProfile(), transport: transport)
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.authenticated)
        XCTAssertFalse(report.modelAvailable)
    }

    func testCheckerRejectsMismatchedModelAndName() {
        let transport = FakeTransport(
            response: OllamaHTTPResponse(
                statusCode: 200,
                data: Data("{\"models\":[{\"model\":\"local/model:latest\",\"name\":\"other:latest\"}]}".utf8)
            )
        )
        XCTAssertThrowsError(
            try OllamaConnectionChecker.check(profile: resolvedProfile(), transport: transport)
        ) { error in
            XCTAssertEqual(
                (error as? OllamaCheckError)?.message,
                "The native Ollama service did not return a valid model listing."
            )
            XCTAssertFalse(String(describing: error).contains(secret))
        }
    }

    func testCheckerHTTPFailureExposesStatusOnly() {
        let transport = FakeTransport(
            response: OllamaHTTPResponse(statusCode: 401, data: Data(secret.utf8))
        )
        XCTAssertThrowsError(
            try OllamaConnectionChecker.check(profile: resolvedProfile(), transport: transport)
        ) { error in
            XCTAssertEqual(
                (error as? OllamaCheckError)?.message,
                "Native Ollama connection failed with HTTP 401."
            )
            XCTAssertFalse(String(describing: error).contains(secret))
        }
    }

    func testCheckerRejectsOversizedListing() {
        let transport = FakeTransport(
            response: OllamaHTTPResponse(
                statusCode: 200,
                data: Data(repeating: 32, count: 1_048_577)
            )
        )
        XCTAssertThrowsError(
            try OllamaConnectionChecker.check(profile: resolvedProfile(), transport: transport)
        ) { error in
            XCTAssertEqual(
                (error as? OllamaCheckError)?.message,
                "The native Ollama model listing exceeded the supported size."
            )
        }
    }

    func testCommandCheckPassesAndUnavailableReturnsOne() throws {
        try saveProfile()
        let passing = FakeTransport(
            response: OllamaHTTPResponse(
                statusCode: 200,
                data: Data("{\"models\":[{\"model\":\"local/model\"}]}".utf8)
            )
        )
        let passed = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "ollama", "--profile", "alice", "check"],
            environment: [:],
            secretStore: fakeSecrets,
            ollamaTransport: passing
        )
        XCTAssertEqual(passed.code, 0, passed.stderr)
        XCTAssertEqual(passed.stdout, "Connected. Native model local/model is available.\n")
        XCTAssertFalse((passed.stdout + passed.stderr).contains(secret))

        let unavailableTransport = FakeTransport(
            response: OllamaHTTPResponse(statusCode: 200, data: Data("{\"models\":[]}".utf8))
        )
        let unavailable = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "ollama", "--profile=alice", "check"],
            environment: [:],
            secretStore: fakeSecrets,
            ollamaTransport: unavailableTransport
        )
        XCTAssertEqual(unavailable.code, 1)
        XCTAssertEqual(
            unavailable.stderr,
            "Connected, but the default native model is not available to this key.\n"
        )
        XCTAssertFalse((unavailable.stdout + unavailable.stderr).contains(secret))
    }

    func testCommandRejectsExecutableWithCheckAndMissingProfile() throws {
        try saveProfile()
        let transport = FakeTransport(
            response: OllamaHTTPResponse(statusCode: 200, data: Data("{\"models\":[]}".utf8))
        )
        let withExecutable = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "ollama", "--profile", "alice",
             "--executable", "/tmp/ollama", "check"],
            environment: [:],
            secretStore: fakeSecrets,
            ollamaTransport: transport
        )
        XCTAssertEqual(withExecutable.code, 2)
        XCTAssertEqual(transport.callCount, 0)

        let missingProfile = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "ollama", "check"],
            environment: [:],
            secretStore: fakeSecrets,
            ollamaTransport: transport
        )
        XCTAssertEqual(missingProfile.code, 2)
        XCTAssertEqual(transport.callCount, 0)
        XCTAssertFalse((withExecutable.stderr + missingProfile.stderr).contains(secret))
    }

    private func resolvedProfile() -> ResolvedOllamaProfile {
        ResolvedOllamaProfile(
            name: "alice",
            endpoint: "https://native.example.test/ollama",
            secret: secret,
            model: "local/model"
        )
    }

    private func saveProfile() throws {
        try ProfileStore(directory: stateDirectory).saveNativeOllamaProfile(
            name: "alice",
            endpoint: "https://native.example.test/ollama",
            secret: secret,
            model: "local/model",
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

private final class OllamaCheckFakeSecretStore: SecretStoring, @unchecked Sendable {
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
