import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct StateStoreError: Error, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

public struct CodexCatalogBinding: Codable, Equatable, Sendable {
    public let path: String
    public let requiredVersion: String
    public let sha256: String

    enum CodingKeys: String, CodingKey {
        case path
        case requiredVersion = "required_version"
        case sha256
    }
}

public struct PublicConnectionProfile: Codable, Equatable, Sendable {
    public let name: String
    public let endpoint: String
    public let model: String
    public let contextWindow: Int?
    public let codexCatalog: CodexCatalogBinding?

    enum CodingKeys: String, CodingKey {
        case name
        case endpoint
        case model
        case contextWindow = "context_window"
        case codexCatalog = "codex_catalog"
    }
}

public struct PublicMemoryProfile: Codable, Equatable, Sendable {
    public let name: String
    public let endpoint: String
    public let serverName: String

    enum CodingKeys: String, CodingKey {
        case name
        case endpoint
        case serverName = "server_name"
    }
}

public struct PublicOllamaProfile: Codable, Equatable, Sendable {
    public let name: String
    public let endpoint: String
    public let model: String
}

private struct LegacyMemoryProfile {
    let endpoint: String
    let secret: String
    let serverName: String

    func publicProfile(name: String) -> PublicMemoryProfile {
        PublicMemoryProfile(name: name, endpoint: endpoint, serverName: serverName)
    }
}

private struct LegacyOllamaProfile {
    let endpoint: String
    let secret: String
    let model: String

    func publicProfile(name: String) -> PublicOllamaProfile {
        PublicOllamaProfile(name: name, endpoint: endpoint, model: model)
    }
}

private struct LegacyProfile {
    let endpoint: String
    let secret: String
    let model: String
    let contextWindow: Int?
    let codexCatalog: CodexCatalogBinding?

    func publicProfile(name: String) -> PublicConnectionProfile {
        PublicConnectionProfile(
            name: name,
            endpoint: endpoint,
            model: model,
            contextWindow: contextWindow,
            codexCatalog: codexCatalog
        )
    }
}

public struct ProfileStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    public func listProfiles() throws -> [String] {
        try listProfileNames(folderName: "profiles", failure: "Cannot list connection profiles.") { name in
            _ = try loadLegacyProfile(name: name)
        }
    }

    public func loadPublicProfile(name: String) throws -> PublicConnectionProfile {
        try loadLegacyProfile(name: name).publicProfile(name: name)
    }

    public func listMemoryProfiles() throws -> [String] {
        try listProfileNames(folderName: "memory-profiles", failure: "Cannot list memory profiles.") { name in
            _ = try loadLegacyMemoryProfile(name: name)
        }
    }

    public func loadPublicMemoryProfile(name: String) throws -> PublicMemoryProfile {
        try loadLegacyMemoryProfile(name: name).publicProfile(name: name)
    }

    public func listOllamaProfiles() throws -> [String] {
        try listProfileNames(folderName: "ollama-profiles", failure: "Cannot list native Ollama profiles.") { name in
            _ = try loadLegacyOllamaProfile(name: name)
        }
    }

    public func loadPublicOllamaProfile(name: String) throws -> PublicOllamaProfile {
        try loadLegacyOllamaProfile(name: name).publicProfile(name: name)
    }

    private func listProfileNames(
        folderName: String,
        failure: String,
        validate: (String) throws -> Void
    ) throws -> [String] {
        let folder = try folder(named: folderName)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            return []
        }
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )
        } catch {
            throw StateStoreError(failure)
        }
        let names = entries.compactMap { url -> String? in
            guard url.pathExtension == "json" else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            guard ProfileNameValidator.isValid(name) else { return nil }
            guard let info = statInfo(url), isRegularFile(info), !isSymbolicLink(info) else { return nil }
            return name
        }.sorted()
        for name in names {
            try validate(name)
        }
        return names
    }

    private func loadLegacyProfile(name: String) throws -> LegacyProfile {
        guard ProfileNameValidator.isValid(name) else {
            throw StateStoreError("Use a profile name with 1-64 letters, numbers, dots, underscores, or hyphens.")
        }
        let path = try folder(named: "profiles").appendingPathComponent(name + ".json")
        let raw = try readPrivateData(path)
        do {
            let object = try JSONSerialization.jsonObject(with: raw, options: [])
            guard let value = object as? [String: Any] else {
                throw StateStoreError("Unsupported connection profile format.")
            }
            guard let schemaVersion = exactInt(value["schema_version"]), [1, 2].contains(schemaVersion) else {
                throw StateStoreError("Unsupported connection profile format.")
            }
            var binding: CodexCatalogBinding?
            if schemaVersion == 2 {
                binding = try catalogBinding(value["codex_catalog"])
            } else if value["codex_catalog"] != nil {
                throw StateStoreError("Catalog bindings require connection profile format version 2.")
            }
            guard let endpointRaw = value["endpoint"] as? String,
                  let secret = value["api_key"] as? String,
                  let model = value["model"] as? String else {
                throw StateStoreError("The connection profile is invalid; no contents were displayed.")
            }
            let context = try contextWindow(value["context_window"])
            let endpoint = try normalizedEndpoint(endpointRaw)
            try validateSecret(secret)
            try validateModel(model)
            if name.contains(secret) || endpoint.contains(secret) || model.contains(secret) {
                throw StateStoreError("Keep gateway credentials out of public profile fields.")
            }
            if let binding {
                try validateCatalog(binding, secret: secret)
            }
            return LegacyProfile(
                endpoint: endpoint,
                secret: secret,
                model: model,
                contextWindow: context,
                codexCatalog: binding
            )
        } catch let error as StateStoreError {
            throw error
        } catch {
            throw StateStoreError("The connection profile is invalid; no contents were displayed.")
        }
    }

    private func loadLegacyMemoryProfile(name: String) throws -> LegacyMemoryProfile {
        try validateProfileName(name)
        let path = try folder(named: "memory-profiles").appendingPathComponent(name + ".json")
        let raw = try readPrivateData(path)
        do {
            if hasDuplicateTopLevelKeys(raw) {
                throw StateStoreError("The memory profile contains duplicate fields.")
            }
            let object = try JSONSerialization.jsonObject(with: raw, options: [])
            guard let value = object as? [String: Any],
                  Set(value.keys) == ["schema_version", "endpoint", "token", "server_name"],
                  exactInt(value["schema_version"]) == 1,
                  let endpoint = value["endpoint"] as? String,
                  let secret = value["token"] as? String,
                  let serverName = value["server_name"] as? String else {
                throw StateStoreError("Unsupported memory profile format.")
            }
            try validateSecret(secret)
            guard isValidMemoryServerName(serverName) else {
                throw StateStoreError("Use a memory server name of 1-64 ASCII letters, digits, underscores, or hyphens.")
            }
            _ = try normalizedEndpoint(endpoint)
            if name.contains(secret) || endpoint.contains(secret) || serverName.contains(secret) {
                throw StateStoreError("Keep memory credentials out of public profile fields.")
            }
            return LegacyMemoryProfile(endpoint: endpoint, secret: secret, serverName: serverName)
        } catch let error as StateStoreError {
            throw error
        } catch {
            throw StateStoreError("The memory profile is invalid; no contents were displayed.")
        }
    }

    private func loadLegacyOllamaProfile(name: String) throws -> LegacyOllamaProfile {
        try validateProfileName(name)
        let path = try folder(named: "ollama-profiles").appendingPathComponent(name + ".json")
        let raw = try readPrivateData(path)
        do {
            if hasDuplicateTopLevelKeys(raw) {
                throw StateStoreError("The native Ollama profile contains duplicate fields.")
            }
            let object = try JSONSerialization.jsonObject(with: raw, options: [])
            guard let value = object as? [String: Any],
                  Set(value.keys) == ["schema_version", "endpoint", "api_key", "model"],
                  exactInt(value["schema_version"]) == 1,
                  let endpointRaw = value["endpoint"] as? String,
                  let secret = value["api_key"] as? String,
                  let model = value["model"] as? String else {
                throw StateStoreError("Unsupported native Ollama profile format.")
            }
            guard isValidOllamaSecret(secret) else {
                throw StateStoreError("A nonempty ASCII Bearer [REDACTED] is required for the Ollama service.")
            }
            guard isValidOllamaModel(model) else {
                throw StateStoreError("Use a native model name of 1-256 ASCII letters, numbers, or model-name separators.")
            }
            let endpoint = try normalizedOllamaEndpoint(endpointRaw)
            let decodedEndpoint = endpoint.removingPercentEncoding ?? endpoint
            let decodedModel = model.removingPercentEncoding ?? model
            if name.contains(secret) || endpoint.contains(secret) || decodedEndpoint.contains(secret)
                || model.contains(secret) || decodedModel.contains(secret) {
                throw StateStoreError("Keep the Ollama service credential out of public connection fields.")
            }
            return LegacyOllamaProfile(endpoint: endpoint, secret: secret, model: model)
        } catch let error as StateStoreError {
            throw error
        } catch {
            throw StateStoreError("The native Ollama profile is invalid; no contents were displayed.")
        }
    }

    private func folder(named name: String) throws -> URL {
        let rootExists = try checkPrivateDirectory(directory)
        let folder = directory.appendingPathComponent(name, isDirectory: true)
        if rootExists {
            _ = try checkPrivateDirectory(folder)
        }
        return folder
    }

    private func checkPrivateDirectory(_ url: URL) throws -> Bool {
        guard let info = statInfo(url) else {
            if isSymbolicLinkPath(url) {
                throw StateStoreError("State directories must be owned by you, private, and not symlinks.")
            }
            return false
        }
        guard isDirectory(info), !isSymbolicLink(info), permissions(info) & 0o077 == 0, owner(info) == currentUID() else {
            throw StateStoreError("State directories must be owned by you, private, and not symlinks.")
        }
        return true
    }

    private func readPrivateData(_ url: URL, limit: Int = 64 * 1024) throws -> Data {
        guard let info = statInfo(url) else {
            throw StateStoreError("The requested private file does not exist.")
        }
        guard isRegularFile(info), !isSymbolicLink(info), permissions(info) & 0o077 == 0, owner(info) == currentUID() else {
            throw StateStoreError("Credential files must be owned by you, private, and regular files.")
        }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: limit + 1) ?? Data()
            if data.count > limit {
                throw StateStoreError("The private file exceeds the supported size.")
            }
            return data
        } catch let error as StateStoreError {
            throw error
        } catch {
            throw StateStoreError("Cannot read the private file.")
        }
    }

    private func contextWindow(_ raw: Any?) throws -> Int? {
        if raw == nil || raw is NSNull {
            return nil
        }
        guard let value = exactInt(raw), value > 0 else {
            throw StateStoreError("The model context window must be a positive integer.")
        }
        return value
    }

    private func validateProfileName(_ name: String) throws {
        guard ProfileNameValidator.isValid(name) else {
            throw StateStoreError("Use a profile name with 1-64 letters, numbers, dots, underscores, or hyphens.")
        }
    }

    private func isValidMemoryServerName(_ value: String) -> Bool {
        guard (1...64).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value)
                || (65...90).contains(scalar.value)
                || (97...122).contains(scalar.value)
                || scalar == "_" || scalar == "-"
        }
    }

    private func isValidOllamaSecret(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 4096, value.allSatisfy({ $0.isASCII }) else {
            return false
        }
        let base = value.dropLast(value.reversed().prefix { $0 == "=" }.count)
        guard !base.isEmpty else { return false }
        return base.allSatisfy { character in
            character.isLetter || character.isNumber || "._~+/-".contains(character)
        }
    }

    private func isValidOllamaModel(_ value: String) -> Bool {
        let characters = Array(value)
        guard (1...256).contains(characters.count), let first = characters.first, first.isASCII,
              first.isLetter || first.isNumber else {
            return false
        }
        return characters.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || "._:/@+-".contains(character))
        }
    }

    private func normalizedOllamaEndpoint(_ endpoint: String) throws -> String {
        _ = try normalizedEndpoint(endpoint)
        guard endpoint.count <= 4096,
              !endpoint.contains(where: { $0.isWhitespace }),
              !endpoint.contains("\\"),
              var components = URLComponents(string: endpoint),
              let scheme = components.scheme?.lowercased(),
              let host = components.host else {
            throw StateStoreError("Use a complete HTTPS native Ollama root, or literal loopback HTTP, without /v1, credentials, query, or fragment.")
        }
        if scheme == "http" && !isLiteralLoopbackIP(host) {
            throw StateStoreError("Use a complete HTTPS native Ollama root, or literal loopback HTTP, without /v1, credentials, query, or fragment.")
        }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        guard !path.hasSuffix("/v1") else {
            throw StateStoreError("Use a complete HTTPS native Ollama root, or literal loopback HTTP, without /v1, credentials, query, or fragment.")
        }
        components.scheme = scheme
        components.percentEncodedPath = path
        components.query = nil
        components.fragment = nil
        guard let normalized = components.string else {
            throw StateStoreError("Use a complete HTTPS native Ollama root, or literal loopback HTTP, without /v1, credentials, query, or fragment.")
        }
        return normalized
    }

    private func isLiteralLoopbackIP(_ host: String) -> Bool {
        if host == "::1" {
            return true
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "127" else { return false }
        return parts.allSatisfy { part in
            guard let value = Int(part), (0...255).contains(value) else { return false }
            return String(value) == part
        }
    }

    private func catalogBinding(_ raw: Any?) throws -> CodexCatalogBinding {
        guard let value = raw as? [String: Any],
              Set(value.keys) == ["path", "required_version", "sha256"],
              let path = value["path"] as? String,
              let version = value["required_version"] as? String,
              let sha = value["sha256"] as? String else {
            throw StateStoreError("The saved Codex catalog binding is invalid.")
        }
        return CodexCatalogBinding(path: path, requiredVersion: version, sha256: sha)
    }

    private func validateCatalog(_ binding: CodexCatalogBinding, secret: String) throws {
        let path = binding.path
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard path.hasPrefix("/"), !components.contains(".."), !containsControl(path) else {
            throw StateStoreError("Use an absolute Codex catalog path without parent traversal or control characters.")
        }
        guard binding.requiredVersion.count <= 128, isVersion(binding.requiredVersion) else {
            throw StateStoreError("Provide the exact Codex version number, without the codex-cli prefix.")
        }
        guard binding.sha256.count == 64,
              binding.sha256.allSatisfy({ ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") }) else {
            throw StateStoreError("The saved Codex catalog digest is invalid.")
        }
        if path.contains(secret) || binding.requiredVersion.contains(secret) || binding.sha256.contains(secret) {
            throw StateStoreError("Keep gateway credentials out of Codex catalog metadata.")
        }
    }

    private func isVersion(_ value: String) -> Bool {
        let pattern = #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?(?:\+[0-9A-Za-z.-]+)?$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private func validateSecret(_ secret: String) throws {
        guard !secret.isEmpty, !secret.contains(where: { $0.isWhitespace }), !containsControl(secret) else {
            throw StateStoreError("A nonempty gateway credential without whitespace is required.")
        }
    }

    private func validateModel(_ model: String) throws {
        guard !model.isEmpty,
              model.trimmingCharacters(in: .whitespacesAndNewlines) == model,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !containsControl(model) else {
            throw StateStoreError("A nonempty model name without control characters is required.")
        }
    }

    private func containsControl(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }

    private func normalizedEndpoint(_ endpoint: String) throws -> String {
        guard !endpoint.isEmpty,
              endpoint.trimmingCharacters(in: .whitespacesAndNewlines) == endpoint,
              !containsControl(endpoint),
              !endpoint.contains("?"),
              !endpoint.contains("#"),
              var components = URLComponents(string: endpoint),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil else {
            throw StateStoreError("Use an HTTPS gateway URL, or loopback HTTP, without query or fragment.")
        }
        if let port = components.port, !(1...65535).contains(port) {
            throw StateStoreError("Use a valid HTTP(S) gateway URL without embedded credentials.")
        }
        if scheme == "http" && !isLoopback(host) {
            throw StateStoreError("Remote gateway connections require HTTPS.")
        }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/v1") {
            path.removeLast(3)
            while path.hasSuffix("/") { path.removeLast() }
        }
        components.scheme = scheme
        components.percentEncodedPath = path
        components.query = nil
        components.fragment = nil
        guard let normalized = components.string else {
            throw StateStoreError("The gateway URL is not valid.")
        }
        return normalized
    }

    private func isLoopback(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower == "localhost" || lower == "::1" {
            return true
        }
        let parts = lower.split(separator: ".")
        guard parts.count == 4, let first = Int(parts[0]), first == 127 else {
            return false
        }
        return parts.allSatisfy { part in
            guard let value = Int(part), (0...255).contains(value) else { return false }
            return String(value) == part || (part.hasPrefix("0") && value == 0)
        }
    }

    private func exactInt(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber else { return nil }
        let type = String(cString: number.objCType)
        guard type != "c" && type != "B" else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, double >= Double(Int.min), double <= Double(Int.max) else {
            return nil
        }
        return number.intValue
    }

    private func hasDuplicateTopLevelKeys(_ raw: Data) -> Bool {
        guard let text = String(data: raw, encoding: .utf8) else { return false }
        var keys: Set<String> = []
        var depth = 0
        var inString = false
        var escaped = false
        var expectingKey = false
        var currentStringIsKey = false
        var currentString = ""

        for character in text {
            if inString {
                currentString.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                    if currentStringIsKey {
                        let key = decodeJSONString(currentString) ?? currentString
                        if !keys.insert(key).inserted {
                            return true
                        }
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
                currentStringIsKey = expectingKey && depth == 1
            case "{", "[":
                depth += 1
                if character == "{" && depth == 1 {
                    expectingKey = true
                }
            case "}", "]":
                depth = max(0, depth - 1)
                expectingKey = false
            case ",":
                if depth == 1 {
                    expectingKey = true
                }
            case ":":
                if depth == 1 {
                    expectingKey = false
                }
            default:
                break
            }
        }
        return false
    }

    private func decodeJSONString(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return value as? String
    }

    private func statInfo(_ url: URL) -> stat? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info
    }

    private func isSymbolicLinkPath(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func fileType(_ info: stat) -> mode_t {
        info.st_mode & 0o170000
    }

    private func isDirectory(_ info: stat) -> Bool { fileType(info) == 0o040000 }
    private func isRegularFile(_ info: stat) -> Bool { fileType(info) == 0o100000 }
    private func isSymbolicLink(_ info: stat) -> Bool { fileType(info) == 0o120000 }
    private func permissions(_ info: stat) -> mode_t { info.st_mode & 0o7777 }
    private func owner(_ info: stat) -> uid_t { info.st_uid }
    private func currentUID() -> uid_t { getuid() }
}
