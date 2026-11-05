import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct OllamaCheckReport: Codable, Equatable, Sendable {
    public let passed: Bool
    public let authenticated: Bool
    public let model: String
    public let modelAvailable: Bool

    enum CodingKeys: String, CodingKey {
        case passed
        case authenticated
        case model
        case modelAvailable = "model_available"
    }
}

public struct OllamaHTTPResponse: Equatable, Sendable {
    public let statusCode: Int
    public let data: Data

    public init(statusCode: Int, data: Data) {
        self.statusCode = statusCode
        self.data = data
    }
}

public enum OllamaCheckError: Error, Equatable, Sendable {
    case httpStatus(Int)
    case deadline
    case sizeLimit
    case invalidListing
    case unreachable

    public var message: String {
        switch self {
        case .httpStatus(let status):
            return "Native Ollama connection failed with HTTP \(status)."
        case .deadline:
            return "The native Ollama model listing took too long."
        case .sizeLimit:
            return "The native Ollama model listing exceeded the supported size."
        case .invalidListing:
            return "The native Ollama service did not return a valid model listing."
        case .unreachable:
            return "The native Ollama service could not be reached or returned an invalid response."
        }
    }
}

public protocol OllamaHTTPTransport: Sendable {
    func get(url: URL, bearerToken: String) throws -> OllamaHTTPResponse
}

public typealias BoundedHTTPResponse = OllamaHTTPResponse
public typealias BoundedHTTPTransport = OllamaHTTPTransport

public enum OllamaConnectionChecker {
    public static let maximumResponseBytes = 1_048_576

    public static func check(
        profile: ResolvedOllamaProfile,
        transport: OllamaHTTPTransport
    ) throws -> OllamaCheckReport {
        guard let url = URL(string: profile.endpoint + "/api/tags") else {
            throw OllamaCheckError.unreachable
        }
        let response: OllamaHTTPResponse
        do {
            response = try transport.get(url: url, bearerToken: profile.secret)
        } catch let error as OllamaCheckError {
            throw error
        } catch {
            throw OllamaCheckError.unreachable
        }
        guard (200...299).contains(response.statusCode) else {
            throw OllamaCheckError.httpStatus(response.statusCode)
        }
        guard response.data.count <= maximumResponseBytes else {
            throw OllamaCheckError.sizeLimit
        }
        let names = try modelNames(in: response.data)
        let available = names.contains(taggedName(profile.model))
        return OllamaCheckReport(
            passed: available,
            authenticated: true,
            model: profile.model,
            modelAvailable: available
        )
    }

    private static func modelNames(in data: Data) throws -> Set<String> {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw OllamaCheckError.invalidListing
        }
        guard let root = parsed as? [String: Any],
              let models = root["models"] as? [Any] else {
            throw OllamaCheckError.invalidListing
        }
        var names: Set<String> = []
        for item in models {
            guard let object = item as? [String: Any] else {
                throw OllamaCheckError.invalidListing
            }
            let model = try optionalString(object["model"])
            let name = try optionalString(object["name"])
            let selected: String?
            if let model, !model.isEmpty {
                selected = model
            } else {
                selected = name
            }
            guard let selected, isValidModel(selected) else {
                throw OllamaCheckError.invalidListing
            }
            if let model, !model.isEmpty, let name, !name.isEmpty,
               taggedName(model) != taggedName(name) {
                throw OllamaCheckError.invalidListing
            }
            names.insert(taggedName(selected))
        }
        return names
    }

    private static func optionalString(_ raw: Any?) throws -> String? {
        if raw == nil || raw is NSNull {
            return nil
        }
        guard let value = raw as? String else {
            throw OllamaCheckError.invalidListing
        }
        return value
    }

    private static func taggedName(_ name: String) -> String {
        let lastComponent = name.split(separator: "/").last.map(String.init) ?? name
        return lastComponent.contains(":") || name.contains("@") ? name : name + ":latest"
    }

    private static func isValidModel(_ value: String) -> Bool {
        let characters = Array(value)
        guard (1...256).contains(characters.count), let first = characters.first,
              first.isASCII, first.isLetter || first.isNumber else {
            return false
        }
        return characters.allSatisfy { character in
            character.isASCII
                && (character.isLetter || character.isNumber || "._:/@+-".contains(character))
        }
    }
}

public struct URLSessionOllamaHTTPTransport: OllamaHTTPTransport {
    public init() {}

    public func get(url: URL, bearerToken: String) throws -> OllamaHTTPResponse {
        let delegate = BoundedDataDelegate(limit: OllamaConnectionChecker.maximumResponseBytes)
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

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 10
        )
        request.httpMethod = "GET"
        request.setValue("Bearer " + bearerToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let task = session.dataTask(with: request)
        delegate.attach(task)
        task.resume()
        if delegate.semaphore.wait(timeout: .now() + 12) == .timedOut {
            task.cancel()
            throw OllamaCheckError.deadline
        }
        if delegate.exceededLimit {
            throw OllamaCheckError.sizeLimit
        }
        if let error = delegate.error {
            if (error as? URLError)?.code == .timedOut {
                throw OllamaCheckError.deadline
            }
            throw OllamaCheckError.unreachable
        }
        guard let statusCode = delegate.statusCode else {
            throw OllamaCheckError.unreachable
        }
        return OllamaHTTPResponse(statusCode: statusCode, data: delegate.data)
    }
}

final class BoundedDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let limit: Int
    private var task: URLSessionDataTask?
    private var received = Data()
    private var status: Int?
    private var failure: Error?
    private var exceeded = false
    private var finished = false

    init(limit: Int) {
        self.limit = limit
    }

    var data: Data {
        lock.withLock { received }
    }

    var statusCode: Int? {
        lock.withLock { status }
    }

    var error: Error? {
        lock.withLock { failure }
    }

    var exceededLimit: Bool {
        lock.withLock { exceeded }
    }

    func attach(_ task: URLSessionDataTask) {
        lock.withLock { self.task = task }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse {
            lock.withLock { status = http.statusCode }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let shouldCancel = lock.withLock { () -> Bool in
            if received.count + data.count > limit {
                exceeded = true
                return true
            }
            received.append(data)
            return false
        }
        if shouldCancel {
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let shouldSignal = lock.withLock { () -> Bool in
            if finished { return false }
            finished = true
            failure = error
            return true
        }
        if shouldSignal {
            semaphore.signal()
        }
    }
}
