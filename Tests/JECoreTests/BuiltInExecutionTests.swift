import Foundation
import XCTest
@testable import JECore

final class BuiltInExecutionTests: XCTestCase {
    private var temporary: URL!
    private var stateDirectory: URL!
    private var fakeSecrets: BuiltInFakeSecretStore!
    private let secret = "synthetic-builtin-key"
    private let prompt = "Summarize this in one short answer."
    private let answer = "synthetic built-in answer"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("je-builtin-tests-" + UUID().uuidString, isDirectory: true)
        stateDirectory = temporary.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        fakeSecrets = BuiltInFakeSecretStore()
    }

    override func tearDownWithError() throws {
        if let temporary {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    func testExecutorMakesOneNativeChatRequestWithoutTools() throws {
        let transport = FakeTransport(response: successResponse())
        let output = try BuiltInExecutor.execute(
            candidate: candidate(),
            profile: resolvedProfile(),
            prompt: prompt,
            transport: transport
        )
        XCTAssertEqual(output, answer)
        XCTAssertEqual(transport.callCount, 1)
        XCTAssertEqual(transport.url?.absoluteString, "https://native.example.test/ollama/api/chat")
        XCTAssertEqual(transport.bearerToken, secret)

        let body = try XCTUnwrap(transport.body)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body, options: []) as? [String: Any]
        )
        XCTAssertEqual(object["model"] as? String, "local/model")
        XCTAssertEqual(object["stream"] as? Bool, false)
        XCTAssertNil(object["tools"])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.last?["role"] as? String, "user")
        XCTAssertEqual(messages.last?["content"] as? String, prompt)
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains(secret))
    }

    func testExecutorStopsWhenModelRequestsToolCall() {
        let data = Data(
            "{\"message\":{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"function\":{\"name\":\"read_file\"}}]},\"done\":true}".utf8
        )
        let transport = FakeTransport(response: OllamaHTTPResponse(statusCode: 200, data: data))
        XCTAssertThrowsError(try BuiltInExecutor.execute(
            candidate: candidate(),
            profile: resolvedProfile(),
            prompt: prompt,
            transport: transport
        )) { error in
            XCTAssertEqual(error as? BuiltInExecutionError, .harnessRunRequired)
            XCTAssertFalse(String(describing: error).contains(secret))
        }
    }

    func testExecutorRejectsWrongProtocolAndOversizedPromptBeforeTransport() {
        let transport = FakeTransport(response: successResponse())
        var wrong = candidate()
        wrong = RouteCandidate(
            id: wrong.id,
            role: wrong.role,
            engine: wrong.engine,
            harness: wrong.harness,
            launchMode: wrong.launchMode,
            executionPlace: wrong.executionPlace,
            providerKind: wrong.providerKind,
            modelArtifact: wrong.modelArtifact,
            engineVersion: wrong.engineVersion,
            modelFormat: wrong.modelFormat,
            protocolImplementation: "other-protocol",
            protocolVersion: wrong.protocolVersion,
            configurationDigest: wrong.configurationDigest,
            qualificationStatus: wrong.qualificationStatus,
            allowedPersonIDs: wrong.allowedPersonIDs,
            connectionProfileName: wrong.connectionProfileName,
            qualificationEvidenceReference: wrong.qualificationEvidenceReference,
            publishedPriority: wrong.publishedPriority
        )
        XCTAssertThrowsError(try BuiltInExecutor.execute(
            candidate: wrong,
            profile: resolvedProfile(),
            prompt: prompt,
            transport: transport
        )) { error in
            XCTAssertEqual(error as? BuiltInExecutionError, .unsupportedRoute)
        }

        let oversized = String(repeating: "x", count: BuiltInExecutor.maximumPromptBytes + 1)
        XCTAssertThrowsError(try BuiltInExecutor.execute(
            candidate: candidate(),
            profile: resolvedProfile(),
            prompt: oversized,
            transport: transport
        )) { error in
            XCTAssertEqual(error as? BuiltInExecutionError, .promptTooLarge)
        }
        XCTAssertEqual(transport.callCount, 0)
    }

    func testAskWithoutSingleStepDoesNotSelectBuiltInCandidate() throws {
        try publish(candidate())
        try saveOllamaProfile()
        let transport = FakeTransport(response: successResponse())
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "ask", "--person", "alice", "--role", "fast",
             "--json", "--", prompt],
            environment: [:],
            recordedDay: "2026-11-04",
            runID: "run-builtin-not-eligible",
            secretStore: fakeSecrets,
            builtInTransport: transport
        )
        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.stdout.contains("\"launchStatus\" : \"no_qualified_route\""))
        XCTAssertEqual(transport.callCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerURL.path))
    }

    func testAskSingleStepReturnsAnswerAndRecordsContentFreeTrace() throws {
        try publish(candidate())
        try saveOllamaProfile()
        let transport = FakeTransport(response: successResponse())
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "ask", "--person", "alice", "--role", "fast",
             "--single-step", "--json", "--", prompt],
            environment: [:],
            recordedDay: "2026-11-04",
            runID: "run-builtin",
            secretStore: fakeSecrets,
            builtInTransport: transport
        )
        XCTAssertEqual(result.code, 0, result.stderr)
        let decoded = try JSONDecoder().decode(AskResult.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(decoded.answer, answer)
        XCTAssertEqual(decoded.launchStatus, "completed")
        XCTAssertNil(decoded.harnessExitCode)
        XCTAssertEqual(transport.callCount, 1)

        let ledger = try String(contentsOf: ledgerURL, encoding: .utf8)
        XCTAssertTrue(ledger.contains("\"outcome\":\"succeeded\""))
        XCTAssertFalse(ledger.contains(prompt))
        XCTAssertFalse(ledger.contains(answer))
        XCTAssertFalse(ledger.contains(secret))
    }

    func testAskSingleStepProfileModelMismatchFailsWithoutAnswer() throws {
        try publish(candidate())
        try ProfileStore(directory: stateDirectory).saveNativeOllamaProfile(
            name: "alice",
            endpoint: "https://native.example.test/ollama",
            secret: secret,
            model: "other/model",
            secretStore: fakeSecrets
        )
        let transport = FakeTransport(response: successResponse())
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "ask", "--person", "alice", "--role", "fast",
             "--single-step", "--", prompt],
            environment: [:],
            recordedDay: "2026-11-04",
            runID: "run-builtin-mismatch",
            secretStore: fakeSecrets,
            builtInTransport: transport
        )
        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.stdout.contains("Launch: profile_mismatch."))
        XCTAssertFalse(result.stdout.contains(answer))
        XCTAssertEqual(transport.callCount, 0)
        let ledger = try String(contentsOf: ledgerURL, encoding: .utf8)
        XCTAssertTrue(ledger.contains("\"outcome\":\"failed\""))
    }

    func testContextLoaderReadsExplicitFilesInsideRoot() throws {
        let root = try makeContextRoot()
        let files = try BuiltInContextLoader.load(
            root: root,
            relativePaths: ["notes.txt", "docs/guide.txt"],
            secret: secret
        )
        XCTAssertEqual(files.map(\.relativePath), ["notes.txt", "docs/guide.txt"])
        XCTAssertEqual(files.map(\.text), ["first context\n", "second context\n"])
    }

    func testContextLoaderRejectsTraversalSymlinkBinaryAndSecret() throws {
        let root = try makeContextRoot()
        let outside = temporary.appendingPathComponent("outside.txt")
        try Data("outside\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked.txt"),
            withDestinationURL: outside
        )
        try Data([0, 1, 2, 3]).write(to: root.appendingPathComponent("binary.bin"))
        try Data(("token is " + secret + "\n").utf8)
            .write(to: root.appendingPathComponent("leak.txt"))

        for path in ["../outside.txt", "/etc/passwd", "linked.txt", "binary.bin", "leak.txt", "missing.txt"] {
            XCTAssertThrowsError(
                try BuiltInContextLoader.load(root: root, relativePaths: [path], secret: secret),
                "path should fail: \(path)"
            ) { error in
                XCTAssertTrue(error is BuiltInContextError)
                XCTAssertFalse(String(describing: error).contains(secret))
            }
        }
    }

    func testContextLoaderRejectsOversizedFile() throws {
        let root = try makeContextRoot()
        try Data(String(repeating: "x", count: BuiltInContextLoader.maximumFileBytes + 1).utf8)
            .write(to: root.appendingPathComponent("large.txt"))
        XCTAssertThrowsError(
            try BuiltInContextLoader.load(root: root, relativePaths: ["large.txt"], secret: secret)
        ) { error in
            XCTAssertEqual(error as? BuiltInContextError, .fileTooLarge)
        }
    }

    func testExecutorIncludesExplicitContextBeforePrompt() throws {
        let transport = FakeTransport(response: successResponse())
        let output = try BuiltInExecutor.execute(
            candidate: candidate(),
            profile: resolvedProfile(),
            prompt: prompt,
            contextFiles: [
                BuiltInContextFile(relativePath: "notes.txt", text: "first context\n")
            ],
            transport: transport
        )
        XCTAssertEqual(output, answer)
        let body = try XCTUnwrap(transport.body)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body, options: []) as? [String: Any]
        )
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.last?["content"] as? String)
        XCTAssertTrue(content.contains("Context file: notes.txt"))
        XCTAssertTrue(content.contains("first context"))
        XCTAssertTrue(content.contains("User request:"))
        XCTAssertTrue(content.hasSuffix(prompt))
        XCTAssertNil(object["tools"])
    }

    func testAskSingleStepWithContextFileReturnsAnswer() throws {
        try publish(candidate())
        try saveOllamaProfile()
        let root = try makeContextRoot()
        let transport = FakeTransport(response: successResponse())
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "ask", "--person", "alice", "--role", "fast",
             "--single-step", "--context-root", root.path,
             "--context-file", "notes.txt", "--json", "--", prompt],
            environment: [:],
            recordedDay: "2026-11-04",
            runID: "run-builtin-context",
            secretStore: fakeSecrets,
            builtInTransport: transport
        )
        XCTAssertEqual(result.code, 0, result.stderr)
        let decoded = try JSONDecoder().decode(AskResult.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(decoded.answer, answer)
        let body = try XCTUnwrap(transport.body)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("first context"))
        let ledger = try String(contentsOf: ledgerURL, encoding: .utf8)
        XCTAssertFalse(ledger.contains("first context"))
        XCTAssertFalse(ledger.contains(prompt))
    }

    func testAskContextOutsideSingleStepIsInvalid() throws {
        try publish(candidate())
        try saveOllamaProfile()
        let root = try makeContextRoot()
        let transport = FakeTransport(response: successResponse())
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "ask", "--person", "alice", "--role", "fast",
             "--context-root", root.path, "--context-file", "notes.txt", "--", prompt],
            environment: [:],
            secretStore: fakeSecrets,
            builtInTransport: transport
        )
        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.stderr.contains("Invalid arguments."))
        XCTAssertEqual(transport.callCount, 0)
    }

    func testContextLoaderListsFilesSortedInsideRoot() throws {
        let root = try makeContextRoot()
        let section = try BuiltInContextLoader.list(root: root, secret: secret)
        XCTAssertEqual(section.relativePath, "[file list]")
        XCTAssertEqual(section.text, "docs/guide.txt\nnotes.txt\n")
    }

    func testContextLoaderSearchReturnsMatchingLinesOnly() throws {
        let root = try makeContextRoot()
        try Data("alpha line\ngamma needle line\nomega needle\n".utf8)
            .write(to: root.appendingPathComponent("search.txt"))
        let section = try BuiltInContextLoader.search(
            root: root,
            query: "needle",
            secret: secret
        )
        XCTAssertEqual(section.relativePath, "[search: needle]")
        XCTAssertEqual(
            section.text,
            "search.txt:2: gamma needle line\nsearch.txt:3: omega needle\n"
        )
    }

    func testContextLoaderSearchRejectsSecretQueryAndSymlinkedFiles() throws {
        let root = try makeContextRoot()
        XCTAssertThrowsError(
            try BuiltInContextLoader.search(root: root, query: secret, secret: secret)
        ) { error in
            XCTAssertEqual(error as? BuiltInContextError, .secretInContext)
        }
        let outside = temporary.appendingPathComponent("outside-search.txt")
        try Data("needle outside\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked.txt"),
            withDestinationURL: outside
        )
        XCTAssertThrowsError(
            try BuiltInContextLoader.search(root: root, query: "needle", secret: secret)
        ) { error in
            XCTAssertEqual(error as? BuiltInContextError, .symbolicLink)
        }
        XCTAssertThrowsError(
            try BuiltInContextLoader.list(root: root, secret: secret)
        ) { error in
            XCTAssertEqual(error as? BuiltInContextError, .symbolicLink)
        }
    }

    func testAskSingleStepWithListAndSearchContextReturnsAnswer() throws {
        try publish(candidate())
        try saveOllamaProfile()
        let root = try makeContextRoot()
        try Data("alpha line\ngamma needle line\n".utf8)
            .write(to: root.appendingPathComponent("search.txt"))
        let transport = FakeTransport(response: successResponse())
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "ask", "--person", "alice", "--role", "fast",
             "--single-step", "--context-root", root.path, "--context-list",
             "--context-search", "needle", "--json", "--", prompt],
            environment: [:],
            recordedDay: "2026-11-04",
            runID: "run-builtin-list-search",
            secretStore: fakeSecrets,
            builtInTransport: transport
        )
        XCTAssertEqual(result.code, 0, result.stderr)
        let decoded = try JSONDecoder().decode(AskResult.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(decoded.answer, answer)
        let body = String(decoding: try XCTUnwrap(transport.body), as: UTF8.self)
        XCTAssertTrue(body.contains("[file list]"))
        XCTAssertTrue(body.contains("search.txt:2: gamma needle line"))
        let ledger = try String(contentsOf: ledgerURL, encoding: .utf8)
        XCTAssertFalse(ledger.contains("gamma needle line"))
        XCTAssertFalse(ledger.contains(prompt))
    }

    private func makeContextRoot() throws -> URL {
        let root = temporary.appendingPathComponent("context-root", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("docs", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("first context\n".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try Data("second context\n".utf8)
            .write(to: root.appendingPathComponent("docs/guide.txt"))
        return root
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

    private func resolvedProfile() -> ResolvedOllamaProfile {
        ResolvedOllamaProfile(
            name: "alice",
            endpoint: "https://native.example.test/ollama",
            secret: secret,
            model: "local/model"
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
            secret: secret,
            model: "local/model",
            secretStore: fakeSecrets
        )
    }
}

private final class FakeTransport: BuiltInHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let response: OllamaHTTPResponse
    private var capturedURL: URL?
    private var capturedBearerToken: String?
    private var capturedBody: Data?
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

    var body: Data? {
        lock.withLock { capturedBody }
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    func postJSON(url: URL, bearerToken: String, body: Data) throws -> OllamaHTTPResponse {
        lock.withLock {
            capturedURL = url
            capturedBearerToken = bearerToken
            capturedBody = body
            calls += 1
        }
        return response
    }
}

private final class BuiltInFakeSecretStore: SecretStoring, @unchecked Sendable {
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
