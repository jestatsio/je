import Foundation
import XCTest
@testable import JECore

final class CredentialCommandTests: XCTestCase {
    private var temporary: URL!
    private var stateDirectory: URL!
    private var fakeSecrets: CredentialFakeSecretStore!
    private let secret = "synthetic-credential-key"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("je-credential-tests-" + UUID().uuidString, isDirectory: true)
        stateDirectory = temporary.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        fakeSecrets = CredentialFakeSecretStore()
    }

    override func tearDownWithError() throws {
        if let temporary {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    func testCredentialPrintsOnlyTheSavedKey() throws {
        try saveNativeProfile()
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "credential", "--profile", "alice"],
            environment: [:],
            secretStore: fakeSecrets
        )
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertEqual(result.stdout, secret + "\n")
        XCTAssertEqual(result.stderr, "")
    }

    func testCredentialAcceptsEqualsFormAndLegacyEmbeddedKey() throws {
        try saveLegacyProfile()
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "credential", "--profile=alice"],
            environment: [:],
            secretStore: fakeSecrets
        )
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertEqual(result.stdout, secret + "\n")
        XCTAssertEqual(result.stderr, "")
    }

    func testCredentialUnknownProfilePrintsNoKey() throws {
        try saveNativeProfile()
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "credential", "--profile", "nope"],
            environment: [:],
            secretStore: fakeSecrets
        )
        XCTAssertEqual(result.code, 2)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(result.stderr.contains("The requested private file does not exist."))
        XCTAssertFalse((result.stdout + result.stderr).contains(secret))
    }

    func testCredentialRejectsInvalidArgumentShapes() throws {
        try saveNativeProfile()
        let shapes: [[String]] = [
            ["credential"],
            ["credential", "--profile"],
            ["credential", "--profile="],
            ["credential", "--profile", "alice", "get"],
            ["credential", "--profile", "alice", "--profile", "alice"],
            ["credential", "--unknown", "alice"]
        ]
        for shape in shapes {
            let result = JECommandLine.run(
                ["--state-dir", stateDirectory.path] + shape,
                environment: [:],
                secretStore: fakeSecrets
            )
            XCTAssertEqual(result.code, 2, "shape should be invalid: \(shape)")
            XCTAssertTrue(result.stderr.contains("Invalid arguments."))
            XCTAssertEqual(result.stdout, "")
            XCTAssertFalse((result.stdout + result.stderr).contains(secret))
        }
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

    private func saveLegacyProfile() throws {
        let folder = stateDirectory.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = folder.appendingPathComponent("alice.json")
        let json = "{\"schema_version\":1,\"endpoint\":\"https://models.example.test\","
            + "\"api_key\":\"\(secret)\",\"model\":\"local-fast\",\"context_window\":32768}"
        try Data(json.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private final class CredentialFakeSecretStore: SecretStoring, @unchecked Sendable {
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
