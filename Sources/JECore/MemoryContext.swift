import Foundation

public enum MemoryContextError: Error, Equatable, Sendable {
    case invalidQuery
    case tooManyQueries
    case secretInContext
    case writeScopeRequired
    case searchUnavailable
    case unsupportedSchema
    case resultTooLarge
    case invalidResult
    case timeout
    case connection

    public var message: String {
        switch self {
        case .invalidQuery:
            return "A built-in memory search query is empty, duplicated, too long, or contains control characters."
        case .tooManyQueries:
            return "The built-in memory context contains too many searches."
        case .secretInContext:
            return "Built-in memory context may not contain the selected memory credential."
        case .writeScopeRequired:
            return "Built-in memory context requires a read-only memory credential."
        case .searchUnavailable:
            return "The memory service does not offer the search tool built-in context needs."
        case .unsupportedSchema:
            return "The memory search tool does not accept the single text query built-in context sends."
        case .resultTooLarge:
            return "A built-in memory search result exceeds the supported size."
        case .invalidResult:
            return "The memory service did not return a valid text search result."
        case .timeout:
            return "The built-in memory context fetch took too long."
        case .connection:
            return "Built-in memory context could not be fetched. Verify its address and credential."
        }
    }

    public var launchStatus: String {
        switch self {
        case .invalidQuery:
            return "memory_context_invalid_query"
        case .tooManyQueries:
            return "memory_context_too_many_queries"
        case .secretInContext:
            return "context_secret_rejected"
        case .writeScopeRequired:
            return "memory_context_read_scope_required"
        case .searchUnavailable:
            return "memory_context_search_unavailable"
        case .unsupportedSchema:
            return "memory_context_unsupported_schema"
        case .resultTooLarge:
            return "memory_context_too_large"
        case .invalidResult:
            return "memory_context_invalid_result"
        case .timeout:
            return "memory_context_timeout"
        case .connection:
            return "memory_context_unreachable"
        }
    }
}

/// Fetches explicit read-only memory search results as built-in context.
///
/// The frozen tool names come from `MemoryConnectionChecker`. Argument and
/// result schemas are verified against the advertised `tools/list` entry at
/// runtime: only `search_memories` with a single required string `query` is
/// called, only under a credential that advertises no write tools, and only
/// plain text result blocks are accepted. Anything else fails closed.
public enum MemoryContextFetcher {
    public static let searchToolName = "search_memories"
    public static let maximumQueries = 4

    public static func fetch(
        profile: ResolvedMemoryProfile,
        queries: [String],
        transport: MemoryHTTPTransport,
        deadlineSeconds: TimeInterval = 30
    ) throws -> [BuiltInContextFile] {
        try validate(queries: queries, secret: profile.secret)
        var session = Session(
            profile: profile,
            transport: transport,
            deadline: Date().addingTimeInterval(deadlineSeconds)
        )
        return try session.run(queries: queries)
    }

    private static func validate(queries: [String], secret: String) throws {
        guard !queries.isEmpty else {
            throw MemoryContextError.invalidQuery
        }
        guard queries.count <= maximumQueries else {
            throw MemoryContextError.tooManyQueries
        }
        guard Set(queries).count == queries.count else {
            throw MemoryContextError.invalidQuery
        }
        for query in queries {
            guard !query.isEmpty,
                  query.count <= BuiltInContextLoader.maximumSearchQueryCharacters,
                  !query.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                throw MemoryContextError.invalidQuery
            }
            if !secret.isEmpty && query.contains(secret) {
                throw MemoryContextError.secretInContext
            }
        }
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

        mutating func run(queries: [String]) throws -> [BuiltInContextFile] {
            guard let url = URL(string: profile.endpoint) else {
                throw MemoryContextError.connection
            }
            try initialize(url: url)
            let tools = try listTools(url: url)
            if !MemoryConnectionChecker.writeTools.isDisjoint(with: tools.keys) {
                throw MemoryContextError.writeScopeRequired
            }
            guard let schemaEntry = tools[searchToolName] else {
                throw MemoryContextError.searchUnavailable
            }
            guard Self.isSupportedSearchSchema(schemaEntry) else {
                throw MemoryContextError.unsupportedSchema
            }
            var sections: [BuiltInContextFile] = []
            for query in queries {
                let text = try search(url: url, query: query)
                sections.append(BuiltInContextFile(
                    relativePath: "[memory search: \(query)]",
                    text: text
                ))
            }
            return sections
        }

        private mutating func initialize(url: URL) throws {
            let initializeID = allocateID()
            let initializeBody = try jsonBody([
                "jsonrpc": "2.0",
                "id": initializeID,
                "method": "initialize",
                "params": [
                    "protocolVersion": MemoryConnectionChecker.clientProtocolVersion,
                    "capabilities": [String: String](),
                    "clientInfo": ["name": "je", "version": JEVersion.current]
                ]
            ])
            let initializeResponse = try perform(url: url, body: initializeBody)
            sessionID = header("mcp-session-id", in: initializeResponse.headers)
            let initializeResult = try result(in: initializeResponse, expectedID: initializeID)
            guard let version = initializeResult["protocolVersion"] as? String,
                  MemoryConnectionChecker.supportedProtocolVersions.contains(version) else {
                throw MemoryContextError.connection
            }
            negotiatedVersion = version

            let initializedBody = try jsonBody([
                "jsonrpc": "2.0",
                "method": "notifications/initialized"
            ])
            let initializedResponse = try perform(url: url, body: initializedBody)
            guard [200, 202, 204].contains(initializedResponse.statusCode) else {
                throw MemoryContextError.connection
            }
            if let updated = header("mcp-session-id", in: initializedResponse.headers) {
                sessionID = updated
            }
        }

        private mutating func listTools(url: URL) throws -> [String: [String: Any]?] {
            var schemas: [String: [String: Any]?] = [:]
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
                    throw MemoryContextError.connection
                }
                for item in tools {
                    guard let object = item as? [String: Any],
                          let name = object["name"] as? String,
                          !name.isEmpty else {
                        throw MemoryContextError.connection
                    }
                    guard schemas[name] == nil, schemas.count < 100 else {
                        throw MemoryContextError.connection
                    }
                    schemas[name] = object["inputSchema"] as? [String: Any]
                }
                let next = listing["nextCursor"]
                if next == nil || next is NSNull {
                    cursor = nil
                    break
                }
                guard let nextCursor = next as? String,
                      page < 3,
                      seenCursors.insert(nextCursor).inserted else {
                    throw MemoryContextError.connection
                }
                cursor = nextCursor
            }
            if cursor != nil {
                throw MemoryContextError.connection
            }
            return schemas
        }

        private mutating func search(url: URL, query: String) throws -> String {
            let requestID = allocateID()
            let body = try jsonBody([
                "jsonrpc": "2.0",
                "id": requestID,
                "method": "tools/call",
                "params": [
                    "name": searchToolName,
                    "arguments": ["query": query]
                ]
            ])
            let response = try perform(url: url, body: body)
            if let updated = header("mcp-session-id", in: response.headers) {
                sessionID = updated
            }
            let callResult = try result(in: response, expectedID: requestID)
            if let isError = callResult["isError"], !(isError is NSNull) {
                guard (isError as? Bool) == false else {
                    throw MemoryContextError.invalidResult
                }
            }
            guard let content = callResult["content"] as? [Any] else {
                throw MemoryContextError.invalidResult
            }
            var parts: [String] = []
            for item in content {
                guard let block = item as? [String: Any],
                      (block["type"] as? String) == "text",
                      let text = block["text"] as? String else {
                    throw MemoryContextError.invalidResult
                }
                parts.append(text)
            }
            let text = parts.joined(separator: "\n")
            guard text.utf8.count <= BuiltInContextLoader.maximumFileBytes else {
                throw MemoryContextError.resultTooLarge
            }
            guard !Self.isBinary(text) else {
                throw MemoryContextError.invalidResult
            }
            if !profile.secret.isEmpty && text.contains(profile.secret) {
                throw MemoryContextError.secretInContext
            }
            return text
        }

        private static func isSupportedSearchSchema(_ schema: [String: Any]?) -> Bool {
            guard let schema else {
                return false
            }
            if let type = schema["type"], !(type is NSNull), (type as? String) != "object" {
                return false
            }
            guard let properties = schema["properties"] as? [String: Any],
                  let query = properties["query"] as? [String: Any],
                  (query["type"] as? String) == "string" else {
                return false
            }
            if let required = schema["required"], !(required is NSNull) {
                guard let fields = required as? [Any] else {
                    return false
                }
                for field in fields where (field as? String) != "query" {
                    return false
                }
            }
            return true
        }

        private static func isBinary(_ text: String) -> Bool {
            text.unicodeScalars.contains { scalar in
                if scalar == "\n" || scalar == "\r" || scalar == "\t" {
                    return false
                }
                return scalar.value < 32 || scalar.value == 127
            }
        }

        private mutating func allocateID() -> Int {
            defer { nextID += 1 }
            return nextID
        }

        private mutating func perform(url: URL, body: Data) throws -> MemoryHTTPResponse {
            guard Date() < deadline else {
                throw MemoryContextError.timeout
            }
            requestCount += 1
            guard requestCount <= 16 else {
                throw MemoryContextError.connection
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
            } catch let error as MemoryContextError {
                throw error
            } catch let error as MemoryCheckError {
                throw error == .timeout ? MemoryContextError.timeout : .connection
            } catch {
                throw MemoryContextError.connection
            }
            guard Date() <= deadline else {
                throw MemoryContextError.timeout
            }
            totalResponseBytes += response.data.count
            guard totalResponseBytes <= MemoryConnectionChecker.maximumTotalResponseBytes else {
                throw MemoryContextError.connection
            }
            if let encoding = header("content-encoding", in: response.headers),
               encoding.lowercased() != "identity" {
                throw MemoryContextError.connection
            }
            return response
        }

        private func result(
            in response: MemoryHTTPResponse,
            expectedID: Int
        ) throws -> [String: Any] {
            guard (200...299).contains(response.statusCode) else {
                throw MemoryContextError.connection
            }
            let object = try decodeRPCObject(data: response.data, expectedID: expectedID)
            guard object["error"] == nil || object["error"] is NSNull else {
                throw MemoryContextError.connection
            }
            guard let result = object["result"] as? [String: Any] else {
                throw MemoryContextError.connection
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
            throw MemoryContextError.connection
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
                throw MemoryContextError.connection
            }
        }
    }
}
