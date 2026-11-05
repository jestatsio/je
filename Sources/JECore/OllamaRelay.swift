import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct OllamaRelayUpstreamRequest: Equatable, Sendable {
    public let method: String
    public let url: URL
    public let contentType: String?
    public let body: Data

    public init(method: String, url: URL, contentType: String?, body: Data) {
        self.method = method
        self.url = url
        self.contentType = contentType
        self.body = body
    }
}

public enum OllamaRelayUpstreamError: Error, Equatable, Sendable {
    case transportFailed
}

public enum OllamaRelayError: Error, Equatable, Sendable {
    case startFailed
}

/// Streams one upstream response: `onHead` fires once with the status and
/// content type, then `onChunk` fires per body chunk. Throws
/// `OllamaRelayUpstreamError.transportFailed` when the upstream cannot be
/// reached or the transfer fails.
public protocol OllamaRelayUpstream: Sendable {
    func perform(
        _ request: OllamaRelayUpstreamRequest,
        bearerToken: String,
        onHead: @escaping @Sendable (_ status: Int, _ contentType: String?) -> Void,
        onChunk: @escaping @Sendable (Data) -> Void
    ) throws
}

public struct URLSessionOllamaRelayUpstream: OllamaRelayUpstream {
    public static let userAgent = "je-studio-native-relay/0.1"
    public static let maximumUpstreamBytes = 64 * 1024 * 1024

    public init() {}

    public func perform(
        _ request: OllamaRelayUpstreamRequest,
        bearerToken: String,
        onHead: @escaping @Sendable (_ status: Int, _ contentType: String?) -> Void,
        onChunk: @escaping @Sendable (Data) -> Void
    ) throws {
        let delegate = RelayUpstreamDelegate(
            limit: Self.maximumUpstreamBytes, onHead: onHead, onChunk: onChunk)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 3600
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
            timeoutInterval: 300
        )
        urlRequest.httpMethod = request.method
        if !request.body.isEmpty {
            urlRequest.httpBody = request.body
        }
        urlRequest.setValue("Bearer " + bearerToken, forHTTPHeaderField: "Authorization")
        urlRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let contentType = request.contentType {
            urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        let task = session.dataTask(with: urlRequest)
        delegate.attach(task)
        task.resume()
        if delegate.semaphore.wait(timeout: .now() + 3630) == .timedOut {
            task.cancel()
            throw OllamaRelayUpstreamError.transportFailed
        }
        if delegate.failed {
            throw OllamaRelayUpstreamError.transportFailed
        }
    }
}

private final class RelayUpstreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let limit: Int
    private let onHead: @Sendable (_ status: Int, _ contentType: String?) -> Void
    private let onChunk: @Sendable (Data) -> Void
    private var task: URLSessionDataTask?
    private var receivedBytes = 0
    private var headDelivered = false
    private var failure = false
    private var finished = false

    init(
        limit: Int,
        onHead: @escaping @Sendable (_ status: Int, _ contentType: String?) -> Void,
        onChunk: @escaping @Sendable (Data) -> Void
    ) {
        self.limit = limit
        self.onHead = onHead
        self.onChunk = onChunk
    }

    var failed: Bool { failure }

    func attach(_ task: URLSessionDataTask) {
        self.task = task
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
            var contentType: String?
            for (key, value) in http.allHeaderFields
            where String(describing: key).lowercased() == "content-type" {
                contentType = String(describing: value)
            }
            headDelivered = true
            onHead(http.statusCode, contentType)
        } else {
            failure = true
        }
        completionHandler(headDelivered ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivedBytes += data.count
        if receivedBytes > limit {
            failure = true
            dataTask.cancel()
            return
        }
        onChunk(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if finished { return }
        finished = true
        if error != nil {
            failure = true
        }
        semaphore.signal()
    }
}

/// Loopback-only reverse proxy matching the Python native Ollama relay: a
/// random capability-token path prefix, an exact method+path allowlist, the
/// saved key injected upstream, and sanitized upstream error bodies. The
/// listener lives only between `start()` and `stop()`.
public final class OllamaLoopbackRelay: @unchecked Sendable {
    public static let maximumHeadBytes = 64 * 1024
    public static let maximumBodyBytes = 32 * 1024 * 1024

    private let upstreamBase: String
    private let bearerToken: String
    private let upstream: OllamaRelayUpstream
    private let token: String
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var clientFDs: Set<Int32> = []
    private var stopped = false
    private var startedURL: URL?

    public init(
        upstreamBase: String,
        bearerToken: String,
        upstream: OllamaRelayUpstream,
        token: String? = nil
    ) {
        self.upstreamBase = upstreamBase
        self.bearerToken = bearerToken
        self.upstream = upstream
        self.token = token ?? Self.makeToken()
    }

    public static func makeToken() -> String {
        let bytes = (0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public func start() throws -> URL {
        if let startedURL {
            return startedURL
        }
        let fd = Self.makeListener()
        guard fd >= 0, let port = Self.boundPort(fd) else {
            if fd >= 0 { Self.closeFD(fd) }
            throw OllamaRelayError.startFailed
        }
        lock.lock()
        listenFD = fd
        stopped = false
        lock.unlock()
        let thread = Thread { [weak self] in
            self?.acceptLoop(listenFD: fd)
        }
        thread.name = "je-ollama-relay-accept"
        thread.start()
        let url = URL(string: "http://127.0.0.1:\(port)/\(token)")!
        startedURL = url
        return url
    }

    public func stop() {
        lock.lock()
        stopped = true
        let listener = listenFD
        listenFD = -1
        let clients = clientFDs
        clientFDs.removeAll()
        lock.unlock()
        if listener >= 0 {
            Self.closeFD(listener)
        }
        for client in clients {
            Self.shutdownFD(client)
            Self.closeFD(client)
        }
    }

    private var isStopped: Bool {
        lock.withLock { stopped }
    }

    private func acceptLoop(listenFD fd: Int32) {
        while !isStopped {
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollFD, 1, 200)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 || pollFD.revents & Int16(POLLIN) == 0 {
                continue
            }
            let client = accept(fd, nil, nil)
            if client < 0 {
                continue
            }
            Self.configureClient(client)
            lock.lock()
            if stopped {
                lock.unlock()
                Self.closeFD(client)
                break
            }
            clientFDs.insert(client)
            lock.unlock()
            let thread = Thread { [weak self] in
                self?.handleConnection(client)
            }
            thread.name = "je-ollama-relay-client"
            thread.start()
        }
    }

    private func releaseClient(_ fd: Int32) {
        lock.lock()
        clientFDs.remove(fd)
        lock.unlock()
        Self.closeFD(fd)
    }

    private static var streamSocketType: Int32 {
        #if canImport(Glibc)
        return Int32(SOCK_STREAM.rawValue)
        #else
        return SOCK_STREAM
        #endif
    }

    private static var sendFlags: Int32 {
        #if canImport(Glibc)
        return Int32(MSG_NOSIGNAL)
        #else
        return 0
        #endif
    }

    private static func makeListener() -> Int32 {
        let fd = socket(AF_INET, streamSocketType, 0)
        guard fd >= 0 else { return -1 }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            closeFD(fd)
            return -1
        }
        return fd
    }

    private static func boundPort(_ fd: Int32) -> UInt16? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard result == 0 else { return nil }
        return UInt16(bigEndian: address.sin_port)
    }

    private static func configureClient(_ fd: Int32) {
        var timeout = timeval(tv_sec: 120, tv_usec: 0)
        setsockopt(
            fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
            socklen_t(MemoryLayout<timeval>.size))
        #if canImport(Darwin)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    private static func closeFD(_ fd: Int32) {
        #if canImport(Glibc)
        Glibc.close(fd)
        #else
        Darwin.close(fd)
        #endif
    }

    private static func shutdownFD(_ fd: Int32) {
        #if canImport(Glibc)
        Glibc.shutdown(fd, Int32(SHUT_RDWR.rawValue))
        #else
        Darwin.shutdown(fd, SHUT_RDWR)
        #endif
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        if data.isEmpty { return true }
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var sent = 0
            while sent < raw.count {
                let result = send(
                    fd, base.advanced(by: sent), raw.count - sent, sendFlags)
                if result < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if result == 0 { return false }
                sent += result
            }
            return true
        }
    }

    private static func fill(_ fd: Int32, _ buffer: inout Data) -> Bool {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let result = chunk.withUnsafeMutableBufferPointer { pointer in
                recv(fd, pointer.baseAddress, pointer.count, 0)
            }
            if result < 0 {
                if errno == EINTR { continue }
                return false
            }
            if result == 0 { return false }
            buffer.append(contentsOf: chunk[..<result])
            return true
        }
    }

    private struct ClientRequest {
        let method: String
        let target: String
        let version: String
        let headers: [String: String]
        let body: Data
    }

    private static let notPermittedBody =
        "{\"error\":\"This local relay request is not permitted.\"}\n"
    private static let modelUnavailableBody =
        "{\"error\":\"This model is not available through the shared connection.\"}\n"
    private static let rejectedBody =
        "{\"error\":\"The shared service rejected this request.\"}\n"
    private static let returnedErrorBody =
        "{\"error\":\"The shared Ollama service returned an error.\"}\n"
    private static let couldNotCompleteBody =
        "{\"error\":\"The shared Ollama service could not complete the request.\"}\n"

    private static let allowedRoutes: Set<String> = [
        "HEAD|", "HEAD|/",
        "GET|/api/tags", "GET|/api/version", "GET|/api/ps",
        "POST|/api/chat", "POST|/api/generate", "POST|/api/show"
    ]

    private func handleConnection(_ fd: Int32) {
        var buffer = Data()
        defer { releaseClient(fd) }
        while !isStopped {
            guard let request = readRequest(fd, &buffer) else {
                break
            }
            let keepAlive = Self.shouldKeepAlive(request)
            let closeAfter = handleOne(fd: fd, request: request, keepAlive: keepAlive)
            if closeAfter || !keepAlive {
                break
            }
        }
    }

    private static func shouldKeepAlive(_ request: ClientRequest) -> Bool {
        let connection = (request.headers["connection"] ?? "")
            .lowercased()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if connection.contains("close") {
            return false
        }
        if request.version == "HTTP/1.0" {
            return connection.contains("keep-alive")
        }
        return true
    }

    private func routedPath(target: String, method: String) -> String? {
        let prefix = "/" + token
        let rest: String
        if target == prefix {
            rest = ""
        } else if target.hasPrefix(prefix + "/") {
            rest = String(target.dropFirst(prefix.count))
        } else {
            return nil
        }
        guard !rest.contains("?"),
              Self.allowedRoutes.contains(method + "|" + rest) else {
            return nil
        }
        return rest
    }

    private static func mappedError(
        method: String, rest: String, upstreamStatus: Int
    ) -> (status: Int, body: String) {
        if method == "POST" && rest == "/api/show" && upstreamStatus == 404 {
            return (403, modelUnavailableBody)
        }
        if upstreamStatus == 401 || upstreamStatus == 403 {
            return (upstreamStatus, rejectedBody)
        }
        return (upstreamStatus, returnedErrorBody)
    }

    private final class ForwardState: @unchecked Sendable {
        private let lock = NSLock()
        private var status: Int?
        private var headWritten = false
        private var failed = false

        func recordHead(_ value: Int, written: Bool) {
            lock.withLock {
                status = value
                headWritten = written
                if !written && (200...299).contains(value) {
                    failed = true
                }
            }
        }

        func recordWriteFailure() {
            lock.withLock { failed = true }
        }

        var snapshot: (status: Int?, headWritten: Bool, failed: Bool) {
            lock.withLock { (status, headWritten, failed) }
        }
    }

    private func handleOne(fd: Int32, request: ClientRequest, keepAlive: Bool) -> Bool {
        let isHead = request.method == "HEAD"
        guard let rest = routedPath(target: request.target, method: request.method) else {
            return !writeLocalError(
                fd: fd, status: 403, body: Self.notPermittedBody,
                isHead: isHead, keepAlive: keepAlive)
        }
        let upstreamPath = rest.isEmpty ? "/" : rest
        guard let url = URL(string: upstreamBase + upstreamPath) else {
            return !writeLocalError(
                fd: fd, status: 502, body: Self.couldNotCompleteBody,
                isHead: isHead, keepAlive: keepAlive)
        }
        let state = ForwardState()
        let writeLock = NSLock()
        func lockedWrite(_ data: Data) -> Bool {
            writeLock.lock()
            defer { writeLock.unlock() }
            return Self.writeAll(fd, data)
        }
        do {
            try upstream.perform(
                OllamaRelayUpstreamRequest(
                    method: request.method,
                    url: url,
                    contentType: request.headers["content-type"],
                    body: request.body),
                bearerToken: bearerToken,
                onHead: { status, contentType in
                    var written = false
                    if (200...299).contains(status) {
                        written = lockedWrite(Data(Self.responseHead(
                            status: status,
                            contentType: isHead ? "application/json" : contentType,
                            chunked: !isHead,
                            keepAlive: keepAlive).utf8))
                    }
                    state.recordHead(status, written: written)
                },
                onChunk: { chunk in
                    let snapshot = state.snapshot
                    guard snapshot.headWritten, !isHead, !chunk.isEmpty else { return }
                    var framed = Data("\(String(chunk.count, radix: 16))\r\n".utf8)
                    framed.append(chunk)
                    framed.append(Data("\r\n".utf8))
                    if !lockedWrite(framed) {
                        state.recordWriteFailure()
                    }
                })
        } catch {
            let snapshot = state.snapshot
            if snapshot.headWritten {
                return true
            }
            if let status = snapshot.status {
                let mapped = Self.mappedError(
                    method: request.method, rest: rest, upstreamStatus: status)
                return !writeLocalError(
                    fd: fd, status: mapped.status, body: mapped.body,
                    isHead: isHead, keepAlive: keepAlive)
            }
            return !writeLocalError(
                fd: fd, status: 502, body: Self.couldNotCompleteBody,
                isHead: isHead, keepAlive: keepAlive)
        }
        let snapshot = state.snapshot
        if snapshot.headWritten {
            if !isHead {
                return !lockedWrite(Data("0\r\n\r\n".utf8)) || snapshot.failed
            }
            return snapshot.failed
        }
        guard let status = snapshot.status else {
            return !writeLocalError(
                fd: fd, status: 502, body: Self.couldNotCompleteBody,
                isHead: isHead, keepAlive: keepAlive)
        }
        let mapped = Self.mappedError(
            method: request.method, rest: rest, upstreamStatus: status)
        return !writeLocalError(
            fd: fd, status: mapped.status, body: mapped.body,
            isHead: isHead, keepAlive: keepAlive)
    }

    private static func responseHead(
        status: Int, contentType: String?, chunked: Bool, keepAlive: Bool
    ) -> String {
        var head = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\n"
        if let contentType {
            let cleaned = contentType.filter { $0 != "\r" && $0 != "\n" }
            if !cleaned.isEmpty {
                head += "Content-Type: \(cleaned)\r\n"
            }
        }
        head += chunked ? "Transfer-Encoding: chunked\r\n" : "Content-Length: 0\r\n"
        if !keepAlive {
            head += "Connection: close\r\n"
        }
        head += "\r\n"
        return head
    }

    private func writeLocalError(
        fd: Int32, status: Int, body: String, isHead: Bool, keepAlive: Bool
    ) -> Bool {
        let bytes = Data(body.utf8)
        var head = "HTTP/1.1 \(status) \(Self.reasonPhrase(status))\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(bytes.count)\r\n"
        if !keepAlive {
            head += "Connection: close\r\n"
        }
        head += "\r\n"
        guard Self.writeAll(fd, Data(head.utf8)) else { return false }
        if isHead {
            return true
        }
        return Self.writeAll(fd, bytes)
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }

    private func readRequest(_ fd: Int32, _ buffer: inout Data) -> ClientRequest? {
        let marker = Data("\r\n\r\n".utf8)
        var headRange: Range<Data.Index>?
        while headRange == nil {
            if let range = buffer.range(of: marker) {
                headRange = range
                break
            }
            if buffer.count > Self.maximumHeadBytes {
                return nil
            }
            if !Self.fill(fd, &buffer) {
                return nil
            }
        }
        guard let range = headRange else { return nil }
        let headData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
        guard let head = String(data: headData, encoding: .utf8) else {
            return nil
        }
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(
            separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              !parts[0].isEmpty, !parts[1].isEmpty,
              parts[2].hasPrefix("HTTP/1.") else {
            return nil
        }
        var headers: [String: String] = [:]
        var contentLengths: Set<String> = []
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon]
                .trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            if name == "content-length" {
                contentLengths.insert(value)
            }
            if headers[name] == nil {
                headers[name] = value
            }
        }
        guard contentLengths.count <= 1 else { return nil }
        if (headers["expect"] ?? "").lowercased().contains("100-continue") {
            guard Self.writeAll(fd, Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)) else {
                return nil
            }
        }
        let body: Data
        if (headers["transfer-encoding"] ?? "").lowercased().contains("chunked") {
            guard let decoded = readChunkedBody(fd, &buffer) else { return nil }
            body = decoded
        } else if let lengthText = headers["content-length"] {
            guard let length = Int(lengthText),
                  length >= 0, length <= Self.maximumBodyBytes,
                  let exact = readExact(fd, &buffer, count: length) else {
                return nil
            }
            body = exact
        } else {
            body = Data()
        }
        return ClientRequest(
            method: String(parts[0]),
            target: String(parts[1]),
            version: String(parts[2]),
            headers: headers,
            body: body)
    }

    private func readExact(_ fd: Int32, _ buffer: inout Data, count: Int) -> Data? {
        while buffer.count < count {
            if !Self.fill(fd, &buffer) {
                return nil
            }
        }
        let data = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(data)
    }

    private func readLine(_ fd: Int32, _ buffer: inout Data) -> String? {
        let marker = Data("\r\n".utf8)
        while true {
            if let range = buffer.range(of: marker) {
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return String(data: lineData, encoding: .utf8)
            }
            if buffer.count > 8192 {
                return nil
            }
            if !Self.fill(fd, &buffer) {
                return nil
            }
        }
    }

    private func readChunkedBody(_ fd: Int32, _ buffer: inout Data) -> Data? {
        var body = Data()
        while true {
            guard let sizeLine = readLine(fd, &buffer) else { return nil }
            let sizeText = sizeLine.split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16),
                  size >= 0 else {
                return nil
            }
            if size == 0 {
                while let trailer = readLine(fd, &buffer), !trailer.isEmpty {}
                return body
            }
            guard body.count + size <= Self.maximumBodyBytes,
                  let chunk = readExact(fd, &buffer, count: size),
                  let crlf = readExact(fd, &buffer, count: 2),
                  crlf == Data("\r\n".utf8) else {
                return nil
            }
            body.append(chunk)
        }
    }
}
