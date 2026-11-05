import Foundation

public enum ProfileCommands {
    private static let invalidArguments = "Invalid arguments. Run je --help or the command's --help.\n"

    public static func run(
        arguments: [String],
        stateDirectory: URL,
        environment: [String: String],
        secretStore: SecretStoring?
    ) -> CLIResult {
        guard arguments.first == "profile", arguments.count >= 2 else {
            return invalid()
        }
        let store = ProfileStore(directory: stateDirectory)
        do {
            switch arguments[1] {
            case "list":
                guard arguments.count == 2 else { return invalid() }
                let names = try store.listProfiles()
                let output = names.isEmpty
                    ? "No saved connections. Run je profile add --help.\n"
                    : names.joined(separator: "\n") + "\n"
                return CLIResult(code: 0, stdout: output)
            case "show":
                guard arguments.count == 3 else { return invalid() }
                return encode(try store.loadPublicProfile(name: arguments[2]))
            case "add":
                return try add(
                    arguments: arguments,
                    store: store,
                    environment: environment,
                    secretStore: secretStore ?? ProcessSecretStore.default(environment: environment)
                )
            case "remove":
                return try remove(
                    arguments: arguments,
                    store: store,
                    environment: environment,
                    secretStore: secretStore
                )
            default:
                return invalid()
            }
        } catch let error as StateStoreError {
            return CLIResult(code: 2, stderr: error.message + "\n")
        } catch {
            return CLIResult(code: 2, stderr: "The connection profile could not be updated.\n")
        }
    }

    public static func runMemory(
        arguments: [String],
        stateDirectory: URL,
        environment: [String: String],
        secretStore: SecretStoring?
    ) -> CLIResult {
        guard arguments.first == "memory", arguments.count >= 2 else { return invalid() }
        if arguments[1] == "check" {
            return CLIResult(
                code: 2,
                stderr: "This memory command is not ported to the native core yet. Use the released Python client for now.\n"
            )
        }
        let store = ProfileStore(directory: stateDirectory)
        do {
            switch arguments[1] {
            case "list":
                guard arguments.count == 2 else { return invalid() }
                let names = try store.listMemoryProfiles()
                let output = names.isEmpty
                    ? "No saved memory connections. Run je memory add --help.\n"
                    : names.joined(separator: "\n") + "\n"
                return CLIResult(code: 0, stdout: output)
            case "show":
                guard arguments.count == 3 else { return invalid() }
                return encode(try store.loadPublicMemoryProfile(name: arguments[2]))
            case "add":
                guard let parsed = MemoryAddArguments(arguments: Array(arguments.dropFirst(2))) else {
                    return invalid()
                }
                if parsed.replace {
                    _ = try store.loadPublicMemoryProfile(name: parsed.name)
                }
                let secret = try secretValue(
                    file: parsed.tokenFile,
                    environmentName: parsed.tokenEnvironment,
                    environment: environment,
                    store: store,
                    provideMessage: "Provide --token-file or --token-env when input is not interactive."
                )
                try store.saveNativeMemoryProfile(
                    name: parsed.name,
                    endpoint: parsed.endpoint,
                    secret: secret,
                    secretStore: secretStore ?? ProcessSecretStore.default(environment: environment),
                    replace: parsed.replace
                )
                return CLIResult(
                    code: 0,
                    stdout: "Saved memory connection \(parsed.name). Select it with --memory-profile \(parsed.name) when connecting.\n"
                )
            case "remove":
                guard let parsed = RemoveArguments(arguments: Array(arguments.dropFirst(2))) else {
                    return invalid()
                }
                try store.deleteMemoryProfile(
                    name: parsed.name,
                    secretStore: parsed.deleteSecret
                        ? (secretStore ?? ProcessSecretStore.default(environment: environment))
                        : nil,
                    deleteSecret: parsed.deleteSecret
                )
                return CLIResult(
                    code: 0,
                    stdout: "Local memory connection removed. Its server-side token has not been revoked.\n"
                )
            default:
                return invalid()
            }
        } catch let error as StateStoreError {
            return CLIResult(code: 2, stderr: error.message + "\n")
        } catch {
            return CLIResult(code: 2, stderr: "The memory profile could not be updated.\n")
        }
    }

    public static func runOllamaProfile(
        arguments: [String],
        stateDirectory: URL,
        environment: [String: String],
        secretStore: SecretStoring?
    ) -> CLIResult {
        guard arguments.count >= 3, arguments[0] == "ollama", arguments[1] == "profile" else {
            return invalid()
        }
        let store = ProfileStore(directory: stateDirectory)
        do {
            switch arguments[2] {
            case "list":
                guard arguments.count == 3 else { return invalid() }
                let names = try store.listOllamaProfiles()
                let output = names.isEmpty
                    ? "No saved native connections. Run je ollama profile add --help.\n"
                    : names.joined(separator: "\n") + "\n"
                return CLIResult(code: 0, stdout: output)
            case "show":
                guard arguments.count == 4 else { return invalid() }
                return encode(try store.loadPublicOllamaProfile(name: arguments[3]))
            case "add":
                guard let parsed = OllamaAddArguments(arguments: Array(arguments.dropFirst(3))) else {
                    return invalid()
                }
                let secret = try secretValue(
                    file: parsed.keyFile,
                    environmentName: parsed.keyEnvironment,
                    environment: environment,
                    store: store,
                    provideMessage: "Provide --key-file or --key-env when input is not interactive."
                )
                try store.saveNativeOllamaProfile(
                    name: parsed.name,
                    endpoint: parsed.endpoint,
                    secret: secret,
                    model: parsed.model,
                    secretStore: secretStore ?? ProcessSecretStore.default(environment: environment),
                    replace: parsed.replace
                )
                return CLIResult(
                    code: 0,
                    stdout: "Saved native connection \(parsed.name). Run je ollama --profile \(parsed.name) check.\n"
                )
            case "remove":
                guard let parsed = RemoveArguments(arguments: Array(arguments.dropFirst(3))) else {
                    return invalid()
                }
                try store.deleteOllamaProfile(
                    name: parsed.name,
                    secretStore: parsed.deleteSecret
                        ? (secretStore ?? ProcessSecretStore.default(environment: environment))
                        : nil,
                    deleteSecret: parsed.deleteSecret
                )
                return CLIResult(
                    code: 0,
                    stdout: "Local native connection removed. Its server-side key has not been revoked.\n"
                )
            default:
                return invalid()
            }
        } catch let error as StateStoreError {
            return CLIResult(code: 2, stderr: error.message + "\n")
        } catch {
            return CLIResult(code: 2, stderr: "The native Ollama profile could not be updated.\n")
        }
    }

    private static func secretValue(
        file: String?,
        environmentName: String?,
        environment: [String: String],
        store: ProfileStore,
        provideMessage: String
    ) throws -> String {
        if let file {
            return try store.readSecretFile(
                at: URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
            )
        }
        if let environmentName {
            return environment[environmentName] ?? ""
        }
        throw StateStoreError(provideMessage)
    }

    private static func add(
        arguments: [String],
        store: ProfileStore,
        environment: [String: String],
        secretStore: SecretStoring
    ) throws -> CLIResult {
        guard let parsed = AddArguments(arguments: Array(arguments.dropFirst(2))) else {
            return invalid()
        }
        if (parsed.codexCatalog == nil) != (parsed.codexVersion == nil) {
            return CLIResult(
                code: 2,
                stderr: "Provide --codex-catalog and --codex-version together.\n"
            )
        }
        let secret: String
        if let keyFile = parsed.keyFile {
            secret = try store.readSecretFile(at: URL(fileURLWithPath: (keyFile as NSString).expandingTildeInPath))
        } else if let keyEnvironment = parsed.keyEnvironment {
            secret = environment[keyEnvironment] ?? ""
        } else {
            return CLIResult(
                code: 2,
                stderr: "Provide --key-file or --key-env when input is not interactive.\n"
            )
        }
        var binding: CodexCatalogBinding?
        if let catalogPath = parsed.codexCatalog, let catalogVersion = parsed.codexVersion {
            let expanded = (catalogPath as NSString).expandingTildeInPath
            let absolutePath: String
            if expanded.hasPrefix("/") {
                absolutePath = URL(fileURLWithPath: expanded).standardizedFileURL.path
            } else {
                absolutePath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(expanded)
                    .standardizedFileURL
                    .path
            }
            do {
                binding = try CodexCatalogLoader.bind(
                    path: absolutePath,
                    requiredVersion: catalogVersion,
                    model: parsed.model,
                    contextWindow: parsed.contextWindow,
                    secret: secret
                )
            } catch let error as CodexCatalogError {
                throw StateStoreError(error.message)
            }
        }
        try store.saveNativeProfile(
            name: parsed.name,
            endpoint: parsed.endpoint,
            secret: secret,
            model: parsed.model,
            contextWindow: parsed.contextWindow,
            codexCatalog: binding,
            secretStore: secretStore,
            replace: parsed.replace
        )
        return CLIResult(code: 0, stdout: "Saved connection \(parsed.name).\n")
    }

    private static func remove(
        arguments: [String],
        store: ProfileStore,
        environment: [String: String],
        secretStore: SecretStoring?
    ) throws -> CLIResult {
        guard arguments.count == 3 || arguments == ["profile", "remove", arguments.dropFirst(2).first ?? "", "--delete-secret"] else {
            return invalid()
        }
        let deleteSecret = arguments.contains("--delete-secret")
        try store.deleteProfile(
            name: arguments[2],
            secretStore: deleteSecret
                ? (secretStore ?? ProcessSecretStore.default(environment: environment))
                : nil,
            deleteSecret: deleteSecret
        )
        return CLIResult(
            code: 0,
            stdout: "Local connection removed. Its server-side key has not been revoked.\n"
        )
    }

    private static func encode<T: Encodable>(_ value: T) -> CLIResult {
        do {
            return CLIResult(code: 0, stdout: try StableJSON.encode(value))
        } catch {
            return CLIResult(code: 1, stderr: "Could not encode the requested report.\n")
        }
    }

    private static func invalid() -> CLIResult {
        CLIResult(code: 2, stderr: invalidArguments)
    }

    private static func flagValue(
        argument: String,
        arguments: [String],
        index: inout Int,
        flags: [String]
    ) -> (String, String)? {
        for flag in flags {
            if argument == flag {
                guard index + 1 < arguments.count else { return nil }
                let value = arguments[index + 1]
                index += 2
                return (flag, value)
            }
            let prefix = flag + "="
            if argument.hasPrefix(prefix) {
                index += 1
                return (flag, String(argument.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    private struct AddArguments {
        let name: String
        let endpoint: String
        let model: String
        let contextWindow: Int?
        let keyFile: String?
        let keyEnvironment: String?
        let codexCatalog: String?
        let codexVersion: String?
        let replace: Bool

        init?(arguments: [String]) {
            guard let name = arguments.first, !name.hasPrefix("-") else { return nil }
            self.name = name
            var endpoint: String?
            var model: String?
            var context: Int?
            var keyFile: String?
            var keyEnvironment: String?
            var codexCatalog: String?
            var codexVersion: String?
            var replace = false
            var index = 1
            while index < arguments.count {
                let argument = arguments[index]
                if argument == "--replace" {
                    replace = true
                    index += 1
                    continue
                }
                guard let pair = Self.flagValue(argument: argument, arguments: arguments, index: &index),
                      !pair.1.isEmpty else {
                    return nil
                }
                switch pair.0 {
                case "--endpoint":
                    endpoint = pair.1
                case "--model":
                    model = pair.1
                case "--context-window":
                    guard let value = Int(pair.1), value > 0 else { return nil }
                    context = value
                case "--key-file":
                    guard keyFile == nil && keyEnvironment == nil else { return nil }
                    keyFile = pair.1
                case "--key-env":
                    guard keyFile == nil && keyEnvironment == nil else { return nil }
                    keyEnvironment = pair.1
                case "--codex-catalog":
                    guard codexCatalog == nil else { return nil }
                    codexCatalog = pair.1
                case "--codex-version":
                    guard codexVersion == nil else { return nil }
                    codexVersion = pair.1
                default:
                    return nil
                }
            }
            guard let endpoint, let model else { return nil }
            self.endpoint = endpoint
            self.model = model
            self.contextWindow = context
            self.keyFile = keyFile
            self.keyEnvironment = keyEnvironment
            self.codexCatalog = codexCatalog
            self.codexVersion = codexVersion
            self.replace = replace
        }

        private static func flagValue(
            argument: String,
            arguments: [String],
            index: inout Int
        ) -> (String, String)? {
            let flags = [
                "--endpoint", "--model", "--context-window", "--key-file", "--key-env",
                "--codex-catalog", "--codex-version"
            ]
            for flag in flags {
                if argument == flag {
                    guard index + 1 < arguments.count else { return nil }
                    let value = arguments[index + 1]
                    index += 2
                    return (flag, value)
                }
                let prefix = flag + "="
                if argument.hasPrefix(prefix) {
                    index += 1
                    return (flag, String(argument.dropFirst(prefix.count)))
                }
            }
            return nil
        }
    }

    private struct MemoryAddArguments {
        let name: String
        let endpoint: String
        let tokenFile: String?
        let tokenEnvironment: String?
        let replace: Bool

        init?(arguments: [String]) {
            guard let name = arguments.first, !name.hasPrefix("-") else { return nil }
            self.name = name
            var endpoint: String?
            var tokenFile: String?
            var tokenEnvironment: String?
            var replace = false
            var index = 1
            while index < arguments.count {
                let argument = arguments[index]
                if argument == "--replace" {
                    guard !replace else { return nil }
                    replace = true
                    index += 1
                    continue
                }
                guard let pair = ProfileCommands.flagValue(
                    argument: argument,
                    arguments: arguments,
                    index: &index,
                    flags: ["--endpoint", "--token-file", "--token-env"]
                ), !pair.1.isEmpty else { return nil }
                switch pair.0 {
                case "--endpoint":
                    guard endpoint == nil else { return nil }
                    endpoint = pair.1
                case "--token-file":
                    guard tokenFile == nil && tokenEnvironment == nil else { return nil }
                    tokenFile = pair.1
                case "--token-env":
                    guard tokenFile == nil && tokenEnvironment == nil else { return nil }
                    tokenEnvironment = pair.1
                default:
                    return nil
                }
            }
            guard let endpoint else { return nil }
            self.endpoint = endpoint
            self.tokenFile = tokenFile
            self.tokenEnvironment = tokenEnvironment
            self.replace = replace
        }
    }

    private struct OllamaAddArguments {
        let name: String
        let endpoint: String
        let model: String
        let keyFile: String?
        let keyEnvironment: String?
        let replace: Bool

        init?(arguments: [String]) {
            guard let name = arguments.first, !name.hasPrefix("-") else { return nil }
            self.name = name
            var endpoint: String?
            var model: String?
            var keyFile: String?
            var keyEnvironment: String?
            var replace = false
            var index = 1
            while index < arguments.count {
                let argument = arguments[index]
                if argument == "--replace" {
                    guard !replace else { return nil }
                    replace = true
                    index += 1
                    continue
                }
                guard let pair = ProfileCommands.flagValue(
                    argument: argument,
                    arguments: arguments,
                    index: &index,
                    flags: ["--endpoint", "--model", "--key-file", "--key-env"]
                ), !pair.1.isEmpty else { return nil }
                switch pair.0 {
                case "--endpoint":
                    guard endpoint == nil else { return nil }
                    endpoint = pair.1
                case "--model":
                    guard model == nil else { return nil }
                    model = pair.1
                case "--key-file":
                    guard keyFile == nil && keyEnvironment == nil else { return nil }
                    keyFile = pair.1
                case "--key-env":
                    guard keyFile == nil && keyEnvironment == nil else { return nil }
                    keyEnvironment = pair.1
                default:
                    return nil
                }
            }
            guard let endpoint, let model else { return nil }
            self.endpoint = endpoint
            self.model = model
            self.keyFile = keyFile
            self.keyEnvironment = keyEnvironment
            self.replace = replace
        }
    }

    private struct RemoveArguments {
        let name: String
        let deleteSecret: Bool

        init?(arguments: [String]) {
            if arguments.count == 1, let name = arguments.first, !name.hasPrefix("-") {
                self.name = name
                self.deleteSecret = false
            } else if arguments.count == 2, let name = arguments.first,
                      !name.hasPrefix("-"), arguments[1] == "--delete-secret" {
                self.name = name
                self.deleteSecret = true
            } else {
                return nil
            }
        }
    }
}
