import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum GatewayProbeProtocol: String, Codable, Equatable, Sendable {
    case responses
    case messages
}

public struct GatewayProbeRequest: Equatable, Sendable {
    public let method: String
    public let url: URL
    public let bearerToken: String?
    public let accept: String
    public let body: Data?

    public init(method: String, url: URL, bearerToken: String?, accept: String, body: Data?) {
        self.method = method
        self.url = url
        self.bearerToken = bearerToken
        self.accept = accept
        self.body = body
    }
}

public struct GatewayProbeHTTPResponse: Equatable, Sendable {
    public let statusCode: Int
    public let data: Data

    public init(statusCode: Int, data: Data) {
        self.statusCode = statusCode
        self.data = data
    }
}

/// Transport failures throw `GatewayCheckError` (deadline, sizeLimit, or
/// unreachable). Any HTTP status returns as a response for the checks to judge.
public protocol GatewayProbeTransport: Sendable {
    func perform(_ request: GatewayProbeRequest) throws -> GatewayProbeHTTPResponse
}

public struct URLSessionGatewayProbeTransport: GatewayProbeTransport {
    public init() {}

    public func perform(_ request: GatewayProbeRequest) throws -> GatewayProbeHTTPResponse {
        let delegate = BoundedDataDelegate(limit: OllamaConnectionChecker.maximumResponseBytes)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 120
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpShouldUsePipelining = false
        configuration.connectionProxyDictionary = [:]

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        defer { session.invalidateAndCancel() }

        var urlRequest = URLRequest(
            url: request.url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 120
        )
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        if let bearerToken = request.bearerToken {
            urlRequest.setValue("Bearer " + bearerToken, forHTTPHeaderField: "Authorization")
        }
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "Anthropic-Version")
        urlRequest.setValue(request.accept, forHTTPHeaderField: "Accept")
        if request.body != nil {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let task = session.dataTask(with: urlRequest)
        delegate.attach(task)
        task.resume()
        if delegate.semaphore.wait(timeout: .now() + 125) == .timedOut {
            task.cancel()
            throw GatewayCheckError.deadline
        }
        if delegate.exceededLimit {
            throw GatewayCheckError.sizeLimit
        }
        if let error = delegate.error {
            if (error as? URLError)?.code == .timedOut {
                throw GatewayCheckError.deadline
            }
            throw GatewayCheckError.unreachable
        }
        guard let statusCode = delegate.statusCode else {
            throw GatewayCheckError.unreachable
        }
        return GatewayProbeHTTPResponse(statusCode: statusCode, data: delegate.data)
    }
}

public enum GatewayProbeEvidenceValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case string(String)
    case object([String: GatewayProbeEvidenceValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .object(try container.decode([String: GatewayProbeEvidenceValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

public struct GatewayProbeCheck: Codable, Equatable, Sendable {
    public let name: String
    public let status: String
    public let evidence: [String: GatewayProbeEvidenceValue]?
    public let error: String?
    public let httpStatus: Int?
    public let elapsedSeconds: Double

    enum CodingKeys: String, CodingKey {
        case name
        case status
        case evidence
        case error
        case httpStatus = "http_status"
        case elapsedSeconds = "elapsed_seconds"
    }
}

public struct GatewayProbeCounts: Codable, Equatable, Sendable {
    public let passed: Int
    public let failed: Int
    public let notRun: Int

    enum CodingKeys: String, CodingKey {
        case passed
        case failed
        case notRun = "not_run"
    }
}

public struct GatewayProbeReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let createdAt: String
    public let endpoint: String
    public let model: String
    public let checks: [GatewayProbeCheck]
    public let protocols: [String]
    public let limitations: [String]
    public let counts: GatewayProbeCounts
    public let passed: Bool

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case createdAt = "created_at"
        case endpoint
        case model
        case checks
        case protocols
        case limitations
        case counts
        case passed
    }

    public static let fixedLimitations = [
        "Synthetic protocol checks do not establish native harness behavior or model quality.",
        "Cancellation and backend resource release are not tested.",
        "Usage is gateway-reported; missing or partial usage is not an accounting pass.",
        "Authentication checks cover model discovery, not every inference route."
    ]
}

public struct GatewayProbeReportStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    @discardableResult
    public func write(_ report: GatewayProbeReport, profileName: String) throws -> URL {
        guard ProfileNameValidator.isValid(profileName) else {
            throw StateStoreError("The protocol probe report could not be written.")
        }
        let store = ProfileStore(directory: directory)
        let reports = directory.appendingPathComponent("reports", isDirectory: true)
        try store.ensurePrivateDirectory(directory)
        try store.ensurePrivateDirectory(reports)
        let path = reports.appendingPathComponent(profileName + ".json")
        let data: Data
        do {
            data = Data(try StableJSON.encode(report).utf8)
        } catch {
            throw StateStoreError("The protocol probe report could not be written.")
        }
        let temporary = reports.appendingPathComponent(
            ".pending-" + UUID().uuidString.lowercased()
        )
        do {
            guard FileManager.default.createFile(
                atPath: temporary.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw StateStoreError("The protocol probe report could not be written.")
            }
            if FileManager.default.fileExists(atPath: path.path) {
                try FileManager.default.removeItem(at: path)
            }
            try FileManager.default.linkItem(at: temporary, to: path)
            try? FileManager.default.removeItem(at: temporary)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: path.path)
        } catch let error as StateStoreError {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw StateStoreError("The protocol probe report could not be written.")
        }
        return path
    }
}

/// Bounded port of the Python 0.2.0 `doctor --probe` checks, mapped from the
/// installed client's observed requests, reports, and exit behavior. Checks
/// run in the oracle's order and stop at the first failure. Streamed payloads
/// are verified from a bounded buffered read, matching the recorded evidence
/// shape rather than incremental arrival timing.
public enum GatewayProbeRunner {
    private static let wrongKey = "je-probe-invalid-key"
    private static let toolName = "read_probe_value"
    private static let customToolName = "read_custom_probe"
    private static let toolDescription = "Returns a fresh probe value."
    private static let customDescription =
        "Accepts the plain text READ and returns a fresh probe value. No commands are executed."
    private static let replyPrompt = "Reply with exactly READY."
    private static let toolPrompt =
        "Call read_probe_value exactly once. Then reply with only the value it returns."
    private static let customPrompt =
        "Call read_custom_probe exactly once with input READ. Then reply with only the value it returns."

    public static func run(
        profile: ResolvedConnectionProfile,
        protocols: [GatewayProbeProtocol],
        transport: GatewayProbeTransport,
        probeValue: (() -> String)? = nil
    ) -> GatewayProbeReport {
        var session = Session(
            profile: profile,
            transport: transport,
            nextProbeValue: probeValue ?? { makeProbeValue() }
        )
        return session.run(protocols: protocols)
    }

    public static func makeProbeValue() -> String {
        let bytes = (0..<12).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }
        return "probe_" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    private enum Outcome: Error {
        case passed([String: GatewayProbeEvidenceValue])
        case failed(code: String, httpStatus: Int?)
    }

    private static func failed(_ code: String) -> Outcome {
        .failed(code: code, httpStatus: nil)
    }

    private struct Session {
        let profile: ResolvedConnectionProfile
        let transport: GatewayProbeTransport
        let nextProbeValue: () -> String
        var checks: [GatewayProbeCheck] = []

        mutating func run(protocols: [GatewayProbeProtocol]) -> GatewayProbeReport {
            let createdAt = Self.timestamp()
            var sequence: [(name: String, body: (inout Session) -> Outcome)] = [
                ("missing_key_rejected", { $0.keyRejected(bearer: nil) }),
                ("wrong_key_rejected", { $0.keyRejected(bearer: Self.wrongBearer(for: $0.profile)) }),
                ("selected_model_visible", { $0.selectedModelVisible() })
            ]
            for proto in protocols {
                switch proto {
                case .responses:
                    sequence += [
                        ("responses_reply", { $0.responsesReply() }),
                        ("responses_stream", { $0.responsesStream() }),
                        ("responses_tool_continuation", { $0.responsesToolContinuation() }),
                        ("responses_custom_tool_continuation", { $0.responsesCustomToolContinuation() })
                    ]
                case .messages:
                    sequence += [
                        ("messages_reply", { $0.messagesReply() }),
                        ("messages_stream", { $0.messagesStream() }),
                        ("messages_tool_continuation", { $0.messagesToolContinuation() })
                    ]
                }
            }
            for step in sequence {
                let started = Date()
                let outcome = step.body(&self)
                let elapsed = (Date().timeIntervalSince(started) * 1000).rounded() / 1000
                switch outcome {
                case .passed(let evidence):
                    checks.append(GatewayProbeCheck(
                        name: step.name, status: "passed", evidence: evidence,
                        error: nil, httpStatus: nil, elapsedSeconds: elapsed))
                case .failed(let code, let httpStatus):
                    checks.append(GatewayProbeCheck(
                        name: step.name, status: "failed", evidence: nil,
                        error: code, httpStatus: httpStatus, elapsedSeconds: elapsed))
                }
                if case .failed = outcome {
                    break
                }
            }
            let passedCount = checks.filter { $0.status == "passed" }.count
            let failedCount = checks.count - passedCount
            return GatewayProbeReport(
                schemaVersion: 1,
                createdAt: createdAt,
                endpoint: profile.endpoint,
                model: profile.model,
                checks: checks,
                protocols: protocols.map(\.rawValue),
                limitations: GatewayProbeReport.fixedLimitations,
                counts: GatewayProbeCounts(
                    passed: passedCount,
                    failed: failedCount,
                    notRun: sequence.count - checks.count
                ),
                passed: failedCount == 0 && checks.count == sequence.count
            )
        }

        private static func wrongBearer(for profile: ResolvedConnectionProfile) -> String {
            profile.secret == GatewayProbeRunner.wrongKey
                ? GatewayProbeRunner.wrongKey + "-2"
                : GatewayProbeRunner.wrongKey
        }

        private static func timestamp() -> String {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'+00:00'"
            return formatter.string(from: Date())
        }

        private func perform(
            method: String,
            path: String,
            bearer: String?,
            accept: String = "application/json",
            body: [String: Any]? = nil
        ) -> Result<GatewayProbeHTTPResponse, Outcome> {
            guard let url = URL(string: profile.apiBase + path) else {
                return .failure(GatewayProbeRunner.failed("connection_error"))
            }
            let bodyData: Data?
            if let body {
                guard let data = try? JSONSerialization.data(
                    withJSONObject: body, options: [.sortedKeys]) else {
                    return .failure(GatewayProbeRunner.failed("connection_error"))
                }
                bodyData = data
            } else {
                bodyData = nil
            }
            do {
                return .success(try transport.perform(GatewayProbeRequest(
                    method: method, url: url, bearerToken: bearer,
                    accept: accept, body: bodyData)))
            } catch let error as GatewayCheckError {
                switch error {
                case .deadline:
                    return .failure(GatewayProbeRunner.failed("timeout"))
                case .sizeLimit:
                    return .failure(GatewayProbeRunner.failed("response_too_large"))
                case .httpStatus(let status):
                    return .failure(.failed(code: "http_error", httpStatus: status))
                case .invalidListing, .unreachable:
                    return .failure(GatewayProbeRunner.failed("connection_error"))
                }
            } catch {
                return .failure(GatewayProbeRunner.failed("connection_error"))
            }
        }

        private func requireOK(_ response: GatewayProbeHTTPResponse) -> Outcome? {
            (200...299).contains(response.statusCode)
                ? nil
                : .failed(code: "http_error", httpStatus: response.statusCode)
        }

        private func keyRejected(bearer: String?) -> Outcome {
            switch perform(method: "GET", path: "/models", bearer: bearer) {
            case .failure(let outcome):
                return outcome
            case .success(let response):
                if [401, 403].contains(response.statusCode) {
                    return .passed(["http_status": .int(response.statusCode)])
                }
                if (200...299).contains(response.statusCode) {
                    return GatewayProbeRunner.failed("authentication_accepted")
                }
                return .failed(code: "http_error", httpStatus: response.statusCode)
            }
        }

        private func selectedModelVisible() -> Outcome {
            switch perform(method: "GET", path: "/models", bearer: profile.secret) {
            case .failure(let outcome):
                return outcome
            case .success(let response):
                if let failure = requireOK(response) {
                    return failure
                }
                guard let root = Self.jsonObject(response.data),
                      let models = root["data"] as? [Any] else {
                    return GatewayProbeRunner.failed("incomplete_response")
                }
                let visible = models.contains { item in
                    ((item as? [String: Any])?["id"] as? String) == profile.model
                }
                let evidence: [String: GatewayProbeEvidenceValue] = [
                    "selected_model_visible": .bool(visible),
                    "model_count": .int(models.count)
                ]
                return visible
                    ? .passed(evidence)
                    : GatewayProbeRunner.failed("model_not_visible")
            }
        }

        private static func jsonObject(_ data: Data) -> [String: Any]? {
            guard let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
                  let object = parsed as? [String: Any] else {
                return nil
            }
            return object
        }

        private static func exactInt(_ raw: Any?) -> Int? {
            guard let number = raw as? NSNumber else { return nil }
            let type = String(cString: number.objCType)
            guard type != "c" && type != "B" else { return nil }
            let double = number.doubleValue
            guard double.rounded() == double,
                  double >= 0, double <= Double(Int.max) else {
                return nil
            }
            return number.intValue
        }

        private static func usageEvidence(
            _ raw: Any?,
            required: [String]
        ) -> [String: GatewayProbeEvidenceValue] {
            guard let dict = raw as? [String: Any] else {
                return ["usage": .null, "usage_status": .string("missing")]
            }
            var values: [String: GatewayProbeEvidenceValue] = [:]
            for key in ["input_tokens", "output_tokens", "total_tokens"] {
                if let value = exactInt(dict[key]) {
                    values[key] = .int(value)
                }
            }
            let complete = required.allSatisfy { values[$0] != nil }
            return [
                "usage": .object(values),
                "usage_status": .string(complete ? "complete" : "partial"),
                "usage_source": .string("gateway_reported")
            ]
        }

        private struct SSEEvent {
            let type: String
            let object: [String: Any]
        }

        private static func parseSSE(_ data: Data) -> [SSEEvent]? {
            guard let raw = String(data: data, encoding: .utf8) else {
                return nil
            }
            let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
            var events: [SSEEvent] = []
            for block in text.components(separatedBy: "\n\n") {
                var eventName: String?
                var payloads: [String] = []
                for line in block.components(separatedBy: "\n") {
                    if line.hasPrefix("event:") {
                        eventName = String(line.dropFirst("event:".count))
                            .trimmingCharacters(in: .whitespaces)
                    } else if line.hasPrefix("data:") {
                        payloads.append(String(line.dropFirst("data:".count))
                            .trimmingCharacters(in: .whitespaces))
                    }
                }
                if payloads.isEmpty {
                    continue
                }
                let payload = payloads.joined(separator: "\n")
                if payload == "[DONE]" {
                    continue
                }
                guard let object = jsonObject(Data(payload.utf8)),
                      let type = (object["type"] as? String) ?? eventName,
                      !type.isEmpty else {
                    return nil
                }
                events.append(SSEEvent(type: type, object: object))
            }
            return events
        }

        private static func trimmed(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private static let responsesUsageFields = ["input_tokens", "output_tokens", "total_tokens"]
        private static let messagesUsageFields = ["input_tokens", "output_tokens"]

        private static var functionTool: [String: Any] {
            [
                "type": "function",
                "name": GatewayProbeRunner.toolName,
                "description": GatewayProbeRunner.toolDescription,
                "parameters": [
                    "type": "object",
                    "properties": [String: Any](),
                    "required": [String](),
                    "additionalProperties": false
                ]
            ]
        }

        private static var customTool: [String: Any] {
            [
                "type": "custom",
                "name": GatewayProbeRunner.customToolName,
                "format": ["type": "text"],
                "description": GatewayProbeRunner.customDescription
            ]
        }

        private static func responsesText(_ root: [String: Any]) -> String {
            var parts: [String] = []
            for item in root["output"] as? [Any] ?? [] {
                guard let object = item as? [String: Any],
                      (object["type"] as? String) == "message" else {
                    continue
                }
                for block in object["content"] as? [Any] ?? [] {
                    guard let content = block as? [String: Any],
                          (content["type"] as? String) == "output_text",
                          let text = content["text"] as? String else {
                        continue
                    }
                    parts.append(text)
                }
            }
            return parts.joined()
        }

        private func completedResponsesText(
            _ response: GatewayProbeHTTPResponse
        ) -> Result<(text: String, root: [String: Any]), Outcome> {
            if let failure = requireOK(response) {
                return .failure(failure)
            }
            guard let root = Self.jsonObject(response.data),
                  (root["status"] as? String) == "completed" else {
                return .failure(GatewayProbeRunner.failed("incomplete_response"))
            }
            let text = Self.responsesText(root)
            guard !Self.trimmed(text).isEmpty else {
                return .failure(GatewayProbeRunner.failed("incomplete_response"))
            }
            return .success((text: text, root: root))
        }

        private func responsesReply() -> Outcome {
            let body: [String: Any] = [
                "model": profile.model,
                "input": GatewayProbeRunner.replyPrompt,
                "max_output_tokens": 64,
                "stream": false
            ]
            switch perform(method: "POST", path: "/responses", bearer: profile.secret, body: body) {
            case .failure(let outcome):
                return outcome
            case .success(let response):
                switch completedResponsesText(response) {
                case .failure(let outcome):
                    return outcome
                case .success(let completed):
                    var evidence: [String: GatewayProbeEvidenceValue] = [
                        "nonempty_text": .bool(true),
                        "terminal_status": .string("completed")
                    ]
                    evidence.merge(
                        Self.usageEvidence(completed.root["usage"], required: Self.responsesUsageFields)
                    ) { _, new in new }
                    return .passed(evidence)
                }
            }
        }

        private func responsesStream() -> Outcome {
            let body: [String: Any] = [
                "model": profile.model,
                "input": GatewayProbeRunner.replyPrompt,
                "max_output_tokens": 64,
                "stream": true
            ]
            switch perform(
                method: "POST", path: "/responses", bearer: profile.secret,
                accept: "text/event-stream", body: body) {
            case .failure(let outcome):
                return outcome
            case .success(let response):
                if let failure = requireOK(response) {
                    return failure
                }
                guard let events = Self.parseSSE(response.data) else {
                    return GatewayProbeRunner.failed("invalid_sse")
                }
                guard let terminal = events.last(where: {
                    ["response.completed", "response.failed", "response.incomplete"]
                        .contains($0.type)
                }) else {
                    return GatewayProbeRunner.failed("invalid_sse")
                }
                guard terminal.type == "response.completed",
                      let completed = terminal.object["response"] as? [String: Any],
                      (completed["status"] as? String) == "completed" else {
                    return GatewayProbeRunner.failed("incomplete_response")
                }
                let deltas = events.filter { $0.type == "response.output_text.delta" }
                let text = deltas.compactMap { $0.object["delta"] as? String }.joined()
                guard !deltas.isEmpty, !Self.trimmed(text).isEmpty else {
                    return GatewayProbeRunner.failed("incomplete_response")
                }
                var evidence: [String: GatewayProbeEvidenceValue] = [
                    "terminal_event": .string("response.completed"),
                    "events": .int(events.count),
                    "text_delta_events": .int(deltas.count),
                    "nonempty_text": .bool(true),
                    "terminal_status": .string("completed")
                ]
                evidence.merge(
                    Self.usageEvidence(completed["usage"], required: Self.responsesUsageFields)
                ) { _, new in new }
                return .passed(evidence)
            }
        }

        private func responsesToolContinuation() -> Outcome {
            let userItem: [String: Any] = [
                "role": "user", "content": GatewayProbeRunner.toolPrompt
            ]
            let first: [String: Any] = [
                "model": profile.model,
                "input": [userItem],
                "tools": [Self.functionTool],
                "tool_choice": [
                    "type": "function", "name": GatewayProbeRunner.toolName
                ],
                "max_output_tokens": 256,
                "stream": false
            ]
            let initial: [String: Any]
            switch perform(method: "POST", path: "/responses", bearer: profile.secret, body: first) {
            case .failure(let outcome):
                return outcome
            case .success(let response):
                if let failure = requireOK(response) {
                    return failure
                }
                guard let root = Self.jsonObject(response.data),
                      (root["status"] as? String) == "completed" else {
                    return GatewayProbeRunner.failed("incomplete_response")
                }
                initial = root
            }
            let calls = (initial["output"] as? [Any] ?? []).compactMap { item -> [String: Any]? in
                guard let object = item as? [String: Any],
                      (object["type"] as? String) == "function_call" else {
                    return nil
                }
                return object
            }
            guard calls.count == 1,
                  let call = calls.first,
                  (call["name"] as? String) == GatewayProbeRunner.toolName,
                  let callID = call["call_id"] as? String, !callID.isEmpty,
                  call["arguments"] is String else {
                return GatewayProbeRunner.failed("invalid_tool_call")
            }
            let value = nextProbeValue()
            let second: [String: Any] = [
                "model": profile.model,
                "tools": [Self.functionTool],
                "tool_choice": "none",
                "input": [
                    userItem, call,
                    ["type": "function_call_output", "call_id": callID, "output": value]
                ],
                "max_output_tokens": 128,
                "stream": false
            ]
            switch perform(method: "POST", path: "/responses", bearer: profile.secret, body: second) {
            case .failure(let outcome):
                return outcome
            case .success(let response):
                switch completedResponsesText(response) {
                case .failure(let outcome):
                    return outcome
                case .success(let completed):
                    guard Self.trimmed(completed.text) == value else {
                        return GatewayProbeRunner.failed("tool_result_mismatch")
                    }
                    return .passed([
                        "tool_call_count": .int(1),
                        "matching_result_sent": .bool(true),
                        "tool_result_observed": .bool(true),
                        "initial_usage": .object(Self.usageEvidence(
                            initial["usage"], required: Self.responsesUsageFields)),
                        "continuation_usage": .object(Self.usageEvidence(
                            completed.root["usage"], required: Self.responsesUsageFields))
                    ])
                }
            }
        }

        private func responsesCustomToolContinuation() -> Outcome {
            let userItem: [String: Any] = [
                "role": "user", "content": GatewayProbeRunner.customPrompt
            ]
            let first: [String: Any] = [
                "model": profile.model,
                "input": [userItem],
                "tools": [Self.customTool],
                "tool_choice": [
                    "type": "custom", "name": GatewayProbeRunner.customToolName
                ],
                "max_output_tokens": 256,
                "stream": true
            ]
            let initial: [String: Any]
            let eventCount: Int
            let inputDeltaCount: Int
            switch perform(
                method: "POST", path: "/responses", bearer: profile.secret,
                accept: "text/event-stream", body: first) {
            case .failure(let outcome):
                return outcome
            case .success(let response):
                if let failure = requireOK(response) {
                    return failure
                }
                guard let events = Self.parseSSE(response.data) else {
                    return GatewayProbeRunner.failed("invalid_sse")
                }
                guard let terminal = events.last(where: {
                    ["response.completed", "response.failed", "response.incomplete"]
                        .contains($0.type)
                }) else {
                    return GatewayProbeRunner.failed("invalid_sse")
                }
                guard terminal.type == "response.completed",
                      let completed = terminal.object["response"] as? [String: Any],
                      (completed["status"] as? String) == "completed" else {
                    return GatewayProbeRunner.failed("incomplete_response")
                }
                let deltas = events.filter {
                    $0.type == "response.custom_tool_call_input.delta"
                }
                let assembled = deltas
                    .compactMap { $0.object["delta"] as? String }.joined()
                let calls = (completed["output"] as? [Any] ?? [])
                    .compactMap { item -> [String: Any]? in
                        guard let object = item as? [String: Any],
                              (object["type"] as? String) == "custom_tool_call" else {
                            return nil
                        }
                        return object
                    }
                guard calls.count == 1,
                      let call = calls.first,
                      (call["name"] as? String) == GatewayProbeRunner.customToolName,
                      let callID = call["call_id"] as? String, !callID.isEmpty,
                      (call["input"] as? String) == "READ",
                      assembled == "READ" else {
                    return GatewayProbeRunner.failed("invalid_tool_call")
                }
                initial = completed
                eventCount = events.count
                inputDeltaCount = deltas.count
                let value = nextProbeValue()
                let second: [String: Any] = [
                    "model": profile.model,
                    "tools": [Self.customTool],
                    "tool_choice": "none",
                    "stream": false,
                    "input": [
                        userItem, call,
                        ["type": "custom_tool_call_output", "call_id": callID, "output": value]
                    ],
                    "max_output_tokens": 128
                ]
                switch perform(
                    method: "POST", path: "/responses", bearer: profile.secret, body: second) {
                case .failure(let outcome):
                    return outcome
                case .success(let secondResponse):
                    switch completedResponsesText(secondResponse) {
                    case .failure(let outcome):
                        return outcome
                    case .success(let completedText):
                        guard Self.trimmed(completedText.text) == value else {
                            return GatewayProbeRunner.failed("tool_result_mismatch")
                        }
                        return .passed([
                            "terminal_event": .string("response.completed"),
                            "events": .int(eventCount),
                            "input_delta_events": .int(inputDeltaCount),
                            "initial_usage": .object(Self.usageEvidence(
                                initial["usage"], required: Self.responsesUsageFields)),
                            "tool_call_count": .int(1),
                            "matching_result_sent": .bool(true),
                            "tool_result_observed": .bool(true),
                            "continuation_usage": .object(Self.usageEvidence(
                                completedText.root["usage"], required: Self.responsesUsageFields))
                        ])
                    }
                }
            }
        }

        private static var messagesTool: [String: Any] {
            [
                "name": GatewayProbeRunner.toolName,
                "description": GatewayProbeRunner.toolDescription,
                "input_schema": [
                    "type": "object",
                    "properties": [String: Any](),
                    "required": [String](),
                    "additionalProperties": false
                ]
            ]
        }

        private static func messagesText(_ root: [String: Any]) -> String {
            var parts: [String] = []
            for block in root["content"] as? [Any] ?? [] {
                guard let content = block as? [String: Any],
                      (content["type"] as? String) == "text",
                      let text = content["text"] as? String else {
                    continue
                }
                parts.append(text)
            }
            return parts.joined()
        }

        private func completedMessagesText(
            _ response: GatewayProbeHTTPResponse
        ) -> Result<(text: String, root: [String: Any]), Outcome> {
            if let failure = requireOK(response) {
                return .failure(failure)
            }
            guard let root = Self.jsonObject(response.data),
                  (root["type"] as? String) == "message" else {
                return .failure(GatewayProbeRunner.failed("incomplete_response"))
            }
            let text = Self.messagesText(root)
            guard !Self.trimmed(text).isEmpty else {
                return .failure(GatewayProbeRunner.failed("incomplete_response"))
            }
            return .success((text: text, root: root))
        }

        private func messagesReply() -> Outcome {
            let body: [String: Any] = [
                "model": profile.model,
                "messages": [[
                    "role": "user", "content": GatewayProbeRunner.replyPrompt
                ]],
                "max_tokens": 64,
                "stream": false
            ]
            switch perform(method: "POST", path: "/messages", bearer: profile.secret, body: body) {
            case .failure(let outcome):
                return outcome
            case .success(let response):
                switch completedMessagesText(response) {
                case .failure(let outcome):
                    return outcome
                case .success(let completed):
                    var evidence: [String: GatewayProbeEvidenceValue] = [
                        "nonempty_text": .bool(true)
                    ]
                    if let stopReason = completed.root["stop_reason"] as? String {
                        evidence["stop_reason"] = .string(stopReason)
                    }
                    evidence.merge(
                        Self.usageEvidence(completed.root["usage"], required: Self.messagesUsageFields)
                    ) { _, new in new }
                    return .passed(evidence)
                }
            }
        }

        private func messagesStream() -> Outcome {
            let body: [String: Any] = [
                "model": profile.model,
                "messages": [[
                    "role": "user", "content": GatewayProbeRunner.replyPrompt
                ]],
                "max_tokens": 64,
                "stream": true
            ]
            switch perform(
                method: "POST", path: "/messages", bearer: profile.secret,
                accept: "text/event-stream", body: body) {
            case .failure(let outcome):
                return outcome
            case .success(let response):
                if let failure = requireOK(response) {
                    return failure
                }
                guard let events = Self.parseSSE(response.data) else {
                    return GatewayProbeRunner.failed("invalid_sse")
                }
                guard events.last(where: { $0.type == "message_stop" }) != nil else {
                    return GatewayProbeRunner.failed("invalid_sse")
                }
                var textDeltas = 0
                var text = ""
                var stopReason: String?
                var usage: [String: Any] = [:]
                for event in events {
                    switch event.type {
                    case "message_start":
                        if let message = event.object["message"] as? [String: Any],
                           let startUsage = message["usage"] as? [String: Any] {
                            usage.merge(startUsage) { _, new in new }
                        }
                    case "content_block_delta":
                        if let delta = event.object["delta"] as? [String: Any],
                           (delta["type"] as? String) == "text_delta",
                           let piece = delta["text"] as? String {
                            textDeltas += 1
                            text += piece
                        }
                    case "message_delta":
                        if let delta = event.object["delta"] as? [String: Any],
                           let reason = delta["stop_reason"] as? String {
                            stopReason = reason
                        }
                        if let deltaUsage = event.object["usage"] as? [String: Any] {
                            usage.merge(deltaUsage) { _, new in new }
                        }
                    default:
                        break
                    }
                }
                guard textDeltas > 0, !Self.trimmed(text).isEmpty else {
                    return GatewayProbeRunner.failed("incomplete_response")
                }
                var evidence: [String: GatewayProbeEvidenceValue] = [
                    "terminal_event": .string("message_stop"),
                    "events": .int(events.count),
                    "text_delta_events": .int(textDeltas)
                ]
                if let stopReason {
                    evidence["stop_reason"] = .string(stopReason)
                }
                evidence.merge(
                    Self.usageEvidence(usage.isEmpty ? nil : usage,
                                       required: Self.messagesUsageFields)
                ) { _, new in new }
                return .passed(evidence)
            }
        }

        private func messagesToolContinuation() -> Outcome {
            let userMessage: [String: Any] = [
                "role": "user", "content": GatewayProbeRunner.toolPrompt
            ]
            let first: [String: Any] = [
                "model": profile.model,
                "messages": [userMessage],
                "tools": [Self.messagesTool],
                "tool_choice": [
                    "type": "tool", "name": GatewayProbeRunner.toolName
                ],
                "max_tokens": 256,
                "stream": false
            ]
            let initial: [String: Any]
            switch perform(method: "POST", path: "/messages", bearer: profile.secret, body: first) {
            case .failure(let outcome):
                return outcome
            case .success(let response):
                if let failure = requireOK(response) {
                    return failure
                }
                guard let root = Self.jsonObject(response.data),
                      (root["type"] as? String) == "message" else {
                    return GatewayProbeRunner.failed("incomplete_response")
                }
                initial = root
            }
            let calls = (initial["content"] as? [Any] ?? []).compactMap { item -> [String: Any]? in
                guard let object = item as? [String: Any],
                      (object["type"] as? String) == "tool_use" else {
                    return nil
                }
                return object
            }
            guard calls.count == 1,
                  let call = calls.first,
                  (call["name"] as? String) == GatewayProbeRunner.toolName,
                  let toolID = call["id"] as? String, !toolID.isEmpty else {
                return GatewayProbeRunner.failed("invalid_tool_call")
            }
            let value = nextProbeValue()
            let second: [String: Any] = [
                "model": profile.model,
                "tools": [Self.messagesTool],
                "tool_choice": ["type": "none"],
                "messages": [
                    userMessage,
                    ["role": "assistant", "content": [call]],
                    ["role": "user", "content": [[
                        "type": "tool_result", "tool_use_id": toolID, "content": value
                    ]]]
                ],
                "max_tokens": 128,
                "stream": false
            ]
            switch perform(method: "POST", path: "/messages", bearer: profile.secret, body: second) {
            case .failure(let outcome):
                return outcome
            case .success(let response):
                switch completedMessagesText(response) {
                case .failure(let outcome):
                    return outcome
                case .success(let completed):
                    guard Self.trimmed(completed.text) == value else {
                        return GatewayProbeRunner.failed("tool_result_mismatch")
                    }
                    return .passed([
                        "tool_call_count": .int(1),
                        "matching_result_sent": .bool(true),
                        "tool_result_observed": .bool(true),
                        "initial_usage": .object(Self.usageEvidence(
                            initial["usage"], required: Self.messagesUsageFields)),
                        "continuation_usage": .object(Self.usageEvidence(
                            completed.root["usage"], required: Self.messagesUsageFields))
                    ])
                }
            }
        }
    }
}

