import Foundation

public enum CodexCatalogError: Error, Equatable, Sendable {
    case invalid(String)
    case versionMismatch
    case versionUnavailable
    case versionTimedOut

    public var message: String {
        switch self {
        case .invalid(let message):
            return message
        case .versionMismatch:
            return "The installed Codex version does not match the saved catalog binding."
        case .versionUnavailable:
            return "Codex did not return a recognized version; no session was started."
        case .versionTimedOut:
            return "The Codex version check timed out; no session was started."
        }
    }
}

public enum CodexCatalogLoader {
    public static func bind(
        path: String,
        requiredVersion: String,
        model: String,
        contextWindow: Int?,
        secret: String
    ) throws -> CodexCatalogBinding {
        var binding = CodexCatalogBinding(
            path: path,
            requiredVersion: requiredVersion,
            sha256: String(repeating: "0", count: 64)
        )
        do {
            try ProfileStore.validateCatalogBinding(binding, secret: secret)
        } catch let error as StateStoreError {
            throw CodexCatalogError.invalid(error.message)
        }
        let raw: Data
        do {
            raw = try ProfileStore.readCatalogData(at: URL(fileURLWithPath: path))
        } catch let error as StateStoreError {
            throw CodexCatalogError.invalid(error.message)
        }
        try validate(raw: raw, model: model, contextWindow: contextWindow, secret: secret)
        binding = CodexCatalogBinding(
            path: path,
            requiredVersion: requiredVersion,
            sha256: SHA256.hexDigest(raw)
        )
        do {
            try ProfileStore.validateCatalogBinding(binding, secret: secret)
        } catch let error as StateStoreError {
            throw CodexCatalogError.invalid(error.message)
        }
        return binding
    }

    public static func loadSnapshot(
        binding: CodexCatalogBinding,
        model: String,
        contextWindow: Int?,
        secret: String
    ) throws -> Data {
        if binding.path.contains(secret) || binding.requiredVersion.contains(secret)
            || binding.sha256.contains(secret) {
            throw CodexCatalogError.invalid("Keep gateway credentials out of Codex catalog metadata.")
        }
        let raw: Data
        do {
            raw = try ProfileStore.readCatalogData(at: URL(fileURLWithPath: binding.path))
        } catch let error as StateStoreError {
            throw CodexCatalogError.invalid(error.message)
        }
        guard SHA256.hexDigest(raw) == binding.sha256 else {
            throw CodexCatalogError.invalid(
                "The Codex catalog changed. Review it and explicitly update the saved binding."
            )
        }
        try validate(raw: raw, model: model, contextWindow: contextWindow, secret: secret)
        return raw
    }

    public static func checkVersion(
        executable: URL,
        requiredVersion: String,
        environment: [String: String],
        secrets: [String]
    ) throws {
        let sanitized = environment.filter { key, value in
            key != "JE_GATEWAY_API_KEY" && key != "JE_STUDIO_API_KEY"
                && !secrets.contains(where: { value.contains($0) })
        }
        let process = Process()
        let stdout = Pipe()
        process.executableURL = executable
        process.arguments = ["--version"]
        process.environment = sanitized
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        let timeoutState = VersionTimeoutState()
        let timeout = DispatchWorkItem {
            if process.isRunning {
                timeoutState.markTimedOut()
                process.terminate()
            }
        }
        do {
            try process.run()
        } catch {
            throw CodexCatalogError.versionUnavailable
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: timeout)
        let data: Data
        do {
            data = try stdout.fileHandleForReading.read(upToCount: 4097) ?? Data()
        } catch {
            timeout.cancel()
            if process.isRunning { process.terminate() }
            throw CodexCatalogError.versionUnavailable
        }
        process.waitUntilExit()
        timeout.cancel()
        if timeoutState.timedOut {
            throw CodexCatalogError.versionTimedOut
        }
        guard process.terminationStatus == 0, data.count <= 4096,
              let output = String(data: data, encoding: .utf8),
              let version = recognizedVersion(in: output) else {
            throw CodexCatalogError.versionUnavailable
        }
        guard version == requiredVersion else {
            throw CodexCatalogError.versionMismatch
        }
    }

    // The oracle recognizes one line, "codex-cli X.Y.Z" with optional
    // dot-separated prerelease and build identifiers, and compares the
    // whole version string. Anything else is an unrecognized version.
    static func recognizedVersion(in output: String) -> String? {
        var line = output
        while line.hasSuffix("\n") || line.hasSuffix("\r") {
            line.removeLast()
        }
        guard line.hasPrefix("codex-cli ") else { return nil }
        let version = String(line.dropFirst("codex-cli ".count))
        let buildParts = version.split(separator: "+", omittingEmptySubsequences: false)
        guard buildParts.count == 1 || buildParts.count == 2,
              buildParts.allSatisfy({ !$0.isEmpty }) else { return nil }
        if buildParts.count == 2 {
            guard isIdentifierList(String(buildParts[1])) else { return nil }
        }
        let coreAndPrerelease = buildParts[0].split(
            separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        if coreAndPrerelease.count == 2 {
            guard isIdentifierList(String(coreAndPrerelease[1])) else { return nil }
        }
        let core = coreAndPrerelease[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              core.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) })
        else { return nil }
        return version
    }

    private static func isIdentifierList(_ value: String) -> Bool {
        let identifiers = value.split(separator: ".", omittingEmptySubsequences: false)
        return !identifiers.isEmpty && identifiers.allSatisfy { identifier in
            !identifier.isEmpty && identifier.allSatisfy { character in
                character.isASCII
                    && (character.isLetter || character.isNumber || character == "-")
            }
        }
    }

    private static func validate(
        raw: Data,
        model: String,
        contextWindow: Int?,
        secret: String
    ) throws {
        guard let text = String(data: raw, encoding: .utf8) else {
            throw CodexCatalogError.invalid("The Codex catalog must contain valid UTF-8 JSON.")
        }
        guard !text.contains(secret) else {
            throw CodexCatalogError.invalid("Keep gateway credentials out of Codex catalog contents.")
        }
        guard !hasDuplicateObjectKeys(text) else {
            throw CodexCatalogError.invalid("The Codex catalog contains duplicate JSON fields.")
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: raw, options: [])
        } catch {
            throw CodexCatalogError.invalid("The Codex catalog must contain valid, unambiguous JSON.")
        }
        guard containsOnlySafeStrings(parsed, secret: secret) else {
            throw CodexCatalogError.invalid("Keep gateway credentials out of Codex catalog contents.")
        }
        guard let root = parsed as? [String: Any],
              let models = root["models"] as? [Any], !models.isEmpty else {
            throw CodexCatalogError.invalid("The Codex catalog must contain a nonempty models list.")
        }
        var seen: Set<String> = []
        var selected: [String: Any]?
        for item in models {
            guard let object = item as? [String: Any],
                  let slug = object["slug"] as? String,
                  !slug.isEmpty,
                  slug.trimmingCharacters(in: .whitespacesAndNewlines) == slug,
                  !slug.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                  seen.insert(slug).inserted else {
                throw CodexCatalogError.invalid("The Codex catalog must contain unique, nonempty model slugs.")
            }
            if slug == model {
                selected = object
            }
        }
        guard let selected else {
            throw CodexCatalogError.invalid("The selected model is missing from the Codex catalog.")
        }
        let catalogContext = try optionalPositiveInt(selected["context_window"])
        let maximum = try optionalPositiveInt(selected["max_context_window"])
        if let contextWindow, catalogContext != contextWindow {
            throw CodexCatalogError.invalid("The saved context window conflicts with the Codex catalog.")
        }
        if let catalogContext, let maximum, catalogContext > maximum {
            throw CodexCatalogError.invalid("The saved context window conflicts with the Codex catalog.")
        }
    }

    private static func optionalPositiveInt(_ raw: Any?) throws -> Int? {
        if raw == nil || raw is NSNull {
            return nil
        }
        guard let number = raw as? NSNumber else {
            throw CodexCatalogError.invalid("Codex catalog context limits must be positive integers.")
        }
        let type = String(cString: number.objCType)
        let double = number.doubleValue
        guard type != "c" && type != "B", double.rounded() == double,
              double > 0, double <= Double(Int.max) else {
            throw CodexCatalogError.invalid("Codex catalog context limits must be positive integers.")
        }
        return number.intValue
    }

    private static func containsOnlySafeStrings(_ value: Any, secret: String) -> Bool {
        var pending: [Any] = [value]
        while let item = pending.popLast() {
            if let string = item as? String {
                if string.contains(secret) {
                    return false
                }
            } else if let dictionary = item as? [String: Any] {
                pending.append(contentsOf: dictionary.keys.map { $0 as Any })
                pending.append(contentsOf: dictionary.values)
            } else if let array = item as? [Any] {
                pending.append(contentsOf: array)
            }
        }
        return true
    }

    private static func hasDuplicateObjectKeys(_ text: String) -> Bool {
        enum Context {
            case object(keys: Set<String>, expectingKey: Bool)
            case array
        }

        var stack: [Context] = []
        var inString = false
        var escaped = false
        var currentString = ""
        var currentStringIsKey = false

        for character in text {
            if inString {
                currentString.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                    if currentStringIsKey, case .object(var keys, _) = stack.last {
                        let key = decodeJSONString(currentString) ?? currentString
                        if !keys.insert(key).inserted {
                            return true
                        }
                        stack[stack.count - 1] = .object(keys: keys, expectingKey: false)
                    }
                    currentString = ""
                    currentStringIsKey = false
                }
                continue
            }
            switch character {
            case "\"":
                inString = true
                currentString = "\""
                if case .object(_, let expectingKey) = stack.last {
                    currentStringIsKey = expectingKey
                } else {
                    currentStringIsKey = false
                }
            case "{":
                stack.append(.object(keys: [], expectingKey: true))
            case "[":
                stack.append(.array)
            case "}", "]":
                if !stack.isEmpty { stack.removeLast() }
            case ",":
                if case .object(let keys, _) = stack.last {
                    stack[stack.count - 1] = .object(keys: keys, expectingKey: true)
                }
            case ":":
                if case .object(let keys, _) = stack.last {
                    stack[stack.count - 1] = .object(keys: keys, expectingKey: false)
                }
            default:
                break
            }
        }
        return false
    }

    private static func decodeJSONString(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return value as? String
    }
}

private final class VersionTimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func markTimedOut() {
        lock.withLock { flag = true }
    }

    var timedOut: Bool {
        lock.withLock { flag }
    }
}
