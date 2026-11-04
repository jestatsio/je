import Foundation
import XCTest
@testable import JECore

final class ProfileWriteTests: XCTestCase {
    private var temporary: URL!
    private var stateDirectory: URL!
    private var fakeSecrets: FakeSecretStore!
    private let secret = "synthetic-native-profile-secret"
    private let replacementSecret = "synthetic-replacement-secret"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("je-profile-write-tests-" + UUID().uuidString, isDirectory: true)
        stateDirectory = temporary.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        fakeSecrets = FakeSecretStore()
    }

    override func tearDownWithError() throws {
        if let temporary {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    func testAddStoresSecretOutsideProfileAndRoundTrips() throws {
        let result = run(addArguments())
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertFalse((result.stdout + result.stderr).contains(secret))

        let raw = try String(contentsOf: profileURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"schema_version\" : 3"))
        XCTAssertTrue(raw.contains("secret_reference"))
        XCTAssertFalse(raw.contains(secret))
        XCTAssertFalse(raw.contains("api_key"))
        XCTAssertEqual(try permissions(of: profileURL), 0o600)
        XCTAssertEqual(fakeSecrets.count, 1)

        let store = ProfileStore(directory: stateDirectory)
        XCTAssertEqual(try store.listProfiles(), ["alice"])
        XCTAssertEqual(try store.loadPublicProfile(name: "alice").model, "local-fast")
        let resolved = try store.loadResolvedProfile(name: "alice", secretStore: fakeSecrets)
        XCTAssertEqual(resolved.secret, secret)
        XCTAssertEqual(resolved.apiBase, "https://models.example.test/v1")
    }

    func testAddFromPrivateKeyFile() throws {
        let keyFile = temporary.appendingPathComponent("key")
        try Data((secret + "\n").utf8).write(to: keyFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        var arguments = addArguments()
        if let index = arguments.firstIndex(of: "--key-env") {
            arguments[index] = "--key-file"
            arguments[index + 1] = keyFile.path
        }
        let result = run(arguments, environment: [:])
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertEqual(fakeSecrets.count, 1)
    }

    func testInsecureKeyFileIsRejectedBeforeSecretStoreWrite() throws {
        let keyFile = temporary.appendingPathComponent("key")
        try Data(secret.utf8).write(to: keyFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: keyFile.path)
        var arguments = addArguments()
        if let index = arguments.firstIndex(of: "--key-env") {
            arguments[index] = "--key-file"
            arguments[index + 1] = keyFile.path
        }
        let result = run(arguments, environment: [:])
        XCTAssertEqual(result.code, 2)
        XCTAssertEqual(fakeSecrets.count, 0)
        XCTAssertFalse((result.stdout + result.stderr).contains(secret))
        XCTAssertEqual(try permissions(of: keyFile), 0o644)
    }

    func testReplaceRotatesReferenceAndDeletesOldSecret() {
        XCTAssertEqual(run(addArguments()).code, 0)
        XCTAssertEqual(run(addArguments()).code, 2)
        let replaced = JECommandLine.run(
            ["--state-dir", stateDirectory.path] + addArguments() + ["--replace"],
            environment: ["JE_TEST_KEY": replacementSecret],
            secretStore: fakeSecrets
        )
        XCTAssertEqual(replaced.code, 0, replaced.stderr)
        XCTAssertEqual(fakeSecrets.count, 1)
        XCTAssertEqual(fakeSecrets.values.first, replacementSecret)
        XCTAssertFalse((replaced.stdout + replaced.stderr).contains(replacementSecret))
    }

    func testRemoveDeletesSecretOnlyWhenExplicitlyRequested() throws {
        XCTAssertEqual(run(addArguments()).code, 0)
        let removed = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "profile", "remove", "alice"],
            environment: [:],
            secretStore: fakeSecrets
        )
        XCTAssertEqual(removed.code, 0)
        XCTAssertEqual(fakeSecrets.count, 1)

        let secondAdd = JECommandLine.run(
            ["--state-dir", stateDirectory.path] + addArguments(),
            environment: ["JE_TEST_KEY": replacementSecret],
            secretStore: fakeSecrets
        )
        XCTAssertEqual(secondAdd.code, 0)
        XCTAssertEqual(fakeSecrets.count, 2)
        let removedWithSecret = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "profile", "remove", "alice", "--delete-secret"],
            environment: [:],
            secretStore: fakeSecrets
        )
        XCTAssertEqual(removedWithSecret.code, 0)
        XCTAssertEqual(fakeSecrets.count, 1)
        XCTAssertEqual(fakeSecrets.values, [secret])
    }

    func testSecretReferenceValidationRejectsTraversal() {
        XCTAssertTrue(SecretReferenceValidator.isValid("gateway/profile/alice/123"))
        XCTAssertFalse(SecretReferenceValidator.isValid("../escape"))
        XCTAssertFalse(SecretReferenceValidator.isValid("/absolute"))
        XCTAssertFalse(SecretReferenceValidator.isValid("has space"))
    }

    private var profileURL: URL {
        stateDirectory.appendingPathComponent("profiles/alice.json")
    }

    private func run(
        _ suffix: [String],
        environment: [String: String]? = nil
    ) -> CLIResult {
        JECommandLine.run(
            ["--state-dir", stateDirectory.path] + suffix,
            environment: environment ?? ["JE_TEST_KEY": secret],
            secretStore: fakeSecrets
        )
    }

    private func addArguments() -> [String] {
        [
            "profile", "add", "alice",
            "--endpoint", "https://models.example.test/v1",
            "--model", "local-fast",
            "--context-window", "32768",
            "--key-env", "JE_TEST_KEY"
        ]
    }

    private func permissions(of url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        return value?.intValue ?? -1
    }
}

private final class FakeSecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    var count: Int {
        lock.withLock { storage.count }
    }

    var values: [String] {
        lock.withLock { Array(storage.values) }
    }

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
