import Foundation

/// Evaluation-only Apple Foundation Models triage (Q11). Nothing in this
/// file has routing authority, saves memory, or changes a route. Routing
/// suggestions stay inert under Q7, and memory proposals stay under Q18.
/// When the system model is unavailable the fallback is deterministic:
/// template titling and absent proposals, never a silent model switch.

public struct FoundationAvailability: Codable, Equatable, Sendable {
    public let available: Bool
    public let reason: String?

    public init(available: Bool, reason: String?) {
        self.available = available
        self.reason = reason
    }

    public var label: String {
        if available {
            return "available"
        }
        return "unavailable:" + (reason ?? "unknown")
    }
}

public enum FoundationHelperError: Error, Equatable, Sendable {
    case invalidText
    case unavailable
    case operationFailed
    case invalidResponse

    public var message: String {
        switch self {
        case .invalidText:
            return "The triage input text is invalid."
        case .unavailable:
            return "The foundation helper is unavailable."
        case .operationFailed:
            return "The foundation helper operation failed."
        case .invalidResponse:
            return "The foundation helper returned an invalid response."
        }
    }
}

public protocol FoundationHelping: Sendable {
    func availability() throws -> FoundationAvailability
    func title(for text: String) throws -> String
}

public struct FoundationHelperRequest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let operation: String
    public let text: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case operation
        case text
    }

    public init(operation: String, text: String? = nil) {
        schemaVersion = 1
        self.operation = operation
        self.text = text
    }
}

public struct FoundationHelperResponse: Codable, Equatable, Sendable {
    public let ok: Bool
    public let available: Bool?
    public let reason: String?
    public let title: String?

    public init(ok: Bool, available: Bool? = nil, reason: String? = nil, title: String? = nil) {
        self.ok = ok
        self.available = available
        self.reason = reason
        self.title = title
    }
}

public struct TriageProviderIdentity: Codable, Equatable, Sendable {
    public let provider: String
    public let helperVersion: String
    public let operatingSystem: String
    public let availability: String

    enum CodingKeys: String, CodingKey {
        case provider
        case helperVersion = "helper_version"
        case operatingSystem = "operating_system"
        case availability
    }

    public init(availability: FoundationAvailability) {
        provider = "apple-foundation-models"
        helperVersion = JEVersion.current
        operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
        self.availability = availability.label
    }
}

public enum TemplateTitler {
    public static let fallback = "Untitled session"
    public static let maximumWords = 8

    public static func title(for text: String) -> String {
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let words = firstLine.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return fallback }
        return words.prefix(maximumWords).joined(separator: " ")
    }
}

public struct TitlingCaseResult: Codable, Equatable, Sendable {
    public let id: String
    public let passed: Bool
    public let title: String?
    public let detail: String
}

public struct TitlingEvaluationReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let task: String
    public let identity: TriageProviderIdentity
    public let available: Bool
    public let passed: Bool
    public let passedCount: Int
    public let cases: [TitlingCaseResult]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case task
        case identity
        case available
        case passed
        case passedCount = "passed_count"
        case cases
    }
}

public enum TitlingEvaluationRunner {
    public static let maximumTitleWords = 8
    public static let maximumTitleCharacters = 200
    public static let maximumInputCharacters = 2000

    public struct Case: Equatable, Sendable {
        public let id: String
        public let input: String
        public let requiredKeyword: String
    }

    /// Predeclared synthetic titling set. A case passes when the helper
    /// returns a single non-empty title of at most eight words that
    /// contains the required keyword, case-insensitively. The set passes
    /// only when every case passes. This qualifies titling only.
    public static let cases: [Case] = [
        Case(
            id: "titling-checkout-tests",
            input: "Fix the failing login tests in the checkout service",
            requiredKeyword: "login"
        ),
        Case(
            id: "titling-churn-report",
            input: "Summarize the quarterly churn report for the board",
            requiredKeyword: "churn"
        ),
        Case(
            id: "titling-parser-rename",
            input: "Rename the parser module and update every import",
            requiredKeyword: "parser"
        )
    ]

    public static func run(helper: FoundationHelping) -> TitlingEvaluationReport {
        let availability: FoundationAvailability
        do {
            availability = try helper.availability()
        } catch {
            availability = FoundationAvailability(available: false, reason: "helper-error")
        }
        let identity = TriageProviderIdentity(availability: availability)
        guard availability.available else {
            return TitlingEvaluationReport(
                schemaVersion: 1,
                task: "titling",
                identity: identity,
                available: false,
                passed: false,
                passedCount: 0,
                cases: cases.map {
                    TitlingCaseResult(
                        id: $0.id, passed: false, title: nil, detail: "helper unavailable"
                    )
                }
            )
        }
        var results: [TitlingCaseResult] = []
        for testCase in cases {
            do {
                let raw = try helper.title(for: testCase.input)
                let title = sanitize(raw)
                let words = title.split(whereSeparator: \.isWhitespace)
                if title.isEmpty {
                    results.append(TitlingCaseResult(
                        id: testCase.id, passed: false, title: nil, detail: "empty title"
                    ))
                } else if words.count > maximumTitleWords {
                    results.append(TitlingCaseResult(
                        id: testCase.id, passed: false, title: title, detail: "title too long"
                    ))
                } else if !title.lowercased().contains(testCase.requiredKeyword) {
                    results.append(TitlingCaseResult(
                        id: testCase.id, passed: false, title: title, detail: "keyword missing"
                    ))
                } else {
                    results.append(TitlingCaseResult(
                        id: testCase.id, passed: true, title: title, detail: "passed"
                    ))
                }
            } catch {
                results.append(TitlingCaseResult(
                    id: testCase.id, passed: false, title: nil, detail: "helper failed"
                ))
            }
        }
        let passedCount = results.filter(\.passed).count
        return TitlingEvaluationReport(
            schemaVersion: 1,
            task: "titling",
            identity: identity,
            available: true,
            passed: passedCount == results.count,
            passedCount: passedCount,
            cases: results
        )
    }

    /// Title with deterministic fallback. Any helper failure, empty
    /// result, or oversized result falls back to the template title.
    public static func title(helper: FoundationHelping, text: String) -> String {
        guard (try? helper.availability())?.available == true,
              let raw = try? helper.title(for: text) else {
            return TemplateTitler.title(for: text)
        }
        let cleaned = sanitize(raw)
        let words = cleaned.split(whereSeparator: \.isWhitespace)
        guard !cleaned.isEmpty, words.count <= maximumTitleWords else {
            return TemplateTitler.title(for: text)
        }
        return cleaned
    }

    public static func sanitize(_ raw: String) -> String {
        let firstLine = raw.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let collapsed = firstLine
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .joined(separator: " ")
        return String(collapsed.prefix(maximumTitleCharacters))
    }
}

public struct ProcessFoundationHelper: FoundationHelping {
    public let helperURL: URL?

    public init(helperURL: URL?) {
        self.helperURL = helperURL
    }

    public static func `default`(environment: [String: String]) -> ProcessFoundationHelper {
        ProcessFoundationHelper(helperURL: resolveHelperURL(environment: environment))
    }

    public func availability() throws -> FoundationAvailability {
        let response = try call(FoundationHelperRequest(operation: "availability"))
        guard let available = response.available else {
            throw FoundationHelperError.invalidResponse
        }
        return FoundationAvailability(available: available, reason: response.reason)
    }

    public func title(for text: String) throws -> String {
        guard !text.isEmpty,
              text.count <= TitlingEvaluationRunner.maximumInputCharacters,
              !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw FoundationHelperError.invalidText
        }
        let response = try call(FoundationHelperRequest(operation: "title", text: text))
        guard let title = response.title, !title.isEmpty else {
            throw FoundationHelperError.invalidResponse
        }
        return title
    }

    private func call(_ request: FoundationHelperRequest) throws -> FoundationHelperResponse {
        guard let helperURL,
              FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw FoundationHelperError.unavailable
        }
        let stdin = Pipe()
        let stdout = Pipe()
        let process = Process()
        process.executableURL = helperURL
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        let timeout = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        do {
            try process.run()
        } catch {
            throw FoundationHelperError.unavailable
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30, execute: timeout)
        do {
            try stdin.fileHandleForWriting.write(contentsOf: try StableJSON.encodeLine(request))
            try stdin.fileHandleForWriting.close()
            let data = try stdout.fileHandleForReading.read(upToCount: 16 * 1024 + 1) ?? Data()
            process.waitUntilExit()
            timeout.cancel()
            guard process.terminationStatus == 0, data.count <= 16 * 1024 else {
                throw FoundationHelperError.operationFailed
            }
            let response = try JSONDecoder().decode(FoundationHelperResponse.self, from: data)
            guard response.ok else {
                throw FoundationHelperError.operationFailed
            }
            return response
        } catch let error as FoundationHelperError {
            timeout.cancel()
            throw error
        } catch {
            timeout.cancel()
            if process.isRunning {
                process.terminate()
            }
            throw FoundationHelperError.invalidResponse
        }
    }

    private static func resolveHelperURL(environment: [String: String]) -> URL? {
        helperURL(
            explicitPath: environment["JE_FOUNDATION_HELPER"],
            executablePath: ProcessInfo.processInfo.arguments.first,
            pathValue: environment["PATH"]
        )
    }

    static func helperURL(explicitPath: String?, executablePath: String?, pathValue: String?) -> URL? {
        if let explicitPath, !explicitPath.isEmpty {
            return URL(fileURLWithPath: (explicitPath as NSString).expandingTildeInPath)
        }
        if let executablePath, executablePath.contains("/") {
            return URL(fileURLWithPath: executablePath)
                .resolvingSymlinksInPath()
                .deletingLastPathComponent()
                .appendingPathComponent("je-foundation-helper")
        }
        let path = pathValue ?? ""
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent("je-foundation-helper")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
