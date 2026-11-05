import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct MemoryCheckReport: Codable, Equatable, Sendable {
    public let passed: Bool
    public let protocolVersion: String
    public let toolCount: Int
    public let readAvailable: Bool
    public let writeAvailable: Bool

    enum CodingKeys: String, CodingKey {
        case passed
        case protocolVersion = "protocol_version"
        case toolCount = "tool_count"
        case readAvailable = "read_available"
        case writeAvailable = "write_available"
    }
}

public struct MemoryHTTPRequest: Equatable, Sendable {
    public let url: URL
    public let bearerToken: String
    public let body: Data
    public let sessionID: String?
    public let protocolVersion: String?
}

public struct MemoryHTTPResponse: Equatable, Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let data: Data

    public init(statusCode: Int, headers: [String: String], data: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.data = data
    }
}

public enum MemoryCheckError: Error, Equatable, Sendable {
    case timeout
    case connection

    public var message: String {
        switch self {
        case .timeout:
            return "The memory connection check took too long."
        case .connection:
            return "The memory service could not be checked. Verify its address and credential."
        }
    }
}

public protocol MemoryHTTPTransport: Sendable {
    func post(_ request: MemoryHTTPRequest) throws -> MemoryHTTPResponse
}

public enum MemoryConnectionChecker {
    public static let maximumTotalResponseBytes = 1_048_576
    static let clientProtocolVersion = "2025-03-26"
    static let supportedProtocolVersions: Set<String> = [
        "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"
    ]
    static let readTools: Set<String> = [
        "search_memories", "list_memories", "get_memory",
        "memory_history", "memory_operation_status"
    ]
    static let writeTools: Set<String> = [
        "save_memory", "edit_memory", "undo_memory",
        "delete_memory", "restore_memory"
    ]

    public static func check(
        profile: ResolvedMemoryProfile,
        transport: MemoryHTTPTransport,
        deadlineSeconds: TimeInterval = 10
    ) throws -> MemoryCheckReport {
        var session = Session(
            profile: profile,
            transport: transport,
            deadline: Date().addingTimeInterval(deadlineSeconds)
        )
        return try session.run()
    }

    private struct Session {
        let profile: ResolvedMemoryProfile
        let transport: MemoryHTTPTransport
        let deadline: Date
        var nextID = 1
        var requestCount = 0
        var totalResponseBytes = 0
        var sessionID: String?
        var negotiatedVersion: String?

        mutating func run() throws -> MemoryCheckReport {
            guard let url = URL(string: profile.endpoint) else {
                throw MemoryCheckError.connection
            }
            let initializeID = allocateID()
            let initializeBody = try jsonBody([
                "jsonrpc": "2.0",
                "id": initializeID,
                "method": "initialize",
                "params": [
                    "protocolVersion": clientProtocolVersion,
                    "capabilities": [String: String](),
                    "clientInfo": ["name": "je", "version": JEVersion.current]
                ]
            ])
            let initializeResponse = try perform(url: url, body: initializeBody)
            sessionID = header("mcp-session-id", in: initializeResponse.headers)
            let initializeResult = try result(in: initializeResponse, expectedID: initializeID)
            guard let version = initializeResult["protocolVersion"] as? String,
                  supportedProtocolVersions.contains(version) else {
                throw MemoryCheckError.connection
            }
            negotiatedVersion = version

            let initializedBody = try jsonBody([
                "jsonrpc": "2.0",
                "method": "notifications/initialized"
            ])
            let initializedResponse = try perform(url: url, body: initializedBody)
            guard [200, 202, 204].contains(initializedResponse.statusCode) else {
                throw MemoryCheckError.connection
            }
            if let updated = header("mcp-session-id", in: initializedResponse.headers) {
                sessionID = updated
            }

            var names: Set<String> = []
            var seenCursors: Set<String> = []
            var cursor: String?
            for page in 0..<4 {
                let requestID = allocateID()
                var params: [String: Any] = [:]
                if let cursor {
                    params["cursor"] = cursor
                }
                let body = try jsonBody([
                    "jsonrpc": "2.0",
                    "id": requestID,
                    "method": "tools/list",
                    "params": params
                ])
                let response = try perform(url: url, body: body)
                if let updated = header("mcp-session-id", in: response.headers) {
                    sessionID = updated
                }
                let listing = try result(in: response, expectedID: requestID)
                guard let tools = listing["tools"] as? [Any] else {
                    throw MemoryCheckError.connection
                }
                for item in tools {
                    guard let object = item as? [String: Any],
                          let name = object["name"] as? String,
                          !name.isEmpty else {
                        throw MemoryCheckError.connection
                    }
                    guard names.insert(name).inserted, names.count <= 100 else {
                        throw MemoryCheckError.connection
                    }
                }
                let next = listing["nextCursor"]
                if next == nil || next is NSNull {
                    cursor = nil
                    break
                }
                guard let nextCursor = next as? String,
                      page < 3,
                      seenCursors.insert(nextCursor).inserted else {
                    throw MemoryCheckError.connection
                }
                cursor = nextCursor
            }
            if cursor != nil {
                throw MemoryCheckError.connection
            }
            let read = MemoryConnectionChecker.readTools.isSubset(of: names)
            return MemoryCheckReport(
                passed: read,
                protocolVersion: version,
                toolCount: names.count,
                readAvailable: read,
                writeAvailable: MemoryConnectionChecker.writeTools.isSubset(of: names)
            )
        }

        private mutating func allocateID() -> Int {
            defer { nextID += 1 }
            return nextID
        }

        private mutating func perform(url: URL, body: Data) throws -> MemoryHTTPResponse {
            guard Date() < deadline else {
                throw MemoryCheckError.timeout
            }
            requestCount += 1
            guard requestCount <= 16 else {
                throw MemoryCheckError.connection
            }
            let response: MemoryHTTPResponse
            do {
                response = try transport.post(MemoryHTTPRequest(
                    url: url,
                    bearerToken: profile.secret,
                    body: body,
                    sessionID: sessionID,
                    protocolVersion: negotiatedVersion
                ))
            } catch let error as MemoryCheckError {
                throw error
            } catch {
                throw MemoryCheckError.connection
            }
            guard Date() <= deadline else {
                throw MemoryCheckError.timeout
            }
            totalResponseBytes += response.data.count
            guard totalResponseBytes <= maximumTotalResponseBytes else {
                throw MemoryCheckError.connection
            }
            if let encoding = header("content-encoding", in: response.headers),
               encoding.lowercased() != "identity" {
                throw MemoryCheckError.connection
            }
            return response
        }

        private func result(
            in response: MemoryHTTPResponse,
            expectedID: Int
        ) throws -> [String: Any] {
            guard (200...299).contains(response.statusCode) else {
                throw MemoryCheckError.connection
            }
            let object = try decodeRPCObject(data: response.data, expectedID: expectedID)
            guard object["error"] == nil || object["error"] is NSNull else {
                throw MemoryCheckError.connection
            }
            guard let result = object["result"] as? [String: Any] else {
                throw MemoryCheckError.connection
            }
            return result
        }

        private func decodeRPCObject(data: Data, expectedID: Int) throws -> [String: Any] {
            let candidates: [Data]
            if let text = String(data: data, encoding: .utf8),
               text.contains("data:") {
                candidates = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .compactMap { line -> Data? in
                        let value = String(line)
                        guard value.hasPrefix("data:") else { return nil }
                        return Data(value.dropFirst("data:".count)
                            .trimmingCharacters(in: .whitespaces).utf8)
                    }
            } else {
                candidates = [data]
            }
            for candidate in candidates where !candidate.isEmpty {
                guard let parsed = try? JSONSerialization.jsonObject(with: candidate, options: []),
                      let object = parsed as? [String: Any],
                      (object["jsonrpc"] as? String) == "2.0",
                      Self.idMatches(object["id"], expectedID: expectedID) else {
                    continue
                }
                return object
            }
            throw MemoryCheckError.connection
        }

        private static func idMatches(_ raw: Any?, expectedID: Int) -> Bool {
            if let number = raw as? NSNumber {
                return number.intValue == expectedID
            }
            if let string = raw as? String {
                return string == String(expectedID)
            }
            return false
        }

        private func header(_ name: String, in headers: [String: String]) -> String? {
            for (key, value) in headers where key.lowercased() == name {
                return value
            }
            return nil
        }

        private func jsonBody(_ object: [String: Any]) throws -> Data {
            do {
                return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            } catch {
                throw MemoryCheckError.connection
            }
        }
    }
}

public struct URLSessionMemoryHTTPTransport: MemoryHTTPTransport {
    public init() {}

    public func post(_ request: MemoryHTTPRequest) throws -> MemoryHTTPResponse {
        let delegate = BoundedDataDelegate(limit: MemoryConnectionChecker.maximumTotalResponseBytes)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
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
            timeoutInterval: 10
        )
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = request.body
        urlRequest.setValue("Bearer " + request.bearerToken, forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let sessionID = request.sessionID {
            urlRequest.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        if let version = request.protocolVersion {
            urlRequest.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version")
        }

        let task = session.dataTask(with: urlRequest)
        delegate.attach(task)
        task.resume()
        if delegate.semaphore.wait(timeout: .now() + 12) == .timedOut {
            task.cancel()
            throw MemoryCheckError.timeout
        }
        if delegate.exceededLimit {
            throw MemoryCheckError.connection
        }
        if let error = delegate.error {
            if (error as? URLError)?.code == .timedOut {
                throw MemoryCheckError.timeout
            }
            throw MemoryCheckError.connection
        }
        guard let statusCode = delegate.statusCode else {
            throw MemoryCheckError.connection
        }
        return MemoryHTTPResponse(
            statusCode: statusCode,
            headers: delegate.headers,
            data: delegate.data
        )
    }
}
