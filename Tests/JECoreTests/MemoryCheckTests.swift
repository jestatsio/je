import Foundation
import XCTest
@testable import JECore

final class MemoryCheckTests: XCTestCase {
    private var temporary: URL!
    private var stateDirectory: URL!
    private var fakeSecrets: MemoryCheckFakeSecretStore!
    private let secret = "synthetic-memory-check-token"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("je-memory-check-tests-" + UUID().uuidString, isDirectory: true)
        stateDirectory = temporary.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        fakeSecrets = MemoryCheckFakeSecretStore()
    }

    override func tearDownWithError() throws {
        if let temporary {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    func testCheckerInitializesPagesToolsAndReportsReadWriteAvailability() throws {
        let transport = FakeTransport()
        let report = try MemoryConnectionChecker.check(
            profile: resolvedProfile(),
            transport: transport
        )
        XCTAssertTrue(report.passed)
        XCTAssertEqual(report.protocolVersion, "2025-03-26")
        XCTAssertEqual(report.toolCount, 10)
        XCTAssertTrue(report.readAvailable)
        XCTAssertTrue(report.writeAvailable)
        XCTAssertEqual(transport.methods, ["initialize", "notifications/initialized", "tools/list", "tools/list"])
        if let firstSessionID = transport.sessionIDs.first {
            XCTAssertNil(firstSessionID)
        } else {
            XCTFail("Expected one initialize request")
        }
        XCTAssertEqual(transport.sessionIDs.dropFirst().compactMap { $0 }, Array(repeating: "session-123", count: 3))
        XCTAssertTrue(transport.bearerTokens.allSatisfy { $0 == secret })
        XCTAssertFalse(transport.bodiesText.contains(secret))
    }

    func testCheckerReportsUnavailableWhenReadToolsMissing() throws {
        let transport = FakeTransport(includeAllReadTools: false)
        let report = try MemoryConnectionChecker.check(
            profile: resolvedProfile(),
            transport: transport
        )
        XCTAssertFalse(report.passed)
        XCTAssertFalse(report.readAvailable)
        XCTAssertEqual(report.toolCount, 9)
    }

    func testCheckerRejectsJSONRPCErrorWithoutResponseContents() {
        let transport = FakeTransport(failToolsList: true)
        XCTAssertThrowsError(
            try MemoryConnectionChecker.check(profile: resolvedProfile(), transport: transport)
        ) { error in
            XCTAssertEqual(
                (error as? MemoryCheckError)?.message,
                "The memory service could not be checked. Verify its address and credential."
            )
            XCTAssertFalse(String(describing: error).contains(secret))
        }
    }

    func testMemoryCheckCommandReturnsReportAndDoesNotEchoToken() throws {
        try saveProfile()
        let transport = FakeTransport()
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "memory", "check", "alice"],
            environment: [:],
            secretStore: fakeSecrets,
            memoryTransport: transport
        )
        XCTAssertEqual(result.code, 0, result.stderr)
        let decoded = try JSONDecoder().decode(MemoryCheckReport.self, from: Data(result.stdout.utf8))
        XCTAssertTrue(decoded.passed)
        XCTAssertEqual(decoded.toolCount, 10)
        XCTAssertFalse((result.stdout + result.stderr).contains(secret))
        XCTAssertFalse(result.stdout.contains("search_memories"))
    }

    func testMemoryCheckCommandReturnsOneWhenReadToolsUnavailable() throws {
        try saveProfile()
        let transport = FakeTransport(includeAllReadTools: false)
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "memory", "check", "alice"],
            environment: [:],
            secretStore: fakeSecrets,
            memoryTransport: transport
        )
        XCTAssertEqual(result.code, 1)
        let decoded = try JSONDecoder().decode(MemoryCheckReport.self, from: Data(result.stdout.utf8))
        XCTAssertFalse(decoded.passed)
    }

    private func resolvedProfile() -> ResolvedMemoryProfile {
        ResolvedMemoryProfile(
            name: "alice",
            endpoint: "https://memory.example.test/prefix/mcp",
            secret: secret,
            serverName: "je_memory_test"
        )
    }

    private func saveProfile() throws {
        try ProfileStore(directory: stateDirectory).saveNativeMemoryProfile(
            name: "alice",
            endpoint: "https://memory.example.test/prefix/mcp",
            secret: secret,
            secretStore: fakeSecrets
        )
    }
}

private final class FakeTransport: MemoryHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let includeAllReadTools: Bool
    private let failToolsList: Bool
    private var capturedMethods: [String] = []
    private var capturedSessionIDs: [String?] = []
    private var capturedBearerTokens: [String] = []
    private var capturedBodies: [Data] = []
    private var toolsPage = 0

    init(includeAllReadTools: Bool = true, failToolsList: Bool = false) {
        self.includeAllReadTools = includeAllReadTools
        self.failToolsList = failToolsList
    }

    var methods: [String] {
        lock.withLock { capturedMethods }
    }

    var sessionIDs: [String?] {
        lock.withLock { capturedSessionIDs }
    }

    var bearerTokens: [String] {
        lock.withLock { capturedBearerTokens }
    }

    var bodiesText: String {
        lock.withLock { capturedBodies.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") }
    }

    func post(_ request: MemoryHTTPRequest) throws -> MemoryHTTPResponse {
        let object = try JSONSerialization.jsonObject(with: request.body, options: []) as? [String: Any]
        let method = object?["method"] as? String ?? ""
        lock.withLock {
            capturedMethods.append(method)
            capturedSessionIDs.append(request.sessionID)
            capturedBearerTokens.append(request.bearerToken)
            capturedBodies.append(request.body)
        }
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
            if failToolsList {
                return MemoryHTTPResponse(
                    statusCode: 200,
                    headers: ["content-type": "application/json"],
                    data: Data(
                        "{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32000,\"message\":\"synthetic failure\"}}".utf8
                    )
                )
            }
            toolsPage += 1
            if toolsPage == 1 {
                let names = includeAllReadTools
                    ? ["search_memories", "list_memories", "get_memory", "memory_history", "memory_operation_status"]
                    : ["search_memories", "list_memories", "get_memory", "memory_history"]
                return sseResponse(id: 2, names: names, nextCursor: "page-2")
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

private final class MemoryCheckFakeSecretStore: SecretStoring, @unchecked Sendable {
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
