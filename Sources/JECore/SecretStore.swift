import Foundation

public enum SecretReferenceValidator {
    public static func isValid(_ reference: String) -> Bool {
        guard (1...128).contains(reference.count),
              !reference.hasPrefix("/"),
              !reference.hasSuffix("/"),
              !reference.contains(".."),
              !reference.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            return false
        }
        return reference.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value)
                || (65...90).contains(scalar.value)
                || (97...122).contains(scalar.value)
                || scalar == "." || scalar == "_" || scalar == "-" || scalar == "/" || scalar == ":"
        }
    }
}

public enum SecretStoreError: Error, Equatable, Sendable {
    case invalidReference
    case invalidSecret
    case unavailable
    case operationFailed
    case invalidResponse

    public var message: String {
        switch self {
        case .invalidReference:
            return "The secret reference is invalid."
        case .invalidSecret:
            return "The secret value is invalid."
        case .unavailable:
            return "The native secret helper is unavailable."
        case .operationFailed:
            return "The native secret operation failed."
        case .invalidResponse:
            return "The native secret helper returned an invalid response."
        }
    }
}

public protocol SecretStoring: Sendable {
    func setSecret(_ secret: String, reference: String) throws
    func secret(reference: String) throws -> String?
    func deleteSecret(reference: String) throws
}

public struct SecretHelperRequest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let operation: String
    public let reference: String
    public let secret: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case operation
        case reference
        case secret
    }

    public init(operation: String, reference: String, secret: String? = nil) {
        schemaVersion = 1
        self.operation = operation
        self.reference = reference
        self.secret = secret
    }
}

public struct SecretHelperResponse: Codable, Equatable, Sendable {
    public let ok: Bool
    public let secret: String?

    public init(ok: Bool, secret: String? = nil) {
        self.ok = ok
        self.secret = secret
    }
}

public struct ProcessSecretStore: SecretStoring {
    public let helperURL: URL?

    public init(helperURL: URL?) {
        self.helperURL = helperURL
    }

    public static func `default`(environment: [String: String]) -> ProcessSecretStore {
        ProcessSecretStore(helperURL: resolveHelperURL(environment: environment))
    }

    public func setSecret(_ secret: String, reference: String) throws {
        guard isValidSecret(secret) else { throw SecretStoreError.invalidSecret }
        _ = try call(SecretHelperRequest(operation: "set", reference: reference, secret: secret))
    }

    public func secret(reference: String) throws -> String? {
        try call(SecretHelperRequest(operation: "get", reference: reference)).secret
    }

    public func deleteSecret(reference: String) throws {
        _ = try call(SecretHelperRequest(operation: "delete", reference: reference))
    }

    private func call(_ request: SecretHelperRequest) throws -> SecretHelperResponse {
        guard SecretReferenceValidator.isValid(request.reference) else {
            throw SecretStoreError.invalidReference
        }
        guard let helperURL,
              FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw SecretStoreError.unavailable
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
            throw SecretStoreError.unavailable
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: timeout)
        do {
            try stdin.fileHandleForWriting.write(contentsOf: try StableJSON.encodeLine(request))
            try stdin.fileHandleForWriting.close()
            let data = try stdout.fileHandleForReading.read(upToCount: 16 * 1024 + 1) ?? Data()
            process.waitUntilExit()
            timeout.cancel()
            guard process.terminationStatus == 0, data.count <= 16 * 1024 else {
                throw SecretStoreError.operationFailed
            }
            let response = try JSONDecoder().decode(SecretHelperResponse.self, from: data)
            guard response.ok else {
                throw SecretStoreError.operationFailed
            }
            return response
        } catch let error as SecretStoreError {
            timeout.cancel()
            throw error
        } catch {
            timeout.cancel()
            if process.isRunning {
                process.terminate()
            }
            throw SecretStoreError.invalidResponse
        }
    }

    private func isValidSecret(_ secret: String) -> Bool {
        !secret.isEmpty
            && secret.count <= 8192
            && !secret.unicodeScalars.contains { $0.value == 0 }
    }

    private static func resolveHelperURL(environment: [String: String]) -> URL? {
        helperURL(
            explicitPath: environment["JE_SECRET_HELPER"],
            executablePath: ProcessInfo.processInfo.arguments.first,
            pathValue: environment["PATH"]
        )
    }

    static func helperURL(explicitPath: String?, executablePath: String?, pathValue: String?) -> URL? {
        if let explicitPath, !explicitPath.isEmpty {
            return URL(fileURLWithPath: (explicitPath as NSString).expandingTildeInPath)
        }
        if let executablePath, executablePath.contains("/") {
            // Resolve symlinks so a Homebrew bin/je symlink finds the helper
            // beside the real binary in libexec.
            return URL(fileURLWithPath: executablePath)
                .resolvingSymlinksInPath()
                .deletingLastPathComponent()
                .appendingPathComponent("je-secret-helper")
        }
        let path = pathValue ?? ""
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent("je-secret-helper")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
