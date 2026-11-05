import Foundation
import XCTest
@testable import JECore

final class ConnectionProfileWriteTests: XCTestCase {
    private var temporary: URL!
    private var stateDirectory: URL!
    private var fakeSecrets: ConnectionFakeSecretStore!
    private let memorySecret = "synthetic-memory-token"
    private let replacementMemorySecret = "synthetic-memory-replacement"
    private let ollamaSecret = "synthetic-ollama-key"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("je-connection-write-tests-" + UUID().uuidString, isDirectory: true)
        stateDirectory = temporary.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        fakeSecrets = ConnectionFakeSecretStore()
    }

    override func tearDownWithError() throws {
        if let temporary {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    func testMemoryAddStoresTokenOutsideProfileAndRoundTrips() throws {
        let result = run(memoryAddArguments())
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertFalse((result.stdout + result.stderr).contains(memorySecret))

        let raw = try String(contentsOf: memoryProfileURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"schema_version\" : 2"))
        XCTAssertTrue(raw.contains("secret_reference"))
        XCTAssertTrue(raw.contains("memory/profile/alice/"))
        XCTAssertFalse(raw.contains("\"token\""))
        XCTAssertFalse(raw.contains(memorySecret))
        XCTAssertEqual(try permissions(of: memoryProfileURL), 0o600)
        XCTAssertEqual(fakeSecrets.count, 1)

        let store = ProfileStore(directory: stateDirectory)
        XCTAssertEqual(try store.listMemoryProfiles(), ["alice"])
        let shown = try store.loadPublicMemoryProfile(name: "alice")
        XCTAssertEqual(shown.endpoint, "https://memory.example.test/prefix/v1/mcp/")
        XCTAssertTrue(shown.serverName.hasPrefix("je_memory_"))
        XCTAssertEqual(shown.serverName.count, "je_memory_".count + 32)
        XCTAssertTrue(shown.serverName.dropFirst("je_memory_".count).allSatisfy {
            $0.isNumber || ("a"..."f").contains($0)
        })

        let resolved = try store.loadResolvedMemoryProfile(
            name: "alice",
            secretStore: fakeSecrets
        )
        XCTAssertEqual(resolved.secret, memorySecret)
        XCTAssertEqual(resolved.serverName, shown.serverName)
    }

    func testMemoryReplacePreservesServerNameAndRotatesSecret() throws {
        XCTAssertEqual(run(memoryAddArguments()).code, 0)
        let store = ProfileStore(directory: stateDirectory)
        let originalServerName = try store.loadPublicMemoryProfile(name: "alice").serverName

        let duplicate = run(memoryAddArguments())
        XCTAssertEqual(duplicate.code, 2)
        XCTAssertEqual(fakeSecrets.count, 1)

        let replaced = run(
            memoryAddArguments() + ["--replace"],
            environment: ["JE_MEMORY_TOKEN": replacementMemorySecret]
        )
        XCTAssertEqual(replaced.code, 0, replaced.stderr)
        XCTAssertEqual(fakeSecrets.count, 1)
        XCTAssertEqual(fakeSecrets.values, [replacementMemorySecret])
        XCTAssertEqual(
            try store.loadPublicMemoryProfile(name: "alice").serverName,
            originalServerName
        )
        XCTAssertFalse((replaced.stdout + replaced.stderr).contains(replacementMemorySecret))
    }

    func testMemoryRemoveDeletesSecretOnlyWhenRequested() throws {
        XCTAssertEqual(run(memoryAddArguments()).code, 0)
        let removed = run(["memory", "remove", "alice"], environment: [:])
        XCTAssertEqual(removed.code, 0, removed.stderr)
        XCTAssertEqual(fakeSecrets.count, 1)

        XCTAssertEqual(run(memoryAddArguments()).code, 0)
        XCTAssertEqual(fakeSecrets.count, 2)
        let removedWithSecret = run(
            ["memory", "remove", "alice", "--delete-secret"],
            environment: [:]
        )
        XCTAssertEqual(removedWithSecret.code, 0, removedWithSecret.stderr)
        XCTAssertEqual(fakeSecrets.count, 1)
    }

    func testOllamaAddFromKeyFileStoresKeyOutsideProfileAndRoundTrips() throws {
        let keyFile = temporary.appendingPathComponent("ollama-key")
        try Data((ollamaSecret + "\n").utf8).write(to: keyFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)

        let result = run(
            [
                "ollama", "profile", "add", "alice",
                "--endpoint", "https://native.example.test/ollama/",
                "--model", "local/model:latest",
                "--key-file", keyFile.path
            ],
            environment: [:]
        )
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertFalse((result.stdout + result.stderr).contains(ollamaSecret))

        let raw = try String(contentsOf: ollamaProfileURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"schema_version\" : 2"))
        XCTAssertTrue(raw.contains("ollama/profile/alice/"))
        XCTAssertFalse(raw.contains("api_key"))
        XCTAssertFalse(raw.contains(ollamaSecret))
        XCTAssertEqual(try permissions(of: ollamaProfileURL), 0o600)
        XCTAssertEqual(fakeSecrets.count, 1)

        let store = ProfileStore(directory: stateDirectory)
        XCTAssertEqual(try store.listOllamaProfiles(), ["alice"])
        let shown = try store.loadPublicOllamaProfile(name: "alice")
        XCTAssertEqual(shown.endpoint, "https://native.example.test/ollama")
        XCTAssertEqual(shown.model, "local/model:latest")

        let resolved = try store.loadResolvedOllamaProfile(
            name: "alice",
            secretStore: fakeSecrets
        )
        XCTAssertEqual(resolved.secret, ollamaSecret)
        XCTAssertEqual(resolved.endpoint, shown.endpoint)
    }

    func testOllamaInvalidEndpointSavesNeitherProfileNorSecret() {
        let result = run(
            [
                "ollama", "profile", "add", "alice",
                "--endpoint", "https://native.example.test/v1",
                "--model", "local/model:latest",
                "--key-env", "JE_OLLAMA_KEY"
            ],
            environment: ["JE_OLLAMA_KEY": ollamaSecret]
        )
        XCTAssertEqual(result.code, 2)
        XCTAssertFalse((result.stdout + result.stderr).contains(ollamaSecret))
        XCTAssertEqual(fakeSecrets.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ollamaProfileURL.path))
    }

    func testOllamaRemoveDeletesSecretOnlyWhenRequested() {
        XCTAssertEqual(
            run(ollamaAddArguments(), environment: ["JE_OLLAMA_KEY": ollamaSecret]).code,
            0
        )
        let removed = run(
            ["ollama", "profile", "remove", "alice", "--delete-secret"],
            environment: [:]
        )
        XCTAssertEqual(removed.code, 0, removed.stderr)
        XCTAssertEqual(fakeSecrets.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ollamaProfileURL.path))
    }

    private var memoryProfileURL: URL {
        stateDirectory.appendingPathComponent("memory-profiles/alice.json")
    }

    private var ollamaProfileURL: URL {
        stateDirectory.appendingPathComponent("ollama-profiles/alice.json")
    }

    private func run(
        _ suffix: [String],
        environment: [String: String]? = nil
    ) -> CLIResult {
        JECommandLine.run(
            ["--state-dir", stateDirectory.path] + suffix,
            environment: environment ?? ["JE_MEMORY_TOKEN": memorySecret],
            secretStore: fakeSecrets
        )
    }

    private func memoryAddArguments() -> [String] {
        [
            "memory", "add", "alice",
            "--endpoint", "https://memory.example.test/prefix/v1/mcp/",
            "--token-env", "JE_MEMORY_TOKEN"
        ]
    }

    private func ollamaAddArguments() -> [String] {
        [
            "ollama", "profile", "add", "alice",
            "--endpoint", "https://native.example.test/ollama",
            "--model", "local/model:latest",
            "--key-env", "JE_OLLAMA_KEY"
        ]
    }

    private func permissions(of url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        return value?.intValue ?? -1
    }
}

private final class ConnectionFakeSecretStore: SecretStoring, @unchecked Sendable {
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
