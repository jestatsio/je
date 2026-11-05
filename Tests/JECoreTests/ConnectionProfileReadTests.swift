import Foundation
import XCTest
@testable import JECore

final class ConnectionProfileReadTests: XCTestCase {
    private var temporary: URL!
    private var stateDirectory: URL!
    private var store: ProfileStore!
    private let memorySecret = "private-memory-swift-secret"
    private let ollamaSecret = "private-ollama-swift-secret"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("je-connection-tests-" + UUID().uuidString, isDirectory: true)
        stateDirectory = temporary.appendingPathComponent("state", isDirectory: true)
        for folder in ["memory-profiles", "ollama-profiles"] {
            let url = stateDirectory.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDirectory.path)
        store = ProfileStore(directory: stateDirectory)
    }

    override func tearDownWithError() throws {
        if let temporary {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    func testMemoryListAndShowPreserveEndpointWithoutToken() throws {
        try writeMemory(name: "zoe")
        try writeMemory(name: "alice")

        XCTAssertEqual(try store.listMemoryProfiles(), ["alice", "zoe"])
        let shown = try store.loadPublicMemoryProfile(name: "alice")
        XCTAssertEqual(shown.endpoint, "https://memory.example.test/prefix/v1/mcp/")
        XCTAssertEqual(shown.serverName, "je_memory_test")

        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "memory", "show", "alice"],
            environment: [:]
        )
        XCTAssertEqual(result.code, 0)
        XCTAssertTrue(result.stdout.contains("server_name"))
        XCTAssertFalse((result.stdout + result.stderr).contains(memorySecret))
        XCTAssertFalse(result.stdout.contains("\"token\""))
    }

    func testMemoryDuplicateAndUnknownFieldsAreRejectedWithoutToken() throws {
        let path = try writeMemory(name: "alice")
        let valid = try String(contentsOf: path, encoding: .utf8)
        try Data(valid.replacingOccurrences(
            of: "\"schema_version\":1",
            with: "\"schema_version\":1,\"schema_version\":1"
        ).utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        XCTAssertThrowsError(try store.loadPublicMemoryProfile(name: "alice")) { error in
            XCTAssertFalse(String(describing: error).contains(memorySecret))
        }

        let unknown = valid.replacingOccurrences(of: "}", with: ",\"extra\":\"\(memorySecret)\"}")
        try Data(unknown.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        XCTAssertThrowsError(try store.loadPublicMemoryProfile(name: "alice")) { error in
            XCTAssertFalse(String(describing: error).contains(memorySecret))
        }
    }

    func testOllamaListAndShowNormalizeRootWithoutCredential() throws {
        try writeOllama(name: "zoe")
        try writeOllama(name: "alice")

        XCTAssertEqual(try store.listOllamaProfiles(), ["alice", "zoe"])
        let shown = try store.loadPublicOllamaProfile(name: "alice")
        XCTAssertEqual(shown.endpoint, "https://native.example.test/ollama")
        XCTAssertEqual(shown.model, "local/model:latest")

        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "ollama", "profile", "show", "alice"],
            environment: [:]
        )
        XCTAssertEqual(result.code, 0)
        XCTAssertFalse((result.stdout + result.stderr).contains(ollamaSecret))
        XCTAssertFalse(result.stdout.contains("api_key"))
    }

    func testOllamaRejectsRemoteHTTPRemoteAndV1Roots() throws {
        let path = try writeOllama(name: "alice", endpoint: "http://remote.example.test/ollama")
        XCTAssertThrowsError(try store.loadPublicOllamaProfile(name: "alice")) { error in
            XCTAssertFalse(String(describing: error).contains(ollamaSecret))
        }
        try FileManager.default.removeItem(at: path)
        _ = try writeOllama(name: "alice", endpoint: "https://native.example.test/v1")
        XCTAssertThrowsError(try store.loadPublicOllamaProfile(name: "alice"))
    }

    func testMalformedMemoryAndOllamaWritesDoNotEcho() {
        let memory = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "memory", "add", "alice", "--token-env", memorySecret],
            environment: [:]
        )
        XCTAssertEqual(memory.code, 2)
        XCTAssertFalse((memory.stdout + memory.stderr).contains(memorySecret))

        let ollama = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "ollama", "profile", "add", "alice", "--key-env", ollamaSecret],
            environment: [:]
        )
        XCTAssertEqual(ollama.code, 2)
        XCTAssertFalse((ollama.stdout + ollama.stderr).contains(ollamaSecret))
    }

    @discardableResult
    private func writeMemory(name: String) throws -> URL {
        let json = "{\"schema_version\":1,\"endpoint\":\"https://memory.example.test/prefix/v1/mcp/\""
            + ",\"token\":\"\(memorySecret)\",\"server_name\":\"je_memory_test\"}"
        return try write(json, folder: "memory-profiles", name: name)
    }

    @discardableResult
    private func writeOllama(
        name: String,
        endpoint: String = "https://native.example.test/ollama/"
    ) throws -> URL {
        let json = "{\"schema_version\":1,\"endpoint\":\"\(endpoint)\""
            + ",\"api_key\":\"\(ollamaSecret)\",\"model\":\"local/model:latest\"}"
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
