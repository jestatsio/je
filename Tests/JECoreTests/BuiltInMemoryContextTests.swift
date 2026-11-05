import Foundation
import XCTest
@testable import JECore

final class BuiltInMemoryContextTests: XCTestCase {
    private var temporary: URL!
    private var stateDirectory: URL!
    private var fakeSecrets: MemoryContextFakeSecretStore!
    private let ollamaSecret = "synthetic-builtin-key"
    private let memorySecret = "synthetic-memory-context-token"
    private let prompt = "Summarize this in one short answer."
    private let answer = "synthetic built-in answer"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("je-builtin-memory-tests-" + UUID().uuidString, isDirectory: true)
        stateDirectory = temporary.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        fakeSecrets = MemoryContextFakeSecretStore()
    }

    override func tearDownWithError() throws {
        if let temporary {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    func testFetcherReturnsSearchSectionsInQueryOrder() throws {
        let transport = FakeMemoryTransport(pages: [readOnlyTools()])
        transport.resultsByQuery = [
            "travel": "memory about travel\n",
            "recipes": "memory about recipes\n"
        ]
        let sections = try MemoryContextFetcher.fetch(
            profile: resolvedMemoryProfile(),
            queries: ["travel", "recipes"],
            transport: transport
        )
        XCTAssertEqual(
            sections.map(\.relativePath),
            ["[memory search: travel]", "[memory search: recipes]"]
        )
        XCTAssertEqual(sections.map(\.text), ["memory about travel\n", "memory about recipes\n"])
        XCTAssertEqual(
            transport.methods,
            ["initialize", "notifications/initialized", "tools/list", "tools/call", "tools/call"]
        )
        XCTAssertEqual(transport.calledToolNames, ["search_memories", "search_memories"])
        XCTAssertEqual(transport.calledQueries, ["travel", "recipes"])
        XCTAssertTrue(transport.calledArgumentKeys.allSatisfy { $0 == ["query"] })
        XCTAssertTrue(transport.bearerTokens.allSatisfy { $0 == memorySecret })
        XCTAssertFalse(transport.bodiesText.contains(memorySecret))
    }

    func testFetcherRefusesWriteScopeBeforeCallingAnyTool() throws {
        let writeTool: [String: Any] = ["name": "save_memory", "inputSchema": ["type": "object"]]
        let transport = FakeMemoryTransport(pages: [readOnlyTools(), [writeTool]])
        XCTAssertThrowsError(try MemoryContextFetcher.fetch(
            profile: resolvedMemoryProfile(),
            queries: ["travel"],
            transport: transport
        )) { error in
            XCTAssertEqual(error as? MemoryContextError, .writeScopeRequired)
            XCTAssertFalse(String(describing: error).contains(memorySecret))
        }
        XCTAssertTrue(transport.calledToolNames.isEmpty)
    }

    func testFetcherRejectsMissingSearchToolAndUnsupportedSchemas() throws {
        let withoutSearch = readOnlyTools().filter { ($0["name"] as? String) != "search_memories" }
        XCTAssertThrowsError(try MemoryContextFetcher.fetch(
            profile: resolvedMemoryProfile(),
            queries: ["travel"],
            transport: FakeMemoryTransport(pages: [withoutSearch])
        )) { error in
            XCTAssertEqual(error as? MemoryContextError, .searchUnavailable)
        }

        let extraRequired: [String: Any] = [
            "type": "object",
            "properties": ["query": ["type": "string"], "user_id": ["type": "string"]],
            "required": ["query", "user_id"]
        ]
        XCTAssertThrowsError(try MemoryContextFetcher.fetch(
            profile: resolvedMemoryProfile(),
            queries: ["travel"],
            transport: FakeMemoryTransport(pages: [readOnlyTools(searchSchema: extraRequired)])
        )) { error in
            XCTAssertEqual(error as? MemoryContextError, .unsupportedSchema)
        }

        let wrongType: [String: Any] = [
            "type": "object",
            "properties": ["query": ["type": "integer"]],
            "required": ["query"]
        ]
        XCTAssertThrowsError(try MemoryContextFetcher.fetch(
            profile: resolvedMemoryProfile(),
            queries: ["travel"],
            transport: FakeMemoryTransport(pages: [readOnlyTools(searchSchema: wrongType)])
        )) { error in
            XCTAssertEqual(error as? MemoryContextError, .unsupportedSchema)
        }

        let transport = FakeMemoryTransport(pages: [readOnlyTools(searchSchema: nil)])
        XCTAssertThrowsError(try MemoryContextFetcher.fetch(
            profile: resolvedMemoryProfile(),
            queries: ["travel"],
            transport: transport
        )) { error in
            XCTAssertEqual(error as? MemoryContextError, .unsupportedSchema)
        }
        XCTAssertTrue(transport.calledToolNames.isEmpty)
    }

    func testFetcherRejectsOversizedErrorAndNonTextResults() throws {
        let oversized = FakeMemoryTransport(pages: [readOnlyTools()])
        oversized.resultsByQuery = [
            "big": String(repeating: "m", count: BuiltInContextLoader.maximumFileBytes + 1)
        ]
        XCTAssertThrowsError(try MemoryContextFetcher.fetch(
            profile: resolvedMemoryProfile(),
            queries: ["big"],
            transport: oversized
        )) { error in
            XCTAssertEqual(error as? MemoryContextError, .resultTooLarge)
        }

        let failing = FakeMemoryTransport(pages: [readOnlyTools()])
        failing.callResult = { _ in
            ["content": [["type": "text", "text": "synthetic failure"]], "isError": true]
        }
        XCTAssertThrowsError(try MemoryContextFetcher.fetch(
            profile: resolvedMemoryProfile(),
            queries: ["travel"],
            transport: failing
        )) { error in
            XCTAssertEqual(error as? MemoryContextError, .invalidResult)
        }

        let nonText = FakeMemoryTransport(pages: [readOnlyTools()])
        nonText.callResult = { _ in
            ["content": [["type": "image", "data": "synthetic"]]]
        }
        XCTAssertThrowsError(try MemoryContextFetcher.fetch(
            profile: resolvedMemoryProfile(),
            queries: ["travel"],
            transport: nonText
        )) { error in
            XCTAssertEqual(error as? MemoryContextError, .invalidResult)
        }
    }

    func testFetcherRejectsSecretInQueryBeforeTransportAndInResult() throws {
        let untouched = FakeMemoryTransport(pages: [readOnlyTools()])
        XCTAssertThrowsError(try MemoryContextFetcher.fetch(
            profile: resolvedMemoryProfile(),
            queries: ["find " + memorySecret],
            transport: untouched
        )) { error in
            XCTAssertEqual(error as? MemoryContextError, .secretInContext)
            XCTAssertFalse(String(describing: error).contains(memorySecret))
        }
        XCTAssertTrue(untouched.methods.isEmpty)

        let leaking = FakeMemoryTransport(pages: [readOnlyTools()])
        leaking.resultsByQuery = ["travel": "token is " + memorySecret + "\n"]
        XCTAssertThrowsError(try MemoryContextFetcher.fetch(
            profile: resolvedMemoryProfile(),
            queries: ["travel"],
            transport: leaking
        )) { error in
            XCTAssertEqual(error as? MemoryContextError, .secretInContext)
        }
    }

    func testFetcherRejectsInvalidDuplicateAndTooManyQueries() throws {
        for queries in [["bad\u{01}query"], ["same", "same"]] {
            let transport = FakeMemoryTransport(pages: [readOnlyTools()])
            XCTAssertThrowsError(try MemoryContextFetcher.fetch(
                profile: resolvedMemoryProfile(),
                queries: queries,
                transport: transport
            )) { error in
                XCTAssertEqual(error as? MemoryContextError, .invalidQuery)
            }
            XCTAssertTrue(transport.methods.isEmpty)
        }
        let transport = FakeMemoryTransport(pages: [readOnlyTools()])
        XCTAssertThrowsError(try MemoryContextFetcher.fetch(
            profile: resolvedMemoryProfile(),
            queries: (1...MemoryContextFetcher.maximumQueries + 1).map { "q\($0)" },
            transport: transport
        )) { error in
            XCTAssertEqual(error as? MemoryContextError, .tooManyQueries)
        }
        XCTAssertTrue(transport.methods.isEmpty)
    }

    func testAskSingleStepWithMemorySearchReturnsAnswer() throws {
        try publish(candidate())
        try saveOllamaProfile()
        try saveMemoryProfile()
        let memoryTransport = FakeMemoryTransport(pages: [readOnlyTools()])
        memoryTransport.resultsByQuery = ["travel": "remembered travel fact\n"]
        let builtInTransport = FakeBuiltInTransport(response: successResponse())
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "ask", "--person", "alice", "--role", "fast",
             "--single-step", "--memory-profile", "alice-memory",
             "--memory-search", "travel", "--json", "--", prompt],
            environment: [:],
            recordedDay: "2026-11-04",
            runID: "run-builtin-memory",
            secretStore: fakeSecrets,
            builtInTransport: builtInTransport,
            memoryTransport: memoryTransport
        )
        XCTAssertEqual(result.code, 0, result.stderr)
        let decoded = try JSONDecoder().decode(AskResult.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(decoded.answer, answer)
        XCTAssertEqual(decoded.explanation.memoryProfileName, "alice-memory")
        let body = String(decoding: try XCTUnwrap(builtInTransport.body), as: UTF8.self)
        XCTAssertTrue(body.contains("[memory search: travel]"))
        XCTAssertTrue(body.contains("remembered travel fact"))
        let ledger = try String(contentsOf: ledgerURL, encoding: .utf8)
        XCTAssertFalse(ledger.contains("remembered travel fact"))
        XCTAssertFalse(ledger.contains(prompt))
        XCTAssertFalse(ledger.contains(memorySecret))
        XCTAssertFalse(ledger.contains(ollamaSecret))
        XCTAssertFalse((result.stdout + result.stderr).contains(memorySecret))
    }

    func testAskHumanOutputNamesAttachedMemory() throws {
        try publish(candidate())
        try saveOllamaProfile()
        try saveMemoryProfile()
        let memoryTransport = FakeMemoryTransport(pages: [readOnlyTools()])
        memoryTransport.resultsByQuery = ["travel": "remembered travel fact\n"]
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "ask", "--person", "alice", "--role", "fast",
             "--single-step", "--memory-profile", "alice-memory",
             "--memory-search", "travel", "--", prompt],
            environment: [:],
            recordedDay: "2026-11-04",
            runID: "run-builtin-memory-human",
            secretStore: fakeSecrets,
            builtInTransport: FakeBuiltInTransport(response: successResponse()),
            memoryTransport: memoryTransport
        )
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("Memory: alice-memory (read-only)"))
        XCTAssertTrue(result.stdout.contains(answer))
    }

    func testMemoryFlagsRequireSingleStepAndPairing() throws {
        try publish(candidate())
        try saveOllamaProfile()
        try saveMemoryProfile()
        let flagSets: [[String]] = [
            ["--memory-profile", "alice-memory", "--memory-search", "travel"],
            ["--single-step", "--memory-profile", "alice-memory"],
            ["--single-step", "--memory-search", "travel"]
        ]
        for flags in flagSets {
            let memoryTransport = FakeMemoryTransport(pages: [readOnlyTools()])
            let builtInTransport = FakeBuiltInTransport(response: successResponse())
            let result = JECommandLine.run(
                ["--state-dir", stateDirectory.path, "ask", "--person", "alice", "--role", "fast"]
                    + flags + ["--", prompt],
                environment: [:],
                secretStore: fakeSecrets,
                builtInTransport: builtInTransport,
                memoryTransport: memoryTransport
            )
            XCTAssertEqual(result.code, 2, "flags should be invalid: \(flags)")
            XCTAssertTrue(result.stderr.contains("Invalid arguments."))
            XCTAssertTrue(memoryTransport.methods.isEmpty)
            XCTAssertEqual(builtInTransport.callCount, 0)
        }
    }

    func testWhyNamesMemoryWithoutContactingService() throws {
        try publish(candidate())
        try saveOllamaProfile()
        try saveMemoryProfile()
        let memoryTransport = FakeMemoryTransport(pages: [readOnlyTools()])
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "why", "--person", "alice", "--role", "fast",
             "--single-step", "--memory-profile", "alice-memory",
             "--memory-search", "travel", "--", prompt],
            environment: [:],
            secretStore: fakeSecrets,
            memoryTransport: memoryTransport
        )
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("Memory: alice-memory (read-only)"))
        XCTAssertTrue(memoryTransport.methods.isEmpty)
    }

    func testCombinedContextBudgetRejectsOversizeTotal() throws {
        try publish(candidate())
        try saveOllamaProfile()
        try saveMemoryProfile()
        let root = try makeContextRoot()
        let memoryTransport = FakeMemoryTransport(pages: [readOnlyTools()])
        let full = String(repeating: "m", count: BuiltInContextLoader.maximumFileBytes)
        memoryTransport.resultsByQuery = ["one": full, "two": full]
        let builtInTransport = FakeBuiltInTransport(response: successResponse())
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "ask", "--person", "alice", "--role", "fast",
             "--single-step", "--context-root", root.path, "--context-file", "notes.txt",
             "--memory-profile", "alice-memory",
             "--memory-search", "one", "--memory-search", "two", "--", prompt],
            environment: [:],
            recordedDay: "2026-11-04",
            runID: "run-builtin-memory-budget",
            secretStore: fakeSecrets,
            builtInTransport: builtInTransport,
            memoryTransport: memoryTransport
        )
        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.stdout.contains("Launch: context_too_large."))
        XCTAssertEqual(builtInTransport.callCount, 0)
        let ledger = try String(contentsOf: ledgerURL, encoding: .utf8)
        XCTAssertTrue(ledger.contains("\"outcome\":\"failed\""))
    }

    func testAskFailsClosedWhenMemoryCredentialHasWriteScope() throws {
        try publish(candidate())
        try saveOllamaProfile()
        try saveMemoryProfile()
        var tools = readOnlyTools()
        tools.append(["name": "save_memory", "inputSchema": ["type": "object"]])
        let memoryTransport = FakeMemoryTransport(pages: [tools])
        let builtInTransport = FakeBuiltInTransport(response: successResponse())
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "ask", "--person", "alice", "--role", "fast",
             "--single-step", "--memory-profile", "alice-memory",
             "--memory-search", "travel", "--", prompt],
            environment: [:],
            recordedDay: "2026-11-04",
            runID: "run-builtin-memory-scope",
            secretStore: fakeSecrets,
            builtInTransport: builtInTransport,
            memoryTransport: memoryTransport
        )
        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.stdout.contains("Launch: memory_context_read_scope_required."))
        XCTAssertEqual(builtInTransport.callCount, 0)
        XCTAssertFalse((result.stdout + result.stderr).contains(memorySecret))
        XCTAssertFalse((result.stdout + result.stderr).contains(ollamaSecret))
    }

    private func readOnlyTools(
        searchSchema: [String: Any]? = [
            "type": "object",
            "properties": ["query": ["type": "string"]],
            "required": ["query"]
        ]
    ) -> [[String: Any]] {
        var search: [String: Any] = ["name": "search_memories"]
        if let searchSchema {
            search["inputSchema"] = searchSchema
        }
        var tools = [search]
        for name in ["list_memories", "get_memory", "memory_history", "memory_operation_status"] {
            tools.append(["name": name, "inputSchema": ["type": "object"]])
        }
        return tools
    }

    private func resolvedMemoryProfile() -> ResolvedMemoryProfile {
        ResolvedMemoryProfile(
            name: "alice-memory",
            endpoint: "https://memory.example.test/mcp",
            secret: memorySecret,
            serverName: "je_memory_test"
        )
    }

    private var ledgerURL: URL {
        stateDirectory.appendingPathComponent("usage/detailed.jsonl")
    }

    private func successResponse() -> OllamaHTTPResponse {
        OllamaHTTPResponse(
            statusCode: 200,
            data: Data(
                "{\"model\":\"local/model:latest\",\"message\":{\"role\":\"assistant\",\"content\":\"\(answer)\"},\"done\":true}".utf8
            )
        )
    }

    private func candidate() -> RouteCandidate {
        RouteCandidate(
            id: "fast-builtin-ollama",
            role: .fast,
            engine: .ollama,
            harness: .builtIn,
            launchMode: .singleStep,
            executionPlace: .personalMachine,
            providerKind: .local,
            modelArtifact: "local/model",
            engineVersion: "0.13.0",
            modelFormat: "ollama",
            protocolImplementation: "ollama-native-chat",
            protocolVersion: "0.13.0",
            configurationDigest: String(repeating: "c", count: 64),
            qualificationStatus: .qualified,
            allowedPersonIDs: ["alice"],
            connectionProfileName: "alice",
            qualificationEvidenceReference: "evidence:test",
            publishedPriority: 10
        )
    }

    private func publish(_ candidate: RouteCandidate) throws {
        _ = try AssignmentRegistry(directory: stateDirectory).publish(candidate)
    }

    private func saveOllamaProfile() throws {
        try ProfileStore(directory: stateDirectory).saveNativeOllamaProfile(
            name: "alice",
            endpoint: "https://native.example.test/ollama",
            secret: ollamaSecret,
            model: "local/model",
            secretStore: fakeSecrets
        )
    }

    private func saveMemoryProfile() throws {
        try ProfileStore(directory: stateDirectory).saveNativeMemoryProfile(
            name: "alice-memory",
            endpoint: "https://memory.example.test/mcp",
            secret: memorySecret,
            secretStore: fakeSecrets
        )
    }

    private func makeContextRoot() throws -> URL {
        let root = temporary.appendingPathComponent("context-root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("first context\n".utf8).write(to: root.appendingPathComponent("notes.txt"))
        return root
    }
}

private final class FakeMemoryTransport: MemoryHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let pages: [[[String: Any]]]
    var resultsByQuery: [String: String] = [:]
    var callResult: ((String) -> [String: Any])?
    private var capturedMethods: [String] = []
    private var capturedBearerTokens: [String] = []
    private var capturedBodies: [Data] = []
    private var capturedToolNames: [String] = []
    private var capturedQueries: [String] = []
    private var capturedArgumentKeys: [[String]] = []

    init(pages: [[[String: Any]]]) {
        self.pages = pages
    }

    var methods: [String] { lock.withLock { capturedMethods } }
    var bearerTokens: [String] { lock.withLock { capturedBearerTokens } }
    var calledToolNames: [String] { lock.withLock { capturedToolNames } }
    var calledQueries: [String] { lock.withLock { capturedQueries } }
    var calledArgumentKeys: [[String]] { lock.withLock { capturedArgumentKeys } }

    var bodiesText: String {
        lock.withLock { capturedBodies.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") }
    }

    func post(_ request: MemoryHTTPRequest) throws -> MemoryHTTPResponse {
        let object = try JSONSerialization.jsonObject(with: request.body, options: []) as? [String: Any]
        let method = object?["method"] as? String ?? ""
        let id = (object?["id"] as? NSNumber)?.intValue ?? 0
        let params = object?["params"] as? [String: Any] ?? [:]
        lock.withLock {
            capturedMethods.append(method)
            capturedBearerTokens.append(request.bearerToken)
            capturedBodies.append(request.body)
        }
        switch method {
        case "initialize":
            return response(id: id, result: [
                "protocolVersion": "2025-03-26",
                "capabilities": [String: Any](),
                "serverInfo": ["name": "fake", "version": "1"]
            ], headers: ["mcp-session-id": "session-123"])
        case "notifications/initialized":
            return MemoryHTTPResponse(statusCode: 202, headers: [:], data: Data())
        case "tools/list":
            let pageIndex: Int
            if let cursor = params["cursor"] as? String, cursor.hasPrefix("cursor-") {
                pageIndex = Int(cursor.dropFirst("cursor-".count)) ?? 0
            } else {
                pageIndex = 0
            }
            var result: [String: Any] = ["tools": pages[pageIndex]]
            if pageIndex + 1 < pages.count {
                result["nextCursor"] = "cursor-\(pageIndex + 1)"
            }
            return response(id: id, result: result)
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let query = arguments["query"] as? String ?? ""
            lock.withLock {
                capturedToolNames.append(name)
                capturedQueries.append(query)
                capturedArgumentKeys.append(arguments.keys.sorted())
            }
            let result = callResult?(query) ?? [
                "content": [["type": "text", "text": resultsByQuery[query] ?? ""]],
                "isError": false
            ]
            return response(id: id, result: result)
        default:
            return MemoryHTTPResponse(statusCode: 400, headers: [:], data: Data())
        }
    }

    private func response(
        id: Int,
        result: [String: Any],
        headers: [String: String] = ["content-type": "application/json"]
    ) -> MemoryHTTPResponse {
        let data = (try? JSONSerialization.data(
            withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result],
            options: [.sortedKeys]
        )) ?? Data()
        return MemoryHTTPResponse(statusCode: 200, headers: headers, data: data)
    }
}

private final class FakeBuiltInTransport: BuiltInHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let response: OllamaHTTPResponse
    private var capturedBody: Data?
    private var calls = 0

    init(response: OllamaHTTPResponse) {
        self.response = response
    }

    var body: Data? { lock.withLock { capturedBody } }
    var callCount: Int { lock.withLock { calls } }

    func postJSON(url: URL, bearerToken: String, body: Data) throws -> OllamaHTTPResponse {
        lock.withLock {
            capturedBody = body
            calls += 1
        }
        return response
    }
}

private final class MemoryContextFakeSecretStore: SecretStoring, @unchecked Sendable {
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
