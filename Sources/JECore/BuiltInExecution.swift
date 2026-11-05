import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum BuiltInExecutionError: Error, Equatable, Sendable {
    case unsupportedRoute
    case profileMismatch
    case promptTooLarge
    case secretInContext
    case harnessRunRequired
    case httpStatus(Int)
    case deadline
    case sizeLimit
    case invalidResponse
    case unreachable

    public var message: String {
        switch self {
        case .unsupportedRoute:
            return "This built-in route is not supported by the native single-step executor."
        case .profileMismatch:
            return "The saved native profile does not match the selected built-in assignment."
        case .promptTooLarge:
            return "This prompt exceeds the bounded single-step request size."
        case .secretInContext:
            return "Built-in context may not contain the selected profile credential."
        case .harnessRunRequired:
            return "This request needs a new explicit harness run."
        case .httpStatus(let status):
            return "The built-in model request failed with HTTP \(status)."
        case .deadline:
            return "The built-in model request took too long."
        case .sizeLimit:
            return "The built-in model response exceeded the supported size."
        case .invalidResponse:
            return "The built-in model service did not return a valid single-step answer."
        case .unreachable:
            return "The built-in model service could not be reached or returned an invalid response."
        }
    }

    public var launchStatus: String {
        switch self {
        case .unsupportedRoute:
            return "unsupported_route"
        case .profileMismatch:
            return "profile_mismatch"
        case .promptTooLarge:
            return "prompt_too_large"
        case .secretInContext:
            return "context_secret_rejected"
        case .harnessRunRequired:
            return "harness_run_required"
        case .httpStatus:
            return "http_failed"
        case .deadline:
            return "deadline"
        case .sizeLimit:
            return "size_limit"
        case .invalidResponse:
            return "invalid_response"
        case .unreachable:
            return "unreachable"
        }
    }
}

public protocol BuiltInHTTPTransport: Sendable {
    func postJSON(url: URL, bearerToken: String, body: Data) throws -> OllamaHTTPResponse
}

public enum BuiltInExecutor {
    public static let protocolImplementation = "ollama-native-chat"
    public static let maximumPromptBytes = 32_768
    public static let maximumAnswerBytes = 65_536

    public static func isSupported(_ candidate: RouteCandidate) -> Bool {
        candidate.harness == .builtIn
            && candidate.launchMode == .singleStep
            && candidate.engine == .ollama
            && candidate.executionPlace == .personalMachine
            && candidate.providerKind == .local
            && candidate.protocolImplementation == protocolImplementation
            && !candidate.protocolVersion.isEmpty
            && candidate.protocolVersion == candidate.engineVersion
            && candidate.connectionProfileName != nil
    }

    public static func execute(
        candidate: RouteCandidate,
        profile: ResolvedOllamaProfile,
        prompt: String,
        contextFiles: [BuiltInContextFile] = [],
        transport: BuiltInHTTPTransport
    ) throws -> String {
        guard isSupported(candidate) else {
            throw BuiltInExecutionError.unsupportedRoute
        }
        guard candidate.connectionProfileName == profile.name,
              candidate.modelArtifact == profile.model else {
            throw BuiltInExecutionError.profileMismatch
        }
        guard prompt.utf8.count <= maximumPromptBytes else {
            throw BuiltInExecutionError.promptTooLarge
        }
        guard contextFiles.count <= BuiltInContextLoader.maximumFiles else {
            throw BuiltInExecutionError.promptTooLarge
        }
        for file in contextFiles {
            guard file.text.utf8.count <= BuiltInContextLoader.maximumFileBytes else {
                throw BuiltInExecutionError.promptTooLarge
            }
            if !profile.secret.isEmpty
                && (file.text.contains(profile.secret)
                    || file.relativePath.contains(profile.secret)) {
                throw BuiltInExecutionError.secretInContext
            }
        }
        let assembled = assembledContent(prompt: prompt, contextFiles: contextFiles)
        guard assembled.utf8.count <= maximumPromptBytes + BuiltInContextLoader.maximumTotalBytes else {
            throw BuiltInExecutionError.promptTooLarge
        }
        guard let url = URL(string: profile.endpoint + "/api/chat") else {
            throw BuiltInExecutionError.unreachable
        }
        let body = try requestBody(model: profile.model, content: assembled)
        let response: OllamaHTTPResponse
        do {
            response = try transport.postJSON(url: url, bearerToken: profile.secret, body: body)
        } catch let error as BuiltInExecutionError {
            throw error
        } catch let error as OllamaCheckError {
            throw Self.mapTransportError(error)
        } catch {
            throw BuiltInExecutionError.unreachable
        }
        guard (200...299).contains(response.statusCode) else {
            throw BuiltInExecutionError.httpStatus(response.statusCode)
        }
        guard response.data.count <= OllamaConnectionChecker.maximumResponseBytes else {
            throw BuiltInExecutionError.sizeLimit
        }
        return try answer(in: response.data)
    }

    private static func assembledContent(
        prompt: String,
        contextFiles: [BuiltInContextFile]
    ) -> String {
        guard !contextFiles.isEmpty else {
            return prompt
        }
        var sections = contextFiles.map { file in
            "Context file: \(file.relativePath)\n\(file.text)"
        }
        sections.append("User request:\n\(prompt)")
        return sections.joined(separator: "\n\n")
    }

    private static func requestBody(model: String, content: String) throws -> Data {
        let payload: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [
                [
                    "role": "system",
                    "content": "Answer in one response. Do not request tools, file changes, commands, or more steps."
                ],
                ["role": "user", "content": content]
            ]
        ]
        do {
            return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        } catch {
            throw BuiltInExecutionError.invalidResponse
        }
    }

    private static func answer(in data: Data) throws -> String {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw BuiltInExecutionError.invalidResponse
        }
        guard let root = parsed as? [String: Any],
              let message = root["message"] as? [String: Any] else {
            throw BuiltInExecutionError.invalidResponse
        }
        if let calls = message["tool_calls"] as? [Any], !calls.isEmpty {
            throw BuiltInExecutionError.harnessRunRequired
        }
        if message["tool_calls"] != nil && !(message["tool_calls"] is NSNull)
            && !(message["tool_calls"] is [Any]) {
            throw BuiltInExecutionError.invalidResponse
        }
        if let role = message["role"], !(role is NSNull), (role as? String) != "assistant" {
            throw BuiltInExecutionError.invalidResponse
        }
        if let done = root["done"], !(done is NSNull), (done as? Bool) != true {
            throw BuiltInExecutionError.invalidResponse
        }
        guard let content = message["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BuiltInExecutionError.invalidResponse
        }
        guard content.utf8.count <= maximumAnswerBytes else {
            throw BuiltInExecutionError.sizeLimit
        }
        return content
    }

    private static func mapTransportError(_ error: OllamaCheckError) -> BuiltInExecutionError {
        switch error {
        case .httpStatus(let status):
            return .httpStatus(status)
        case .deadline:
            return .deadline
        case .sizeLimit:
            return .sizeLimit
        case .invalidListing:
            return .invalidResponse
        case .unreachable:
            return .unreachable
        }
    }
}

public struct URLSessionBuiltInHTTPTransport: BuiltInHTTPTransport {
    public init() {}

    public func postJSON(url: URL, bearerToken: String, body: Data) throws -> OllamaHTTPResponse {
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

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 120
        )
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer " + bearerToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let task = session.dataTask(with: request)
        delegate.attach(task)
        task.resume()
        if delegate.semaphore.wait(timeout: .now() + 125) == .timedOut {
            task.cancel()
            throw BuiltInExecutionError.deadline
        }
        if delegate.exceededLimit {
            throw BuiltInExecutionError.sizeLimit
        }
        if let error = delegate.error {
            if (error as? URLError)?.code == .timedOut {
                throw BuiltInExecutionError.deadline
            }
            throw BuiltInExecutionError.unreachable
        }
        guard let statusCode = delegate.statusCode else {
            throw BuiltInExecutionError.unreachable
        }
        return OllamaHTTPResponse(statusCode: statusCode, data: delegate.data)
    }
}
