import Foundation
import XCTest
@testable import JECore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class OllamaLaunchTests: XCTestCase {
    private var temporary: URL!
    private var stateDirectory: URL!
    private var fakeSecrets: OllamaLaunchFakeSecretStore!
    private let secret = "synthetic-native-launch-key"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("je-ollama-launch-tests-" + UUID().uuidString, isDirectory: true)
        stateDirectory = temporary.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        fakeSecrets = OllamaLaunchFakeSecretStore()
    }

    override func tearDownWithError() throws {
        if let temporary {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    func testRelayForwardsAllowedRequestWithInjectedAuth() throws {
        let upstream = FakeRelayUpstream { _ in
            (200, "application/json", [Data("{\"models\":[]}".utf8)])
        }
        let relay = OllamaLoopbackRelay(
            upstreamBase: "http://upstream.example.test/root",
            bearerToken: secret,
            upstream: upstream,
            token: "TESTTOKEN"
        )
        let base = try relay.start()
        defer { relay.stop() }
        XCTAssertEqual(base.absoluteString, "http://127.0.0.1:\(base.port ?? 0)/TESTTOKEN")

        let response = try http("GET", base.appendingPathComponent("api/tags"))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.body, "{\"models\":[]}")
        XCTAssertEqual(response.headers["content-type"], "application/json")

        let recorded = try XCTUnwrap(upstream.recorded.first)
        XCTAssertEqual(recorded.method, "GET")
        XCTAssertEqual(recorded.url.absoluteString, "http://upstream.example.test/root/api/tags")
        XCTAssertEqual(recorded.bearer, secret)
    }

    func testRelayBlocksNonAllowlistedRequests() throws {
        let upstream = FakeRelayUpstream { _ in (200, "application/json", [Data("{}".utf8)]) }
        let relay = OllamaLoopbackRelay(
            upstreamBase: "http://upstream.example.test",
            bearerToken: secret,
            upstream: upstream,
            token: "TESTTOKEN"
        )
        let base = try relay.start()
        defer { relay.stop() }
        let cases: [(String, URL)] = [
            ("POST", base.appendingPathComponent("api/tags")),
            ("GET", base.appendingPathComponent("api/chat")),
            ("GET", base.appendingPathComponent("api/pull")),
            ("POST", base.appendingPathComponent("api/pull")),
            ("DELETE", base.appendingPathComponent("api/delete")),
            ("GET", base.appendingPathComponent("other")),
            ("GET", URL(string: "http://127.0.0.1:\(base.port ?? 0)/api/tags")!),
            ("GET", URL(string: "http://127.0.0.1:\(base.port ?? 0)/WRONG/api/tags")!),
            ("GET", URL(string: "http://127.0.0.1:\(base.port ?? 0)/TESTTOKEN/api/tags?x=1")!),
            ("GET", URL(string: "http://127.0.0.1:\(base.port ?? 0)/TESTTOKEN/api/tags/")!),
            ("GET", URL(string: "http://127.0.0.1:\(base.port ?? 0)/TESTTOKEN/API/tags")!)
        ]
        for (method, url) in cases {
            let response = try http(method, url, body: method == "GET" ? nil : Data("{}".utf8))
            XCTAssertEqual(response.status, 403, "\(method) \(url.absoluteString)")
            XCTAssertEqual(
                response.body,
                "{\"error\":\"This local relay request is not permitted.\"}\n",
                "\(method) \(url.absoluteString)"
            )
        }
        XCTAssertTrue(upstream.recorded.isEmpty)
    }

    func testRelayMapsUpstreamErrorsLikeOracle() throws {
        let upstream = FakeRelayUpstream { request in
            let path = request.url.path
            if path.hasSuffix("/api/show") {
                return (404, "application/json", [Data("{\"error\":\"gone\"}".utf8)])
            }
            if path.hasSuffix("/api/ps") {
                return (500, "application/json", [Data("{\"error\":\"broke\"}".utf8)])
            }
            if path.hasSuffix("/api/version") {
                return (401, "application/json", [Data("{\"error\":\"bad key\"}".utf8)])
            }
            return (200, "application/json", [Data("{}".utf8)])
        }
        let relay = OllamaLoopbackRelay(
            upstreamBase: "http://upstream.example.test",
            bearerToken: secret,
            upstream: upstream,
            token: "TESTTOKEN"
        )
        let base = try relay.start()
        defer { relay.stop() }

        let show = try http(
            "POST", base.appendingPathComponent("api/show"),
            body: Data("{\"name\":\"missing\"}".utf8))
        XCTAssertEqual(show.status, 403)
        XCTAssertEqual(
            show.body,
            "{\"error\":\"This model is not available through the shared connection.\"}\n")

        let ps = try http("GET", base.appendingPathComponent("api/ps"))
        XCTAssertEqual(ps.status, 500)
        XCTAssertEqual(
            ps.body, "{\"error\":\"The shared Ollama service returned an error.\"}\n")

        let version = try http("GET", base.appendingPathComponent("api/version"))
        XCTAssertEqual(version.status, 401)
        XCTAssertEqual(
            version.body, "{\"error\":\"The shared service rejected this request.\"}\n")
    }

    func testRelayTransportFailureReturns502() throws {
        let upstream = FakeRelayUpstream { _ in
            throw OllamaRelayUpstreamError.transportFailed
        }
        let relay = OllamaLoopbackRelay(
            upstreamBase: "http://upstream.example.test",
            bearerToken: secret,
            upstream: upstream,
            token: "TESTTOKEN"
        )
        let base = try relay.start()
        defer { relay.stop() }
        let response = try http("GET", base.appendingPathComponent("api/tags"))
        XCTAssertEqual(response.status, 502)
        XCTAssertEqual(
            response.body,
            "{\"error\":\"The shared Ollama service could not complete the request.\"}\n")
    }

    func testRelayStreamsChunksInOrderAndStopsListening() throws {
        let upstream = FakeRelayUpstream { _ in
            (200, "application/x-ndjson", [
                Data("{\"done\":false}\n".utf8),
                Data("{\"done\":true}\n".utf8)
            ])
        }
        let relay = OllamaLoopbackRelay(
            upstreamBase: "http://upstream.example.test",
            bearerToken: secret,
            upstream: upstream,
            token: "TESTTOKEN"
        )
        let base = try relay.start()
        let response = try http(
            "POST", base.appendingPathComponent("api/chat"),
            body: Data("{\"model\":\"x\"}".utf8))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.body, "{\"done\":false}\n{\"done\":true}\n")
        XCTAssertEqual(response.headers["content-type"], "application/x-ndjson")

        let head = try http("HEAD", base)
        XCTAssertEqual(head.status, 200)
        XCTAssertEqual(head.body, "")
        XCTAssertEqual(head.headers["content-type"], "application/json")

        relay.stop()
        XCTAssertNil(httpStatus("GET", base.appendingPathComponent("api/tags")))
    }

    func testDefaultLaunchRunsModelWithLiveRelayHost() throws {
        try saveOllamaProfile()
        let upstream = FakeRelayUpstream { _ in
            (200, "application/json", [Data("{\"models\":[]}".utf8)])
        }
        let runner = CapturingRunner()
        var duringStatus: Int?
        runner.duringRun = { spec in
            guard let host = spec.environment["OLLAMA_HOST"],
                  let url = URL(string: host + "/api/tags") else {
                return
            }
            duringStatus = Self.rawHTTP("GET", url, body: nil)?.status
        }
        runner.exitCode = 7
        let executable = try makeExecutable()
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "ollama", "--profile", "alice",
             "--executable", executable],
            environment: [:],
            secretStore: fakeSecrets,
            harnessRunner: runner,
            ollamaRelayUpstream: upstream
        )
        XCTAssertEqual(result.code, 7, result.stderr)
        XCTAssertEqual(duringStatus, 200)
        let spec = try XCTUnwrap(runner.spec)
        XCTAssertEqual(spec.arguments, ["run", "local/model"])
        XCTAssertEqual(spec.executableURL.path, executable)
        let host = try XCTUnwrap(spec.environment["OLLAMA_HOST"])
        let hostURL = try XCTUnwrap(URL(string: host))
        XCTAssertEqual(hostURL.scheme, "http")
        XCTAssertEqual(hostURL.host, "127.0.0.1")
        let token = hostURL.lastPathComponent
        XCTAssertEqual(token.count, 43)
        XCTAssertTrue(token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        XCTAssertFalse(spec.environment.values.contains { $0.contains(secret) })
        XCTAssertFalse(spec.arguments.contains { $0.contains(secret) })
        XCTAssertEqual(upstream.recorded.first?.bearer, secret)
        XCTAssertNil(httpStatus("GET", URL(string: host + "/api/tags")!))
    }

    func testPassthroughArgumentsReachExecutableVerbatim() throws {
        try saveOllamaProfile()
        let runner = CapturingRunner()
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "ollama", "--profile", "alice",
             "--executable", try makeExecutable(), "--", "run", "other", "hello there",
             "--verbose"],
            environment: [:],
            secretStore: fakeSecrets,
            harnessRunner: runner,
            ollamaRelayUpstream: FakeRelayUpstream { _ in (200, nil, []) }
        )
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertEqual(runner.spec?.arguments, ["run", "other", "hello there", "--verbose"])
    }

    func testEmptySeparatorUsesDefaultLaunch() throws {
        try saveOllamaProfile()
        let runner = CapturingRunner()
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "ollama", "--profile", "alice",
             "--executable", try makeExecutable(), "--"],
            environment: [:],
            secretStore: fakeSecrets,
            harnessRunner: runner,
            ollamaRelayUpstream: FakeRelayUpstream { _ in (200, nil, []) }
        )
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertEqual(runner.spec?.arguments, ["run", "local/model"])
    }

    func testLaunchRejectsBarePositionalMissingProfileAndBadExecutable() throws {
        try saveOllamaProfile()
        let runner = CapturingRunner()
        let bare = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "ollama", "--profile", "alice", "list"],
            environment: [:],
            secretStore: fakeSecrets,
            harnessRunner: runner,
            ollamaRelayUpstream: FakeRelayUpstream { _ in (200, nil, []) }
        )
        XCTAssertEqual(bare.code, 2)
        XCTAssertTrue(bare.stderr.contains("Invalid arguments."))

        let noProfile = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "ollama"],
            environment: [:],
            secretStore: fakeSecrets,
            harnessRunner: runner,
            ollamaRelayUpstream: FakeRelayUpstream { _ in (200, nil, []) }
        )
        XCTAssertEqual(noProfile.code, 2)
        XCTAssertTrue(noProfile.stderr.contains(
            "Select a saved native Ollama connection with --profile."))

        for bad in ["/nonexistent/ollama", temporary.path] {
            let result = JECommandLine.run(
                ["--state-dir", stateDirectory.path, "ollama", "--profile", "alice",
                 "--executable", bad],
                environment: [:],
                secretStore: fakeSecrets,
                harnessRunner: runner,
                ollamaRelayUpstream: FakeRelayUpstream { _ in (200, nil, []) }
            )
            XCTAssertEqual(result.code, 2, bad)
            XCTAssertTrue(result.stderr.contains(
                "Install the Ollama CLI or provide the path to its executable."), bad)
        }
        XCTAssertNil(runner.spec)
        XCTAssertFalse(
            (bare.stderr + noProfile.stderr).contains(secret))
    }

    private func saveOllamaProfile() throws {
        try ProfileStore(directory: stateDirectory).saveNativeOllamaProfile(
            name: "alice",
            endpoint: "https://native.example.test",
            secret: secret,
            model: "local/model",
            secretStore: fakeSecrets
        )
    }

    private func makeExecutable() throws -> String {
        let url = temporary.appendingPathComponent("fake-ollama")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private struct HTTPResult {
        let status: Int
        let body: String
        let headers: [String: String]
    }

    private func http(
        _ method: String, _ url: URL, body: Data? = nil
    ) throws -> HTTPResult {
        guard let result = Self.rawHTTP(method, url, body: body) else {
            throw NSError(domain: "OllamaLaunchTests", code: 1)
        }
        return result
    }

    private func httpStatus(_ method: String, _ url: URL) -> Int? {
        Self.rawHTTP(method, url, body: nil)?.status
    }

    private static func rawHTTP(
        _ method: String, _ url: URL, body: Data?
    ) -> HTTPResult? {
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = method
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: HTTPResult?
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                var headers: [String: String] = [:]
                for (key, value) in http.allHeaderFields {
                    headers[String(describing: key).lowercased()] =
                        String(describing: value)
                }
                outcome = HTTPResult(
                    status: http.statusCode,
                    body: String(decoding: data ?? Data(), as: UTF8.self),
                    headers: headers)
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 10)
        session.invalidateAndCancel()
        return outcome
    }
}

private final class FakeRelayUpstream: OllamaRelayUpstream, @unchecked Sendable {
    struct Recorded {
        let method: String
        let url: URL
        let contentType: String?
        let body: Data
        let bearer: String
    }

    typealias Reply = (status: Int, contentType: String?, chunks: [Data])

    private let lock = NSLock()
    private let handler: (OllamaRelayUpstreamRequest) throws -> Reply
    private var captured: [Recorded] = []

    init(handler: @escaping (OllamaRelayUpstreamRequest) throws -> Reply) {
        self.handler = handler
    }

    var recorded: [Recorded] {
        lock.withLock { captured }
    }

    func perform(
        _ request: OllamaRelayUpstreamRequest,
        bearerToken: String,
        onHead: @escaping @Sendable (_ status: Int, _ contentType: String?) -> Void,
        onChunk: @escaping @Sendable (Data) -> Void
    ) throws {
        lock.withLock {
            captured.append(Recorded(
                method: request.method,
                url: request.url,
                contentType: request.contentType,
                body: request.body,
                bearer: bearerToken))
        }
        let reply = try handler(request)
        onHead(reply.status, reply.contentType)
        for chunk in reply.chunks {
            onChunk(chunk)
        }
    }
}

private final class CapturingRunner: HarnessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: HarnessLaunchSpec?
    var exitCode: Int32 = 0
    var duringRun: ((HarnessLaunchSpec) -> Void)?

    var spec: HarnessLaunchSpec? {
        lock.withLock { captured }
    }

    func run(_ spec: HarnessLaunchSpec) throws -> Int32 {
        lock.withLock { captured = spec }
        duringRun?(spec)
        return exitCode
    }
}

private final class OllamaLaunchFakeSecretStore: SecretStoring, @unchecked Sendable {
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
