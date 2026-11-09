import Foundation

public enum ExportError: Error, Equatable, Sendable {
    case helperUnavailable
    case stateAccessFailed

    public var message: String {
        switch self {
        case .helperUnavailable:
            return "No executable credential helper was found. Install je or supply --helper-executable with an absolute executable file path."
        case .stateAccessFailed:
            return "Cannot access the private state directory."
        }
    }
}

/// Matches the oracle's JSON string encoding, which leaves slashes bare
/// (JSONSerialization would emit "\/" inside quoted values).
enum OracleStringEscaping {
    static func jsonString(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22:
                result += "\\\""
            case 0x5C:
                result += "\\\\"
            case 0x08:
                result += "\\b"
            case 0x09:
                result += "\\t"
            case 0x0A:
                result += "\\n"
            case 0x0C:
                result += "\\f"
            case 0x0D:
                result += "\\r"
            case 0x20...0x7E:
                result.unicodeScalars.append(scalar)
            case 0x00...0xFFFF:
                result += String(format: "\\u%04x", scalar.value)
            default:
                let shifted = scalar.value - 0x10000
                result += String(
                    format: "\\u%04x\\u%04x",
                    0xD800 + shifted / 0x400, 0xDC00 + shifted % 0x400)
            }
        }
        result += "\""
        return result
    }

    static func shellQuoted(_ value: String) -> String {
        if value.isEmpty {
            return "''"
        }
        let safe = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

/// Ordered JSON encoded the way the oracle writes it (two-space indent,
/// insertion-ordered keys, ASCII-escaped strings).
indirect enum OrderedJSON {
    case string(String)
    case int(Int)
    case bool(Bool)
    case null
    case array([OrderedJSON])
    case object([(String, OrderedJSON)])

    func encode() -> String {
        encode(indent: 0)
    }

    private func encode(indent: Int) -> String {
        switch self {
        case .string(let value):
            return OracleStringEscaping.jsonString(value)
        case .int(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        case .array(let items):
            if items.isEmpty { return "[]" }
            let inner = String(repeating: " ", count: indent + 2)
            let outer = String(repeating: " ", count: indent)
            return "[\n"
                + items.map { inner + $0.encode(indent: indent + 2) }.joined(separator: ",\n")
                + "\n" + outer + "]"
        case .object(let pairs):
            if pairs.isEmpty { return "{}" }
            let inner = String(repeating: " ", count: indent + 2)
            let outer = String(repeating: " ", count: indent)
            return "{\n"
                + pairs.map {
                    inner + OracleStringEscaping.jsonString($0.0) + ": "
                        + $0.1.encode(indent: indent + 2)
                }.joined(separator: ",\n")
                + "\n" + outer + "}"
        }
    }
}

public struct DesktopExportWriter: Sendable {
    public init() {}

    /// Writes one review bundle under `exports/<profile>/bundle-<random>`
    /// inside the state directory and returns the bundle directory. Files
    /// never contain the gateway secret; apps fetch it through the helper.
    public func writeBundle(
        profile: ResolvedConnectionProfile,
        catalogSnapshot: Data?,
        helperPath: String,
        stateDirectory: URL
    ) throws -> URL {
        // The oracle embeds the absolutized state path without resolving
        // symlinks, so normalize lexically instead of standardizing the URL.
        let statePath = Self.normalizedAbsolutePath(stateDirectory.path)
        let stateURL = URL(fileURLWithPath: statePath, isDirectory: true)
        let bundle: URL
        do {
            let exportsDirectory = try ensurePrivateDirectory(
                stateURL.appendingPathComponent("exports", isDirectory: true))
            let profileDirectory = try ensurePrivateDirectory(
                exportsDirectory.appendingPathComponent(profile.name, isDirectory: true))
            bundle = profileDirectory.appendingPathComponent(
                "bundle-" + Self.randomHex(byteCount: 12), isDirectory: true)
            try FileManager.default.createDirectory(
                at: bundle,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ExportError.stateAccessFailed
        }
        do {
            let files = bundleFiles(
                profile: profile,
                catalogSnapshot: catalogSnapshot,
                helperPath: helperPath,
                statePath: statePath
            )
            for file in files {
                guard !file.contents.contains(Data(profile.secret.utf8)),
                      FileManager.default.createFile(
                        atPath: bundle.appendingPathComponent(file.name).path,
                        contents: file.contents,
                        attributes: [.posixPermissions: 0o600]
                      ) else {
                    throw ExportError.stateAccessFailed
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: bundle)
            throw ExportError.stateAccessFailed
        }
        return bundle
    }

    private struct BundleFile {
        let name: String
        let contents: Data
    }

    private func bundleFiles(
        profile: ResolvedConnectionProfile,
        catalogSnapshot: Data?,
        helperPath: String,
        statePath: String
    ) -> [BundleFile] {
        var files = [
            BundleFile(name: "README.md", contents: Data(
                ExportReadme.text(hasCatalogBinding: profile.codexCatalog != nil).utf8)),
            BundleFile(name: "manifest.json", contents: Data(
                (manifest(profile: profile).encode() + "\n").utf8)),
            BundleFile(name: "codex.config.toml", contents: Data(
                codexConfiguration(profile: profile, helperPath: helperPath, statePath: statePath).utf8)),
            BundleFile(name: "claude-desktop.json", contents: Data(
                (claudeDesktop(profile: profile, helperPath: helperPath, statePath: statePath).encode() + "\n").utf8)),
            BundleFile(name: "claude-code.settings.json", contents: Data(
                (claudeCodeSettings(profile: profile, helperPath: helperPath, statePath: statePath).encode() + "\n").utf8)),
            BundleFile(name: "claude-code.vscode-settings.json", contents: Data(
                (vscodeSettings().encode() + "\n").utf8))
        ]
        if let catalogSnapshot {
            files.append(BundleFile(name: "codex.catalog.json", contents: catalogSnapshot))
        }
        return files
    }

    private func manifest(profile: ResolvedConnectionProfile) -> OrderedJSON {
        var codexSurface: [(String, OrderedJSON)] = [
            ("status", .string("fragment_exported")),
            ("file", .string("codex.config.toml")),
            ("model_catalog", .string(
                profile.codexCatalog == nil ? "not_provided" : "bound_source_with_snapshot")),
            ("runtime_verified", .bool(false))
        ]
        if let binding = profile.codexCatalog {
            codexSurface.append(("catalog_binding", .object([
                ("path", .string(binding.path)),
                ("required_version", .string(binding.requiredVersion)),
                ("sha256", .string(binding.sha256)),
                ("snapshot", .string("codex.catalog.json")),
                ("runtime_enforced", .bool(false))
            ])))
        }
        return .object([
            ("schema_version", .int(1)),
            ("profile", .string(profile.name)),
            ("endpoint", .string(profile.endpoint)),
            ("model", .string(profile.model)),
            ("context_window", profile.contextWindow.map(OrderedJSON.int) ?? .null),
            ("activated", .bool(false)),
            ("runtime_verified", .bool(false)),
            ("surfaces", .object([
                ("codex", .object(codexSurface)),
                ("claude-desktop", .object([
                    ("status", .string("fragment_exported")),
                    ("file", .string("claude-desktop.json")),
                    ("minimum_helper_args_version", .string("2.110.0")),
                    ("context_window_binding", .string("unverified")),
                    ("native_approvals", .string("unverified")),
                    ("runtime_verified", .bool(false))
                ])),
                ("claude-vscode", .object([
                    ("status", .string("exported_pending_editor_qualification")),
                    ("files", .array([
                        .string("claude-code.settings.json"),
                        .string("claude-code.vscode-settings.json")
                    ])),
                    ("credential_helper_shell", .string("posix")),
                    ("prelaunch_authentication", .string("unverified")),
                    ("context_window_binding", .string("unverified")),
                    ("native_approvals", .string("unverified")),
                    ("runtime_verified", .bool(false))
                ]))
            ]))
        ])
    }

    private func claudeDesktop(
        profile: ResolvedConnectionProfile,
        helperPath: String,
        statePath: String
    ) -> OrderedJSON {
        .object([
            ("inferenceProvider", .string("gateway")),
            ("inferenceCredentialKind", .string("helper-script")),
            ("inferenceGatewayBaseUrl", .string(profile.endpoint)),
            ("inferenceGatewayAuthScheme", .string("bearer")),
            ("inferenceCredentialHelper", .string(helperPath)),
            ("inferenceCredentialHelperArgs", .array(
                credentialArguments(profile: profile, statePath: statePath)
                    .map(OrderedJSON.string))),
            ("inferenceModels", .array([.object([
                ("name", .string(profile.model)),
                ("labelOverride", .string(profile.model))
            ])]))
        ])
    }

    private func claudeCodeSettings(
        profile: ResolvedConnectionProfile,
        helperPath: String,
        statePath: String
    ) -> OrderedJSON {
        let helperCommand = ([helperPath] + credentialArguments(profile: profile, statePath: statePath))
            .map(OracleStringEscaping.shellQuoted)
            .joined(separator: " ")
        var env: [(String, OrderedJSON)] = [
            ("ANTHROPIC_BASE_URL", .string(profile.endpoint)),
            ("ANTHROPIC_MODEL", .string(profile.model)),
            ("ANTHROPIC_CUSTOM_MODEL_OPTION", .string(profile.model)),
            ("CLAUDE_CODE_SUBAGENT_MODEL", .string(profile.model)),
            ("ANTHROPIC_DEFAULT_FABLE_MODEL", .string(profile.model)),
            ("ANTHROPIC_DEFAULT_OPUS_MODEL", .string(profile.model)),
            ("ANTHROPIC_DEFAULT_SONNET_MODEL", .string(profile.model)),
            ("ANTHROPIC_DEFAULT_HAIKU_MODEL", .string(profile.model))
        ]
        if let context = profile.contextWindow {
            env.append(("CLAUDE_CODE_MAX_CONTEXT_TOKENS", .string(String(context))))
        }
        return .object([
            ("apiKeyHelper", .string(helperCommand)),
            ("env", .object(env))
        ])
    }

    private func vscodeSettings() -> OrderedJSON {
        .object([
            ("claudeCode.disableLoginPrompt", .bool(true)),
            ("claudeCode.initialPermissionMode", .string("default"))
        ])
    }

    private func credentialArguments(
        profile: ResolvedConnectionProfile,
        statePath: String
    ) -> [String] {
        ["--state-dir", statePath, "credential", "--profile", profile.name]
    }

    private func codexConfiguration(
        profile: ResolvedConnectionProfile,
        helperPath: String,
        statePath: String
    ) -> String {
        let quoted = OracleStringEscaping.jsonString
        var lines = [
            "# Merge this fragment after reviewing README.md and the "
                + (profile.codexCatalog == nil ? "missing model catalog." : "catalog binding."),
            "model = " + quoted(profile.model),
            "model_provider = \"je_studio\""
        ]
        if let context = profile.contextWindow {
            lines.append("model_context_window = \(context)")
        }
        if let binding = profile.codexCatalog {
            lines.append("model_catalog_json = " + quoted(binding.path))
        }
        let arguments = credentialArguments(profile: profile, statePath: statePath)
            .map(quoted)
            .joined(separator: ", ")
        lines.append(contentsOf: [
            "",
            "[model_providers.je_studio]",
            "name = \"J&E Studio\"",
            "base_url = " + quoted(profile.apiBase),
            "wire_api = \"responses\"",
            "requires_openai_auth = false",
            "",
            "[model_providers.je_studio.auth]",
            "command = " + quoted(helperPath),
            "args = [" + arguments + "]",
            "timeout_ms = 30000",
            "refresh_interval_ms = 300000"
        ])
        return lines.joined(separator: "\n") + "\n"
    }

    private func ensurePrivateDirectory(_ url: URL) throws -> URL {
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw ExportError.stateAccessFailed
            }
            return url
        }
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    private static func normalizedAbsolutePath(_ path: String) -> String {
        var absolute = path
        if !absolute.hasPrefix("/") {
            absolute = FileManager.default.currentDirectoryPath + "/" + absolute
        }
        var components: [String] = []
        for part in absolute.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." {
                continue
            }
            if part == ".." {
                _ = components.popLast()
                continue
            }
            components.append(String(part))
        }
        return "/" + components.joined(separator: "/")
    }

    private static func randomHex(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<byteCount)
            .map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
            .joined()
    }
}
