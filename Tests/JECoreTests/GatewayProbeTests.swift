import Foundation
import XCTest
@testable import JECore

final class GatewayProbeTests: XCTestCase {
    private var temporary: URL!
    private var stateDirectory: URL!
    private var fakeSecrets: GatewayProbeFakeSecretStore!
    private let secret = "synthetic-gateway-probe-key"
    private let probeValue = "probe_0123456789abcdef01234567"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("je-gateway-probe-tests-" + UUID().uuidString, isDirectory: true)
        stateDirectory = temporary.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        fakeSecrets = GatewayProbeFakeSecretStore()
    }

    override func tearDownWithError() throws {
        if let temporary {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    func testCodexProbePassesAllSevenChecks() throws {
        let transport = FakeProbeTransport(secret: secret)
        let report = GatewayProbeRunner.run(
            profile: resolvedProfile(),
            protocols: [.responses],
            transport: transport,
            probeValue: { self.probeValue }
        )
        XCTAssertTrue(report.passed)
        XCTAssertEqual(report.protocols, ["responses"])
        XCTAssertEqual(report.counts.passed, 7)
        XCTAssertEqual(report.counts.failed, 0)
        XCTAssertEqual(report.counts.notRun, 0)
        XCTAssertEqual(report.checks.map(\.name), [
            "missing_key_rejected", "wrong_key_rejected", "selected_model_visible",
            "responses_reply", "responses_stream", "responses_tool_continuation",
            "responses_custom_tool_continuation"
        ])
        XCTAssertTrue(report.checks.allSatisfy { $0.status == "passed" })
        let reply = try XCTUnwrap(report.checks[3].evidence)
        XCTAssertEqual(reply["usage_status"], .string("complete"))
        XCTAssertEqual(reply["usage_source"], .string("gateway_reported"))
        XCTAssertEqual(
            reply["usage"],
            .object(["input_tokens": .int(11), "output_tokens": .int(7), "total_tokens": .int(18)])
        )
        let custom = try XCTUnwrap(report.checks[6].evidence)
        XCTAssertEqual(custom["input_delta_events"], .int(1))
        XCTAssertEqual(custom["tool_result_observed"], .bool(true))

        let bodies = transport.bodiesText
        XCTAssertTrue(bodies.contains("read_probe_value"))
        XCTAssertTrue(bodies.contains("read_custom_probe"))
        XCTAssertTrue(bodies.contains(probeValue))
        XCTAssertFalse(bodies.contains(secret))
        let encoded = try String(decoding: JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(encoded.contains(probeValue))
        XCTAssertFalse(encoded.contains(secret))
        let decoded = try JSONDecoder().decode(GatewayProbeReport.self, from: Data(encoded.utf8))
        XCTAssertEqual(decoded.checks.map(\.name), report.checks.map(\.name))
    }

    func testClaudeProbePassesAllSixChecks() throws {
        let transport = FakeProbeTransport(secret: secret)
        let report = GatewayProbeRunner.run(
            profile: resolvedProfile(),
            protocols: [.messages],
            transport: transport,
            probeValue: { self.probeValue }
        )
        XCTAssertTrue(report.passed)
        XCTAssertEqual(report.protocols, ["messages"])
        XCTAssertEqual(report.checks.map(\.name), [
            "missing_key_rejected", "wrong_key_rejected", "selected_model_visible",
            "messages_reply", "messages_stream", "messages_tool_continuation"
        ])
        let stream = try XCTUnwrap(report.checks[4].evidence)
        XCTAssertEqual(stream["terminal_event"], .string("message_stop"))
        XCTAssertEqual(stream["text_delta_events"], .int(1))
    }

    func testBothProtocolsRunTenChecksInOrder() {
        let report = GatewayProbeRunner.run(
            profile: resolvedProfile(),
            protocols: [.responses, .messages],
            transport: FakeProbeTransport(secret: secret),
            probeValue: { self.probeValue }
        )
        XCTAssertTrue(report.passed)
        XCTAssertEqual(report.protocols, ["responses", "messages"])
        XCTAssertEqual(report.checks.map(\.name), [
            "missing_key_rejected", "wrong_key_rejected", "selected_model_visible",
            "responses_reply", "responses_stream", "responses_tool_continuation",
            "responses_custom_tool_continuation", "messages_reply",
            "messages_stream", "messages_tool_continuation"
        ])
    }

    func testAcceptedMissingKeyFailsFast() {
        let transport = FakeProbeTransport(secret: secret)
        transport.requireAuth = false
        let report = GatewayProbeRunner.run(
            profile: resolvedProfile(),
            protocols: [.responses],
            transport: transport,
            probeValue: { self.probeValue }
        )
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.checks.count, 1)
        XCTAssertEqual(report.checks[0].name, "missing_key_rejected")
        XCTAssertEqual(report.checks[0].status, "failed")
        XCTAssertEqual(report.checks[0].error, "authentication_accepted")
        XCTAssertEqual(report.counts.notRun, 6)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testRejectionStatusesMatchOracle() {
        let forbidden = FakeProbeTransport(secret: secret)
        forbidden.rejectStatus = 403
        let passedReport = GatewayProbeRunner.run(
            profile: resolvedProfile(),
            protocols: [.responses],
            transport: forbidden,
            probeValue: { self.probeValue }
        )
        XCTAssertTrue(passedReport.passed)
        XCTAssertEqual(passedReport.checks[0].evidence?["http_status"], .int(403))

        let serverError = FakeProbeTransport(secret: secret)
        serverError.rejectStatus = 500
        let failedReport = GatewayProbeRunner.run(
            profile: resolvedProfile(),
            protocols: [.responses],
            transport: serverError,
            probeValue: { self.probeValue }
        )
        XCTAssertFalse(failedReport.passed)
        XCTAssertEqual(failedReport.checks.count, 1)
        XCTAssertEqual(failedReport.checks[0].error, "http_error")
        XCTAssertEqual(failedReport.checks[0].httpStatus, 500)
    }

    func testMissingUsageStillPassesWithMissingStatus() throws {
        let transport = FakeProbeTransport(secret: secret)
        transport.includeUsage = false
        let report = GatewayProbeRunner.run(
            profile: resolvedProfile(),
            protocols: [.responses],
            transport: transport,
            probeValue: { self.probeValue }
        )
        XCTAssertTrue(report.passed)
        let reply = try XCTUnwrap(report.checks[3].evidence)
        XCTAssertEqual(reply["usage"], .null)
        XCTAssertEqual(reply["usage_status"], .string("missing"))
        XCTAssertNil(reply["usage_source"])
    }

    func testToolResultMismatchFailsContinuation() {
        let transport = FakeProbeTransport(secret: secret)
        transport.toolReplyText = "not the probe value"
        let report = GatewayProbeRunner.run(
            profile: resolvedProfile(),
            protocols: [.responses],
            transport: transport,
            probeValue: { self.probeValue }
        )
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.checks.count, 6)
        XCTAssertEqual(report.checks[5].name, "responses_tool_continuation")
        XCTAssertEqual(report.checks[5].error, "tool_result_mismatch")
        XCTAssertEqual(report.counts.notRun, 1)
    }

    func testDoctorProbeWritesPrivateReportAndReturnsZero() throws {
        try saveProfile()
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "doctor", "--profile", "alice",
             "--probe", "--harness", "codex"],
            environment: [:],
            secretStore: fakeSecrets,
            gatewayTransport: FakeGatewayTransport(),
            gatewayProbeTransport: FakeProbeTransport(secret: secret)
        )
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertEqual(
            result.stdout,
            "Connected. Model local-fast is available.\n"
                + "Protocol checks: 7 passed, 0 failed, 0 not run. "
                + "Private report: \(reportURL.path)\n"
        )
        let data = try Data(contentsOf: reportURL)
        let decoded = try JSONDecoder().decode(GatewayProbeReport.self, from: data)
        XCTAssertTrue(decoded.passed)
        XCTAssertEqual(decoded.model, "local-fast")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(secret))
        XCTAssertFalse((result.stdout + result.stderr).contains(secret))
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: reportURL.path)
        XCTAssertEqual(fileAttributes[.posixPermissions] as? Int, 0o600)
        let dirAttributes = try FileManager.default.attributesOfItem(
            atPath: reportURL.deletingLastPathComponent().path)
        XCTAssertEqual(dirAttributes[.posixPermissions] as? Int, 0o700)
    }

    func testDoctorProbeFailureReturnsOne() throws {
        try saveProfile()
        let probeTransport = FakeProbeTransport(secret: secret)
        probeTransport.requireAuth = false
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "doctor", "--profile", "alice", "--probe"],
            environment: [:],
            secretStore: fakeSecrets,
            gatewayTransport: FakeGatewayTransport(),
            gatewayProbeTransport: probeTransport
        )
        XCTAssertEqual(result.code, 1)
        XCTAssertTrue(result.stdout.contains("Protocol checks: 0 passed, 1 failed, 9 not run."))
        XCTAssertTrue(FileManager.default.fileExists(atPath: reportURL.path))
    }

    func testDoctorProbeSkippedWhenModelUnavailable() throws {
        try saveProfile()
        let probeTransport = FakeProbeTransport(secret: secret)
        let gateway = FakeGatewayTransport()
        gateway.responseData = Data("{\"data\":[]}".utf8)
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "doctor", "--profile", "alice",
             "--probe", "--harness", "claude"],
            environment: [:],
            secretStore: fakeSecrets,
            gatewayTransport: gateway,
            gatewayProbeTransport: probeTransport
        )
        XCTAssertEqual(result.code, 1)
        XCTAssertEqual(
            result.stderr,
            "Connected, but the selected model is not available to this key.\n"
        )
        XCTAssertTrue(probeTransport.requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reportURL.path))
    }

    private var reportURL: URL {
        stateDirectory.appendingPathComponent("reports/alice.json")
    }

    private func resolvedProfile() -> ResolvedConnectionProfile {
        ResolvedConnectionProfile(
            name: "alice",
            endpoint: "https://models.example.test",
            secret: secret,
            model: "local-fast",
            contextWindow: 32768,
            codexCatalog: nil
        )
    }

    private func saveProfile() throws {
        try ProfileStore(directory: stateDirectory).saveNativeProfile(
            name: "alice",
            endpoint: "https://models.example.test",
            secret: secret,
            model: "local-fast",
            contextWindow: 32768,
            secretStore: fakeSecrets
        )
    }
}

private final class FakeProbeTransport: GatewayProbeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let secret: String
    var requireAuth = true
    var rejectStatus = 401
    var includeUsage = true
    var toolReplyText: String?
    private var captured: [GatewayProbeRequest] = []

    init(secret: String) {
        self.secret = secret
    }

    var requests: [GatewayProbeRequest] {
        lock.withLock { captured }
    }

    var bodiesText: String {
        requests.compactMap(\.body)
            .map { String(decoding: $0, as: UTF8.self) }
            .joined(separator: "\n")
    }

    func perform(_ request: GatewayProbeRequest) throws -> GatewayProbeHTTPResponse {
        lock.withLock { captured.append(request) }
        if requireAuth && request.bearerToken != secret {
            return json(rejectStatus, ["error": ["message": "unauthorized"]])
        }
        let path = request.url.path
        if request.method == "GET" && path.hasSuffix("/models") {
            return json(200, ["data": [["id": "local-fast"]]])
        }
        if path.hasSuffix("/responses") {
            return responses(request)
        }
        if path.hasSuffix("/messages") {
            return messages(request)
        }
        return json(404, ["error": ["message": "not found"]])
    }

    private func responses(_ request: GatewayProbeRequest) -> GatewayProbeHTTPResponse {
        let body = parse(request.body)
        let stream = body["stream"] as? Bool ?? false
        let tools = body["tools"] as? [[String: Any]] ?? []
        var toolOutput: String?
        if let items = body["input"] as? [[String: Any]] {
            for item in items
            where ["function_call_output", "custom_tool_call_output"]
                .contains(item["type"] as? String ?? "") {
                toolOutput = item["output"] as? String
            }
        }
        let wantCustom = (tools.first?["type"] as? String) == "custom" && toolOutput == nil
        let wantFunction = !tools.isEmpty && !wantCustom && toolOutput == nil
        let text = toolOutput.map { toolReplyText ?? $0 } ?? "stub response"
        let toolName = tools.first?["name"] as? String ?? "stub_tool"
        var output: [[String: Any]] = []
        if wantCustom {
            output = [[
                "type": "custom_tool_call", "id": "ctc_1", "call_id": "call_1",
                "name": toolName, "input": "READ", "status": "completed"
            ]]
        } else if wantFunction {
            output = [[
                "type": "function_call", "id": "fc_1", "call_id": "call_1",
                "name": toolName, "arguments": "{}", "status": "completed"
            ]]
        } else {
            output = [[
                "type": "message", "id": "msg_1", "role": "assistant",
                "status": "completed",
                "content": [["type": "output_text", "text": text, "annotations": [String]()]]
            ]]
        }
        var resp: [String: Any] = [
            "id": "resp_1", "object": "response", "status": "completed",
            "model": "local-fast", "output": output
        ]
        if includeUsage {
            resp["usage"] = ["input_tokens": 11, "output_tokens": 7, "total_tokens": 18]
        }
        if !stream {
            return json(200, resp)
        }
        var lines = ""
        var sequence = 0
        func ev(_ type: String, _ extra: [String: Any]) {
            var event = extra
            event["type"] = type
            event["sequence_number"] = sequence
            sequence += 1
            lines += "event: \(type)\ndata: \(jsonString(event))\n\n"
        }
        var created = resp
        created["status"] = "in_progress"
        created["output"] = [[String: Any]]()
        ev("response.created", ["response": created])
        if wantCustom {
            var pending = output[0]
            pending["input"] = ""
            pending["status"] = "in_progress"
            ev("response.output_item.added", ["output_index": 0, "item": pending])
            ev("response.custom_tool_call_input.delta",
               ["item_id": "ctc_1", "output_index": 0, "delta": "READ"])
            ev("response.custom_tool_call_input.done",
               ["item_id": "ctc_1", "output_index": 0, "input": "READ"])
            ev("response.output_item.done", ["output_index": 0, "item": output[0]])
        } else if !wantFunction {
            ev("response.output_text.delta",
               ["item_id": "msg_1", "output_index": 0, "content_index": 0, "delta": text])
        }
        ev("response.completed", ["response": resp])
        return GatewayProbeHTTPResponse(statusCode: 200, data: Data(lines.utf8))
    }

    private func messages(_ request: GatewayProbeRequest) -> GatewayProbeHTTPResponse {
        let body = parse(request.body)
        let stream = body["stream"] as? Bool ?? false
        let tools = body["tools"] as? [[String: Any]] ?? []
        var toolResult: String?
        if let msgs = body["messages"] as? [[String: Any]] {
            for message in msgs {
                if let blocks = message["content"] as? [[String: Any]] {
                    for block in blocks where (block["type"] as? String) == "tool_result" {
                        toolResult = block["content"] as? String
                    }
                }
            }
        }
        let wantTool = !tools.isEmpty && toolResult == nil
        let text = toolResult.map { toolReplyText ?? $0 } ?? "stub response"
        var content: [[String: Any]] = []
        var stop = "end_turn"
        if wantTool {
            content = [[
                "type": "tool_use", "id": "toolu_1",
                "name": tools.first?["name"] as? String ?? "stub_tool",
                "input": [String: Any]()
            ]]
            stop = "tool_use"
        } else {
            content = [["type": "text", "text": text]]
        }
        var resp: [String: Any] = [
            "id": "msg_1", "type": "message", "role": "assistant",
            "model": "local-fast", "content": content,
            "stop_reason": stop, "stop_sequence": NSNull()
        ]
        if includeUsage {
            resp["usage"] = ["input_tokens": 11, "output_tokens": 7]
        }
        if !stream {
            return json(200, resp)
        }
        var lines = ""
        func ev(_ type: String, _ data: [String: Any]) {
            var event = data
            event["type"] = type
            lines += "event: \(type)\ndata: \(jsonString(event))\n\n"
        }
        var base = resp
        base["content"] = [[String: Any]]()
        ev("message_start", ["message": base])
        var startBlock = content[0]
        if wantTool {
            ev("content_block_start", ["index": 0, "content_block": startBlock])
            ev("content_block_delta", [
                "index": 0,
                "delta": ["type": "input_json_delta", "partial_json": "{}"]
            ])
        } else {
            startBlock["text"] = ""
            ev("content_block_start", ["index": 0, "content_block": startBlock])
            ev("content_block_delta", [
                "index": 0,
                "delta": ["type": "text_delta", "text": text]
            ])
        }
        ev("content_block_stop", ["index": 0])
        ev("message_delta", [
            "delta": ["stop_reason": stop, "stop_sequence": NSNull()],
            "usage": ["output_tokens": 7]
        ])
        ev("message_stop", [:])
        return GatewayProbeHTTPResponse(statusCode: 200, data: Data(lines.utf8))
    }

    private func json(_ status: Int, _ object: [String: Any]) -> GatewayProbeHTTPResponse {
        GatewayProbeHTTPResponse(statusCode: status, data: Data(jsonString(object).utf8))
    }

    private func jsonString(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func parse(_ data: Data?) -> [String: Any] {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any] else {
            return [:]
        }
        return dict
    }
}

private final class FakeGatewayTransport: OllamaHTTPTransport, @unchecked Sendable {
    var responseData = Data("{\"data\":[{\"id\":\"local-fast\"}]}".utf8)

    func get(url: URL, bearerToken: String) throws -> OllamaHTTPResponse {
        OllamaHTTPResponse(statusCode: 200, data: responseData)
    }
}

private final class GatewayProbeFakeSecretStore: SecretStoring, @unchecked Sendable {
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
