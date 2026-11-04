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

    private static func add(
        arguments: [String],
        store: ProfileStore,
        environment: [String: String],
        secretStore: SecretStoring
    ) throws -> CLIResult {
        guard let parsed = AddArguments(arguments: Array(arguments.dropFirst(2))) else {
            return invalid()
        }
        if parsed.hasCatalogOptions {
            return CLIResult(
                code: 2,
                stderr: "Codex catalog binding is not ported to native profile writes yet.\n"
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
        try store.saveNativeProfile(
            name: parsed.name,
            endpoint: parsed.endpoint,
            secret: secret,
            model: parsed.model,
            contextWindow: parsed.contextWindow,
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

    private struct AddArguments {
        let name: String
        let endpoint: String
        let model: String
        let contextWindow: Int?
        let keyFile: String?
        let keyEnvironment: String?
        let replace: Bool
        let hasCatalogOptions: Bool

        init?(arguments: [String]) {
            guard let name = arguments.first, !name.hasPrefix("-") else { return nil }
            self.name = name
            var endpoint: String?
            var model: String?
            var context: Int?
            var keyFile: String?
            var keyEnvironment: String?
            var replace = false
            var catalog = false
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
                case "--codex-catalog", "--codex-version":
                    catalog = true
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
            self.replace = replace
            self.hasCatalogOptions = catalog
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
}
