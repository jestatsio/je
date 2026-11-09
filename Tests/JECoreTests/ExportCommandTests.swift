import Foundation
import XCTest
@testable import JECore

final class ExportCommandTests: XCTestCase {
    private var temporary: URL!
    private var stateDirectory: URL!
    private var binDirectory: URL!
    private var fakeSecrets: ExportFakeSecretStore!
    private let secret = "synthetic-export-key"
    private let helperMessage = "No executable credential helper was found. Install je or supply --helper-executable with an absolute executable file path.\n"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("je-export-tests-" + UUID().uuidString, isDirectory: true)
        stateDirectory = temporary.appendingPathComponent("state", isDirectory: true)
        binDirectory = temporary.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: binDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        fakeSecrets = ExportFakeSecretStore()
    }

    override func tearDownWithError() throws {
        if let temporary {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    func testPlainBundleMatchesOracleFiles() throws {
        try saveGatewayProfile()
        let helper = try makeExecutable(named: "je-helper")
        let result = runExport(
            ["export", "--profile", "alice", "--helper-executable", helper])
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertEqual(result.stderr, "")
        let bundle = try bundleURL(from: result)
        XCTAssertEqual(
            result.stdout,
            "Desktop setup files saved to \(bundle.path). Review README.md before applying them.\n")
        XCTAssertTrue(bundle.lastPathComponent.hasPrefix("bundle-"))
        XCTAssertEqual(bundle.deletingLastPathComponent().lastPathComponent, "alice")

        let names = try FileManager.default.contentsOfDirectory(atPath: bundle.path).sorted()
        XCTAssertEqual(names, [
            "README.md", "claude-code.settings.json", "claude-code.vscode-settings.json",
            "claude-desktop.json", "codex.config.toml", "manifest.json"
        ])
        XCTAssertEqual(try permissions(of: bundle), 0o700)
        XCTAssertEqual(try permissions(of: bundle.deletingLastPathComponent()), 0o700)
        for name in names {
            let url = bundle.appendingPathComponent(name)
            XCTAssertEqual(try permissions(of: url), 0o600, name)
            XCTAssertFalse(try Data(contentsOf: url).contains(Data(secret.utf8)), name)
        }

        let statePath = stateDirectory.path
        XCTAssertEqual(try read(bundle, "claude-code.settings.json"), """
        {
          "apiKeyHelper": "\(helper) --state-dir \(statePath) credential --profile alice",
          "env": {
            "ANTHROPIC_BASE_URL": "https://models.example.test",
            "ANTHROPIC_MODEL": "example-model",
            "ANTHROPIC_CUSTOM_MODEL_OPTION": "example-model",
            "CLAUDE_CODE_SUBAGENT_MODEL": "example-model",
            "ANTHROPIC_DEFAULT_FABLE_MODEL": "example-model",
            "ANTHROPIC_DEFAULT_OPUS_MODEL": "example-model",
            "ANTHROPIC_DEFAULT_SONNET_MODEL": "example-model",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": "example-model"
          }
        }

        """)
        XCTAssertEqual(try read(bundle, "claude-code.vscode-settings.json"), """
        {
          "claudeCode.disableLoginPrompt": true,
          "claudeCode.initialPermissionMode": "default"
        }

        """)
        XCTAssertEqual(try read(bundle, "claude-desktop.json"), """
        {
          "inferenceProvider": "gateway",
          "inferenceCredentialKind": "helper-script",
          "inferenceGatewayBaseUrl": "https://models.example.test",
          "inferenceGatewayAuthScheme": "bearer",
          "inferenceCredentialHelper": "\(helper)",
          "inferenceCredentialHelperArgs": [
            "--state-dir",
            "\(statePath)",
            "credential",
            "--profile",
            "alice"
          ],
          "inferenceModels": [
            {
              "name": "example-model",
              "labelOverride": "example-model"
            }
          ]
        }

        """)
        XCTAssertEqual(try read(bundle, "codex.config.toml"), """
        # Merge this fragment after reviewing README.md and the missing model catalog.
        model = "example-model"
        model_provider = "je_studio"

        [model_providers.je_studio]
        name = "J&E Studio"
        base_url = "https://models.example.test/v1"
        wire_api = "responses"
        requires_openai_auth = false

        [model_providers.je_studio.auth]
        command = "\(helper)"
        args = ["--state-dir", "\(statePath)", "credential", "--profile", "alice"]
        timeout_ms = 30000
        refresh_interval_ms = 300000

        """)
        let manifest = try read(bundle, "manifest.json")
        XCTAssertTrue(manifest.contains("\"context_window\": null"))
        XCTAssertTrue(manifest.contains("\"model_catalog\": \"not_provided\""))
        XCTAssertFalse(manifest.contains("catalog_binding"))
        XCTAssertEqual(
            SHA256.hexDigest(Data(try read(bundle, "README.md").utf8)),
            "bf259ed039d0917e33be71b7638affae91a36a19bf6a7f70ca8e18a8e50e5b00")
    }

    func testContextWindowFlowsIntoBundle() throws {
        try saveGatewayProfile(contextWindow: 32768)
        let helper = try makeExecutable(named: "je-helper")
        let result = runExport(
            ["export", "--profile", "alice", "--helper-executable", helper])
        XCTAssertEqual(result.code, 0, result.stderr)
        let bundle = try bundleURL(from: result)
        XCTAssertTrue(try read(bundle, "claude-code.settings.json")
            .contains("\"CLAUDE_CODE_MAX_CONTEXT_TOKENS\": \"32768\""))
        XCTAssertTrue(try read(bundle, "codex.config.toml")
            .contains("model_context_window = 32768\n"))
        XCTAssertTrue(try read(bundle, "manifest.json").contains("\"context_window\": 32768"))
    }

    func testRepeatExportsCreateSeparateBundles() throws {
        try saveGatewayProfile()
        let helper = try makeExecutable(named: "je-helper")
        let first = try bundleURL(from: runExport(
            ["export", "--profile", "alice", "--helper-executable", helper]))
        let second = try bundleURL(from: runExport(
            ["export", "--profile", "alice", "--helper-executable", helper]))
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(
            try Data(contentsOf: first.appendingPathComponent("manifest.json")),
            try Data(contentsOf: second.appendingPathComponent("manifest.json")))
    }

    func testCatalogBundleIncludesBindingAndSnapshot() throws {
        let binding = try saveCatalogProfile()
        let helper = try makeExecutable(named: "je-helper")
        let result = runExport(
            ["export", "--profile", "alice", "--helper-executable", helper])
        XCTAssertEqual(result.code, 0, result.stderr)
        let bundle = try bundleURL(from: result)
        let names = try FileManager.default.contentsOfDirectory(atPath: bundle.path).sorted()
        XCTAssertEqual(names.count, 7)
        XCTAssertEqual(
            try Data(contentsOf: bundle.appendingPathComponent("codex.catalog.json")),
            try Data(contentsOf: URL(fileURLWithPath: binding.path)))
        let manifest = try read(bundle, "manifest.json")
        XCTAssertTrue(manifest.contains("\"model_catalog\": \"bound_source_with_snapshot\""))
        XCTAssertTrue(manifest.contains("\"path\": \"\(binding.path)\""))
        XCTAssertTrue(manifest.contains("\"required_version\": \"0.167.0\""))
        XCTAssertTrue(manifest.contains("\"sha256\": \"\(binding.sha256)\""))
        XCTAssertTrue(manifest.contains("\"snapshot\": \"codex.catalog.json\""))
        XCTAssertTrue(manifest.contains("\"runtime_enforced\": false"))
        let toml = try read(bundle, "codex.config.toml")
        XCTAssertTrue(toml.hasPrefix(
            "# Merge this fragment after reviewing README.md and the catalog binding.\n"))
        XCTAssertTrue(toml.contains("model_catalog_json = \"\(binding.path)\"\n"))
        XCTAssertEqual(
            SHA256.hexDigest(Data(try read(bundle, "README.md").utf8)),
            "e4047bf3ab4ee4ff25d684600a88f5dc93f5dcdcbeecdb91aa25bdddf6b94526")
    }

    func testTamperedCatalogBlocksExport() throws {
        let binding = try saveCatalogProfile()
        try Data("{\"models\":[{\"slug\":\"example-model\"}]}".utf8)
            .write(to: URL(fileURLWithPath: binding.path))
        let helper = try makeExecutable(named: "je-helper")
        let result = runExport(
            ["export", "--profile", "alice", "--helper-executable", helper])
        XCTAssertEqual(result.code, 2)
        XCTAssertEqual(
            result.stderr,
            "The Codex catalog changed. Review it and explicitly update the saved binding.\n")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: stateDirectory.appendingPathComponent("exports").path))
    }

    func testHelperResolutionMatchesOracle() throws {
        try saveGatewayProfile()
        let helper = try makeExecutable(named: "je-helper")

        for bad in ["relative/path", "/nonexistent/helper", binDirectory.path, ""] {
            let result = runExport(
                ["export", "--profile", "alice", "--helper-executable", bad])
            XCTAssertEqual(result.code, 2, bad)
            XCTAssertEqual(result.stderr, helperMessage, bad)
        }

        // An explicit symlink path is embedded verbatim.
        let link = binDirectory.appendingPathComponent("je-link")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: URL(fileURLWithPath: helper))
        let verbatim = try bundleURL(from: runExport(
            ["export", "--profile", "alice", "--helper-executable", link.path]))
        XCTAssertTrue(try read(verbatim, "claude-desktop.json")
            .contains("\"inferenceCredentialHelper\": \"\(link.path)\""))

        // The default helper is the current executable with symlinks resolved.
        let defaulted = runExport(
            ["export", "--profile", "alice"],
            currentExecutablePath: link.path)
        XCTAssertEqual(defaulted.code, 0, defaulted.stderr)
        let defaultBundle = try bundleURL(from: defaulted)
        XCTAssertTrue(try read(defaultBundle, "claude-desktop.json")
            .contains("\"inferenceCredentialHelper\": \"\(helper)\""))

        let missing = runExport(
            ["export", "--profile", "alice"],
            currentExecutablePath: "/nonexistent/je")
        XCTAssertEqual(missing.code, 2)
        XCTAssertEqual(missing.stderr, helperMessage)
    }

    func testShellQuotingAndEscapingMatchOracle() throws {
        let spacedState = temporary.appendingPathComponent("state dir", isDirectory: true)
        try ProfileStore(directory: spacedState).saveNativeProfile(
            name: "alice",
            endpoint: "https://models.example.test",
            secret: secret,
            model: "we\"ird\\model",
            contextWindow: nil,
            secretStore: fakeSecrets
        )
        let helperDirectory = temporary.appendingPathComponent("helper dir", isDirectory: true)
        try FileManager.default.createDirectory(
            at: helperDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let helper = helperDirectory.appendingPathComponent("je-helper")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let result = JECommandLine.run(
            ["--state-dir", spacedState.path, "export", "--profile", "alice",
             "--helper-executable", helper.path],
            environment: ["PATH": binDirectory.path],
            secretStore: fakeSecrets
        )
        XCTAssertEqual(result.code, 0, result.stderr)
        let bundle = try bundleURL(from: result)
        XCTAssertTrue(try read(bundle, "claude-code.settings.json").contains(
            "\"apiKeyHelper\": \"'\(helper.path)' --state-dir '\(spacedState.path)' credential --profile alice\""))
        XCTAssertTrue(try read(bundle, "codex.config.toml")
            .contains("model = \"we\\\"ird\\\\model\"\n"))
        XCTAssertTrue(try read(bundle, "manifest.json")
            .contains("\"model\": \"we\\\"ird\\\\model\""))
    }

    func testExportErrorsMatchOracle() throws {
        try saveGatewayProfile()
        let helper = try makeExecutable(named: "je-helper")

        let missing = runExport(["export", "--profile", "nope", "--helper-executable", helper])
        XCTAssertEqual(missing.code, 2)
        XCTAssertEqual(missing.stderr, "The requested private file does not exist.\n")

        // A file where the exports directory belongs blocks the write.
        let exportsPath = stateDirectory.appendingPathComponent("exports")
        try Data("x".utf8).write(to: exportsPath)
        let blocked = runExport(["export", "--profile", "alice", "--helper-executable", helper])
        XCTAssertEqual(blocked.code, 2)
        XCTAssertEqual(blocked.stderr, "Cannot access the private state directory.\n")

        let invalidMessage = "Invalid arguments. Run je --help or the command's --help.\n"
        for arguments in [
            ["export"],
            ["export", "--profile", "alice", "extra"],
            ["export", "--profile", "alice", "--verbose"],
            ["export", "--profile", "alice", "--profile", "alice"],
            ["export", "--profile"]
        ] {
            let result = runExport(arguments)
            XCTAssertEqual(result.code, 2, arguments.description)
            XCTAssertEqual(result.stderr, invalidMessage, arguments.description)
        }
    }

    private func runExport(
        _ arguments: [String],
        environment: [String: String]? = nil,
        currentExecutablePath: String? = nil
    ) -> CLIResult {
        JECommandLine.run(
            ["--state-dir", stateDirectory.path] + arguments,
            environment: environment ?? ["PATH": binDirectory.path],
            secretStore: fakeSecrets,
            currentExecutablePath: currentExecutablePath
        )
    }

    private func bundleURL(from result: CLIResult) throws -> URL {
        let prefix = "Desktop setup files saved to "
        let suffix = ". Review README.md before applying them.\n"
        var path = try XCTUnwrap(result.stdout.hasPrefix(prefix) ? result.stdout : nil)
        path = String(path.dropFirst(prefix.count))
        XCTAssertTrue(path.hasSuffix(suffix))
        return URL(fileURLWithPath: String(path.dropLast(suffix.count)))
    }

    private func read(_ bundle: URL, _ name: String) throws -> String {
        try String(contentsOf: bundle.appendingPathComponent(name), encoding: .utf8)
    }

    private func permissions(of url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        return value?.intValue ?? -1
    }

    private func saveGatewayProfile(contextWindow: Int? = nil) throws {
        try ProfileStore(directory: stateDirectory).saveNativeProfile(
            name: "alice",
            endpoint: "https://models.example.test",
            secret: secret,
            model: "example-model",
            contextWindow: contextWindow,
            secretStore: fakeSecrets
        )
    }

    @discardableResult
    private func saveCatalogProfile() throws -> CodexCatalogBinding {
        let catalogURL = temporary.appendingPathComponent("catalog.json")
        let json = "{\"models\":[{\"slug\":\"example-model\",\"context_window\":32768,"
            + "\"max_context_window\":65536},{\"slug\":\"other-model\",\"context_window\":8192}]}"
        try Data(json.utf8).write(to: catalogURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: catalogURL.path)
        let binding = try CodexCatalogLoader.bind(
            path: catalogURL.path,
            requiredVersion: "0.167.0",
            model: "example-model",
            contextWindow: 32768,
            secret: secret
        )
        try ProfileStore(directory: stateDirectory).saveNativeProfile(
            name: "alice",
            endpoint: "https://models.example.test",
            secret: secret,
            model: "example-model",
            contextWindow: 32768,
            codexCatalog: binding,
            secretStore: fakeSecrets
        )
        return binding
    }

    private func makeExecutable(named name: String) throws -> String {
        let url = binDirectory.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }
}

private final class ExportFakeSecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func setSecret(_ secret: String, reference: String) throws {
        guard SecretReferenceValidator.isValid(reference) else {
            throw SecretStoreError.invalidReference
        }
        lock.withLock { storage[reference] = secret }
    }

    func secret(reference: String) throws -> String? {
        guard SecretReferenceValidator.isValid(reference) else {
            throw SecretStoreError.invalidReference
        }
        return lock.withLock { storage[reference] }
    }

    func deleteSecret(reference: String) throws {
        guard SecretReferenceValidator.isValid(reference) else {
            throw SecretStoreError.invalidReference
        }
        lock.withLock { storage[reference] = nil }
    }
}
