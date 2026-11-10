import Foundation
import XCTest
@testable import JECore

final class CredentialMigrationTests: XCTestCase {
    private var temporary: URL!
    private var stateDirectory: URL!
    private var fakeSecrets: MigrationFakeSecretStore!
    private let gatewaySecret = "synthetic-migration-gateway-key"
    private let memorySecret = "synthetic-migration-memory-token"
    private let ollamaSecret = "synthetic-migration-ollama-key"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("je-migration-tests-" + UUID().uuidString, isDirectory: true)
        stateDirectory = temporary.appendingPathComponent("state", isDirectory: true)
        for folder in ["profiles", "memory-profiles", "ollama-profiles"] {
            let url = stateDirectory.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDirectory.path)
        fakeSecrets = MigrationFakeSecretStore()
    }

    override func tearDownWithError() throws {
        if let temporary {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    func testGatewayMigrateMovesEmbeddedSecretToReferenceAfterCheck() throws {
        let path = try writeGateway(name: "alice")
        let transport = MigrationHTTPTransport(
            response: OllamaHTTPResponse(
                statusCode: 200,
                data: Data("{\"data\":[{\"id\":\"local-fast\"}]}".utf8)
            )
        )
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "profile", "migrate", "alice"],
            environment: [:],
            secretStore: fakeSecrets,
            gatewayTransport: transport
        )
        XCTAssertEqual(result.code, 0, result.stderr + result.stdout)
        XCTAssertFalse((result.stdout + result.stderr).contains(gatewaySecret))
        XCTAssertTrue(result.stdout.contains("older backups"))
        XCTAssertEqual(transport.callCount, 1)
        XCTAssertEqual(transport.bearerToken, gatewaySecret)

        let raw = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"schema_version\" : 3"))
        XCTAssertTrue(raw.contains("secret_reference"))
        XCTAssertFalse(raw.contains(gatewaySecret))
        XCTAssertFalse(raw.contains("api_key"))
        XCTAssertEqual(fakeSecrets.count, 1)
        XCTAssertEqual(fakeSecrets.values.first, gatewaySecret)

        let store = ProfileStore(directory: stateDirectory)
        XCTAssertEqual(try store.gatewaySecretStorage(name: "alice"), .secretReference)
        XCTAssertEqual(try store.loadResolvedProfile(name: "alice", secretStore: fakeSecrets).secret, gatewaySecret)
        XCTAssertEqual(try store.loadPublicProfile(name: "alice").model, "local-fast")
        XCTAssertEqual(try store.loadPublicProfile(name: "alice").contextWindow, 32768)
    }

    func testGatewayMigrateCheckFailureLeavesFileUnchangedAndCleansSecret() throws {
        let path = try writeGateway(name: "alice")
        let before = try Data(contentsOf: path)
        let transport = MigrationHTTPTransport(
            response: OllamaHTTPResponse(
                statusCode: 200,
                data: Data("{\"data\":[]}".utf8)
            )
        )
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "profile", "migrate", "alice"],
            environment: [:],
            secretStore: fakeSecrets,
            gatewayTransport: transport
        )
        XCTAssertEqual(result.code, 1, result.stderr + result.stdout)
        XCTAssertFalse((result.stdout + result.stderr).contains(gatewaySecret))
        XCTAssertEqual(try Data(contentsOf: path), before)
        XCTAssertEqual(fakeSecrets.count, 0)
        XCTAssertEqual(
            try ProfileStore(directory: stateDirectory).gatewaySecretStorage(name: "alice"),
            .embeddedLegacy
        )
    }

    func testGatewayMigrateAlreadyMigratedIsNoOpWithoutCheck() throws {
        try ProfileStore(directory: stateDirectory).saveNativeProfile(
            name: "alice",
            endpoint: "https://models.example.test",
            secret: gatewaySecret,
            model: "local-fast",
            contextWindow: 32768,
            secretStore: fakeSecrets
        )
        let transport = MigrationHTTPTransport(
            response: OllamaHTTPResponse(statusCode: 500, data: Data())
        )
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "profile", "migrate", "alice"],
            environment: [:],
            secretStore: fakeSecrets,
            gatewayTransport: transport
        )
        XCTAssertEqual(result.code, 0, result.stderr + result.stdout)
        XCTAssertTrue(result.stdout.contains("already"))
        XCTAssertEqual(transport.callCount, 0)
        XCTAssertEqual(fakeSecrets.count, 1)
        XCTAssertFalse((result.stdout + result.stderr).contains(gatewaySecret))
    }

    func testGatewayMigrateDryRunWritesNothingAndSkipsCheck() throws {
        let path = try writeGateway(name: "alice")
        let before = try Data(contentsOf: path)
        let transport = MigrationHTTPTransport(
            response: OllamaHTTPResponse(statusCode: 500, data: Data())
        )
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "profile", "migrate", "alice", "--dry-run"],
            environment: [:],
            secretStore: fakeSecrets,
            gatewayTransport: transport
        )
        XCTAssertEqual(result.code, 0, result.stderr + result.stdout)
        XCTAssertEqual(try Data(contentsOf: path), before)
        XCTAssertEqual(fakeSecrets.count, 0)
        XCTAssertEqual(transport.callCount, 0)
        XCTAssertFalse((result.stdout + result.stderr).contains(gatewaySecret))
    }

    func testGatewayMigrateAllReportsMixedResultsAsJSON() throws {
        _ = try writeGateway(name: "alice", model: "local-fast")
        _ = try writeGateway(name: "bob", model: "missing-model")
        try ProfileStore(directory: stateDirectory).saveNativeProfile(
            name: "carol",
            endpoint: "https://models.example.test",
            secret: "synthetic-carol-key",
            model: "local-fast",
            contextWindow: nil,
            secretStore: fakeSecrets
        )
        let transport = MigrationHTTPTransport(
            response: OllamaHTTPResponse(
                statusCode: 200,
                data: Data("{\"data\":[{\"id\":\"local-fast\"}]}".utf8)
            )
        )
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "profile", "migrate", "--all", "--json"],
            environment: [:],
            secretStore: fakeSecrets,
            gatewayTransport: transport
        )
        XCTAssertEqual(result.code, 1, result.stderr + result.stdout)
        XCTAssertFalse((result.stdout + result.stderr).contains(gatewaySecret))
        XCTAssertFalse((result.stdout + result.stderr).contains("synthetic-carol-key"))

        let object = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        let results = try XCTUnwrap(object?["results"] as? [[String: Any]])
        XCTAssertEqual(results.count, 3)
        let byName = Dictionary(uniqueKeysWithValues: results.map { ($0["name"] as? String ?? "", $0) })
        XCTAssertEqual(byName["alice"]?["status"] as? String, "migrated")
        XCTAssertEqual(byName["alice"]?["check"] as? String, "passed")
        XCTAssertEqual(byName["bob"]?["status"] as? String, "failed")
        XCTAssertEqual(byName["bob"]?["check"] as? String, "failed")
        XCTAssertEqual(byName["carol"]?["status"] as? String, "already_migrated")
        XCTAssertNotNil(object?["backup_warning"])

        let store = ProfileStore(directory: stateDirectory)
        XCTAssertEqual(try store.gatewaySecretStorage(name: "alice"), .secretReference)
        XCTAssertEqual(try store.gatewaySecretStorage(name: "bob"), .embeddedLegacy)
        XCTAssertEqual(try store.gatewaySecretStorage(name: "carol"), .secretReference)
    }

    func testMemoryMigrateMovesTokenToReferenceAfterCheck() throws {
        let path = try writeMemory(name: "alice")
        let transport = MigrationMemoryTransport()
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "memory", "migrate", "alice"],
            environment: [:],
            secretStore: fakeSecrets,
            memoryTransport: transport
        )
        XCTAssertEqual(result.code, 0, result.stderr + result.stdout)
        XCTAssertFalse((result.stdout + result.stderr).contains(memorySecret))
        let raw = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"schema_version\" : 2"))
        XCTAssertTrue(raw.contains("secret_reference"))
        XCTAssertFalse(raw.contains(memorySecret))
        XCTAssertFalse(raw.contains("\"token\""))
        let store = ProfileStore(directory: stateDirectory)
        XCTAssertEqual(try store.loadPublicMemoryProfile(name: "alice").serverName, "je_memory_test")
        XCTAssertEqual(try store.loadResolvedMemoryProfile(name: "alice", secretStore: fakeSecrets).secret, memorySecret)
    }

    func testOllamaMigrateMovesKeyToReferenceAfterCheck() throws {
        let path = try writeOllama(name: "alice")
        let transport = MigrationHTTPTransport(
            response: OllamaHTTPResponse(
                statusCode: 200,
                data: Data("{\"models\":[{\"name\":\"local/model:latest\",\"model\":\"local/model:latest\"}]}".utf8)
            )
        )
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "ollama", "profile", "migrate", "alice"],
            environment: [:],
            secretStore: fakeSecrets,
            ollamaTransport: transport
        )
        XCTAssertEqual(result.code, 0, result.stderr + result.stdout)
        XCTAssertFalse((result.stdout + result.stderr).contains(ollamaSecret))
        let raw = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"schema_version\" : 2"))
        XCTAssertTrue(raw.contains("secret_reference"))
        XCTAssertFalse(raw.contains(ollamaSecret))
        XCTAssertFalse(raw.contains("api_key"))
        let store = ProfileStore(directory: stateDirectory)
        XCTAssertEqual(try store.loadResolvedOllamaProfile(name: "alice", secretStore: fakeSecrets).secret, ollamaSecret)
    }

    func testSecretStoreFailureLeavesGatewayFileUnchanged() throws {
        let path = try writeGateway(name: "alice")
        let before = try Data(contentsOf: path)
        let failing = MigrationFakeSecretStore(failOnSet: true)
        let transport = MigrationHTTPTransport(
            response: OllamaHTTPResponse(
                statusCode: 200,
                data: Data("{\"data\":[{\"id\":\"local-fast\"}]}".utf8)
            )
        )
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "profile", "migrate", "alice"],
            environment: [:],
            secretStore: failing,
            gatewayTransport: transport
        )
        XCTAssertEqual(result.code, 1, result.stderr + result.stdout)
        XCTAssertEqual(try Data(contentsOf: path), before)
        XCTAssertEqual(transport.callCount, 0)
        XCTAssertFalse((result.stdout + result.stderr).contains(gatewaySecret))
    }

    @discardableResult
    private func writeGateway(name: String, model: String = "local-fast") throws -> URL {
        let json = "{\"schema_version\":1,\"endpoint\":\"https://models.example.test/v1\","
            + "\"api_key\":\"\(gatewaySecret)\",\"model\":\"\(model)\",\"context_window\":32768}"
        return try write(json, folder: "profiles", name: name)
    }

    @discardableResult
    private func writeMemory(name: String) throws -> URL {
        let json = "{\"schema_version\":1,\"endpoint\":\"https://memory.example.test/mcp\","
            + "\"token\":\"\(memorySecret)\",\"server_name\":\"je_memory_test\"}"
        return try write(json, folder: "memory-profiles", name: name)
    }

    @discardableResult
    private func writeOllama(name: String) throws -> URL {
        let json = "{\"schema_version\":1,\"endpoint\":\"https://native.example.test/ollama\","
            + "\"api_key\":\"\(ollamaSecret)\",\"model\":\"local/model:latest\"}"
        return try write(json, folder: "ollama-profiles", name: name)
    }

    private func write(_ json: String, folder: String, name: String) throws -> URL {
        let path = stateDirectory
            .appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent(name + ".json")
        try Data(json.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        return path
    }
}

private final class MigrationHTTPTransport: OllamaHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let response: OllamaHTTPResponse
    private var capturedBearerToken: String?
    private var calls = 0

    init(response: OllamaHTTPResponse) {
        self.response = response
    }

    var bearerToken: String? {
        lock.withLock { capturedBearerToken }
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    func get(url: URL, bearerToken: String) throws -> OllamaHTTPResponse {
        lock.withLock {
            capturedBearerToken = bearerToken
            calls += 1
        }
        return response
    }
}

private final class MigrationMemoryTransport: MemoryHTTPTransport, @unchecked Sendable {
    private var toolsPage = 0

    func post(_ request: MemoryHTTPRequest) throws -> MemoryHTTPResponse {
        let object = try JSONSerialization.jsonObject(with: request.body, options: []) as? [String: Any]
        let method = object?["method"] as? String ?? ""
        switch method {
        case "initialize":
            return MemoryHTTPResponse(
                statusCode: 200,
                headers: ["mcp-session-id": "session-123", "content-type": "application/json"],
                data: Data(
                    "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{},\"serverInfo\":{\"name\":\"fake\",\"version\":\"1\"}}}".utf8
                )
            )
        case "notifications/initialized":
            return MemoryHTTPResponse(statusCode: 202, headers: [:], data: Data())
        case "tools/list":
            toolsPage += 1
            if toolsPage == 1 {
                return sseResponse(
                    id: 2,
                    names: ["search_memories", "list_memories", "get_memory", "memory_history", "memory_operation_status"],
                    nextCursor: "page-2"
                )
            }
            return sseResponse(
                id: 3,
                names: ["save_memory", "edit_memory", "undo_memory", "delete_memory", "restore_memory"],
                nextCursor: nil
            )
        default:
            return MemoryHTTPResponse(statusCode: 400, headers: [:], data: Data())
        }
    }

    private func sseResponse(id: Int, names: [String], nextCursor: String?) -> MemoryHTTPResponse {
        let tools = names.map { "{\"name\":\"\($0)\"}" }.joined(separator: ",")
        let cursor = nextCursor.map { ",\"nextCursor\":\"\($0)\"" } ?? ""
        let json = "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":{\"tools\":[\(tools)]\(cursor)}}"
        return MemoryHTTPResponse(
            statusCode: 200,
            headers: ["content-type": "text/event-stream"],
            data: Data("event: message\ndata: \(json)\n\n".utf8)
        )
    }
}

private final class MigrationFakeSecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]
    private let failOnSet: Bool

    init(failOnSet: Bool = false) {
        self.failOnSet = failOnSet
    }

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
        if failOnSet {
            throw SecretStoreError.operationFailed
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
