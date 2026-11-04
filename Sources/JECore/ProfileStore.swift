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
        let folder = try profilesFolder()
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
            throw StateStoreError("Cannot list connection profiles.")
        }
        let names = entries.compactMap { url -> String? in
            guard url.pathExtension == "json" else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            guard ProfileNameValidator.isValid(name) else { return nil }
            guard let info = statInfo(url), isRegularFile(info), !isSymbolicLink(info) else { return nil }
            return name
        }.sorted()
        for name in names {
            _ = try loadLegacyProfile(name: name)
        }
        return names
    }

    public func loadPublicProfile(name: String) throws -> PublicConnectionProfile {
        try loadLegacyProfile(name: name).publicProfile(name: name)
    }

    private func loadLegacyProfile(name: String) throws -> LegacyProfile {
        guard ProfileNameValidator.isValid(name) else {
            throw StateStoreError("Use a profile name with 1-64 letters, numbers, dots, underscores, or hyphens.")
        }
        let path = try profilesFolder().appendingPathComponent(name + ".json")
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

    private func profilesFolder() throws -> URL {
        let rootExists = try checkPrivateDirectory(directory)
        let folder = directory.appendingPathComponent("profiles", isDirectory: true)
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
