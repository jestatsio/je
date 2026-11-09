import Foundation
import XCTest
@testable import JECore

final class ConnectCommandTests: XCTestCase {
    private var temporary: URL!
    private var stateDirectory: URL!
    private var binDirectory: URL!
    private var fakeSecrets: ConnectFakeSecretStore!
    private let secret = "synthetic-connect-key"
    private let token = "synthetic-connect-token"
    private let invalidMessage = "Invalid arguments. Run je --help or the command's --help.\n"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("je-connect-tests-" + UUID().uuidString, isDirectory: true)
        stateDirectory = temporary.appendingPathComponent("state", isDirectory: true)
        binDirectory = temporary.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: binDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        fakeSecrets = ConnectFakeSecretStore()
    }

    override func tearDownWithError() throws {
        if let temporary {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    func testCodexLaunchMatchesOracleConfiguration() throws {
        try saveGatewayProfile()
        let executable = try makeExecutable(named: "codex")
        let runner = ConnectCapturingRunner()
        runner.exitCode = 7
        let result = runConnect(
            ["connect", "codex", "--profile", "alice", "--executable", executable],
            environment: [
                "PATH": binDirectory.path,
                "JE_GATEWAY_API_KEY": "stale-gateway",
                "JE_STUDIO_API_KEY": "stale-studio",
                "OPENAI_API_KEY": "stale-openai"
            ],
            runner: runner
        )
        XCTAssertEqual(result.code, 7, result.stderr)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")
        let spec = try XCTUnwrap(runner.spec)
        XCTAssertEqual(spec.executableURL.path, executable)
        XCTAssertEqual(spec.arguments, [
            "-c", "model=\"example-model\"",
            "-c", "model_provider=\"je_studio\"",
            "-c", "model_providers.je_studio.name=\"J&E Studio\"",
            "-c", "model_providers.je_studio.base_url=\"https://models.example.test/v1\"",
            "-c", "model_providers.je_studio.env_key=\"JE_STUDIO_API_KEY\"",
            "-c", "model_providers.je_studio.wire_api=\"responses\"",
            "-c", "model_providers.je_studio.requires_openai_auth=false"
        ])
        XCTAssertEqual(spec.environment["JE_STUDIO_API_KEY"], secret)
        XCTAssertNil(spec.environment["JE_GATEWAY_API_KEY"])
        XCTAssertEqual(spec.environment["OPENAI_API_KEY"], "stale-openai")
        XCTAssertFalse(spec.arguments.contains { $0.contains(secret) })
        XCTAssertFalse((result.stdout + result.stderr).contains(secret))
    }

    func testCodexContextWindowAndTrailingArguments() throws {
        try saveGatewayProfile(contextWindow: 32768)
        let executable = try makeExecutable(named: "codex")
        let runner = ConnectCapturingRunner()
        let result = runConnect(
            ["connect", "codex", "--profile", "alice", "--executable", executable,
             "--", "--help", "extra"],
            runner: runner
        )
        XCTAssertEqual(result.code, 0, result.stderr)
        let spec = try XCTUnwrap(runner.spec)
        XCTAssertEqual(spec.arguments.suffix(4), [
            "-c", "model_context_window=32768", "--help", "extra"
        ])
    }

    func testDifferingModelDropsContextForSessionOnly() throws {
        try saveGatewayProfile(contextWindow: 32768)
        let executable = try makeExecutable(named: "codex")
        let runner = ConnectCapturingRunner()
        let result = runConnect(
            ["connect", "codex", "--profile", "alice", "--model", "other-model",
             "--executable", executable],
            runner: runner
        )
        XCTAssertEqual(result.code, 0, result.stderr)
        let spec = try XCTUnwrap(runner.spec)
        XCTAssertEqual(spec.arguments[1], "model=\"other-model\"")
        XCTAssertFalse(spec.arguments.contains { $0.hasPrefix("model_context_window") })
        let stored = try ProfileStore(directory: stateDirectory)
            .loadPublicProfile(name: "alice")
        XCTAssertEqual(stored.model, "example-model")
        XCTAssertEqual(stored.contextWindow, 32768)
    }

    func testEmptyAndEqualModelOverridesKeepSavedProfile() throws {
        try saveGatewayProfile(contextWindow: 32768)
        let executable = try makeExecutable(named: "codex")
        for model in ["", "example-model"] {
            let runner = ConnectCapturingRunner()
            let result = runConnect(
                ["connect", "codex", "--profile", "alice", "--model", model,
                 "--executable", executable],
                runner: runner
            )
            XCTAssertEqual(result.code, 0, result.stderr)
            let spec = try XCTUnwrap(runner.spec)
            XCTAssertEqual(spec.arguments[1], "model=\"example-model\"")
            XCTAssertTrue(spec.arguments.contains("model_context_window=32768"))
        }
    }

    func testCatalogBoundCodexLaunchUsesExactSnapshot() throws {
        let binding = try saveCatalogProfile(requiredVersion: "0.167.0")
        let executable = try makeExecutable(
            named: "codex",
            body: "#!/bin/sh\nprintf '%s\\n' 'codex-cli 0.167.0'\n"
        )
        let runner = ConnectCapturingRunner()
        var snapshotBytes: Data?
        var snapshotPermissions: Int?
        var snapshotDirectory: URL?
        runner.onRun = { spec in
            guard let argument = spec.arguments.first(where: {
                $0.hasPrefix("model_catalog_json=")
            }) else { return }
            let encoded = String(argument.dropFirst("model_catalog_json=".count))
            guard let data = encoded.data(using: .utf8),
                  let path = try? JSONSerialization.jsonObject(
                    with: data, options: [.fragmentsAllowed]) as? String else { return }
            let url = URL(fileURLWithPath: path)
            snapshotBytes = try? Data(contentsOf: url)
            snapshotPermissions = (try? FileManager.default
                .attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)??.intValue
            snapshotDirectory = url.deletingLastPathComponent()
        }
        let result = runConnect(
            ["connect", "codex", "--profile", "alice", "--executable", executable],
            runner: runner
        )
        XCTAssertEqual(result.code, 0, result.stderr)
        let spec = try XCTUnwrap(runner.spec)
        XCTAssertTrue(spec.arguments.contains("model_context_window=32768"))
        XCTAssertEqual(snapshotBytes, try Data(contentsOf: URL(fileURLWithPath: binding.path)))
        XCTAssertEqual(snapshotPermissions, 0o600)
        let directory = try XCTUnwrap(snapshotDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testCatalogVersionFailuresMatchOracle() throws {
        _ = try saveCatalogProfile(requiredVersion: "0.167.0")
        let mismatch = try makeExecutable(
            named: "codex-mismatch",
            body: "#!/bin/sh\nprintf '%s\\n' 'codex-cli 0.166.0'\n"
        )
        let mismatchRunner = ConnectCapturingRunner()
        let mismatchResult = runConnect(
            ["connect", "codex", "--profile", "alice", "--executable", mismatch],
            runner: mismatchRunner
        )
        XCTAssertEqual(mismatchResult.code, 2)
        XCTAssertEqual(
            mismatchResult.stderr,
            "The installed Codex version does not match the saved catalog binding.\n")
        XCTAssertNil(mismatchRunner.spec)

        for body in [
            "#!/bin/sh\nprintf '%s\\n' 'garbage'\n",
            "#!/bin/sh\nprintf '%s\\n' 'codex-cli garbage'\n",
            "#!/bin/sh\nprintf '%s\\n' 'codex-cli 0.167'\n",
            "#!/bin/sh\nprintf '%s\\n' 'codex-cli 0.167.0-alpha..1'\n",
            "#!/bin/sh\nexit 1\n"
        ] {
            let broken = try makeExecutable(named: "codex-broken", body: body)
            let runner = ConnectCapturingRunner()
            let result = runConnect(
                ["connect", "codex", "--profile", "alice", "--executable", broken],
                runner: runner
            )
            XCTAssertEqual(result.code, 2)
            XCTAssertEqual(
                result.stderr,
                "Codex did not return a recognized version; no session was started.\n")
            XCTAssertNil(runner.spec)
        }
    }

    func testChangedCatalogIsRejected() throws {
        let binding = try saveCatalogProfile(requiredVersion: "0.167.0")
        try Data("{\"models\":[{\"slug\":\"example-model\"}]}".utf8)
            .write(to: URL(fileURLWithPath: binding.path))
        let executable = try makeExecutable(
            named: "codex",
            body: "#!/bin/sh\nprintf '%s\\n' 'codex-cli 0.167.0'\n"
        )
        let runner = ConnectCapturingRunner()
        let result = runConnect(
            ["connect", "codex", "--profile", "alice", "--executable", executable],
            runner: runner
        )
        XCTAssertEqual(result.code, 2)
        XCTAssertEqual(
            result.stderr,
            "The Codex catalog changed. Review it and explicitly update the saved binding.\n")
        XCTAssertNil(runner.spec)
    }

    func testCodexMemoryAttachmentMatchesOracle() throws {
        _ = try saveCatalogProfile(requiredVersion: ConnectLaunchPreparer.qualifiedCodexMemoryVersion)
        try saveMemoryProfile()
        let serverName = try ProfileStore(directory: stateDirectory)
            .loadResolvedMemoryProfile(name: "mem1", secretStore: fakeSecrets).serverName
        let executable = try makeExecutable(
            named: "codex",
            body: "#!/bin/sh\nprintf '%s\\n' 'codex-cli \(ConnectLaunchPreparer.qualifiedCodexMemoryVersion)'\n"
        )
        let runner = ConnectCapturingRunner()
        let result = runConnect(
            ["connect", "codex", "--profile", "alice", "--memory-profile", "mem1",
             "--executable", executable, "--", "resume"],
            runner: runner
        )
        XCTAssertEqual(result.code, 0, result.stderr)
        let spec = try XCTUnwrap(runner.spec)
        XCTAssertEqual(spec.arguments.suffix(9), [
            "-c", "mcp_servers.\(serverName).url=\"https://memory.example.test/mcp\"",
            "-c", "mcp_servers.\(serverName).bearer_token_env_var=\"JE_MEMORY_TOKEN\"",
            "-c", "mcp_servers.\(serverName).required=true",
            "-c", "mcp_servers.\(serverName).startup_readiness=\"connection\"",
            "resume"
        ])
        XCTAssertEqual(spec.environment["JE_MEMORY_TOKEN"], token)
        XCTAssertFalse(spec.arguments.contains { $0.contains(token) })
    }

    func testCodexMemoryGatesMatchOracle() throws {
        try saveMemoryProfile()
        let alpha = "codex-cli \(ConnectLaunchPreparer.qualifiedCodexMemoryVersion)"

        // A plain profile attaches memory on the qualified binary alone.
        try saveGatewayProfile()
        let alphaExecutable = try makeExecutable(
            named: "codex-alpha",
            body: "#!/bin/sh\nprintf '%s\\n' '\(alpha)'\n"
        )
        let plainRunner = ConnectCapturingRunner()
        let plain = runConnect(
            ["connect", "codex", "--profile", "alice", "--memory-profile", "mem1",
             "--executable", alphaExecutable],
            runner: plainRunner
        )
        XCTAssertEqual(plain.code, 0, plain.stderr)
        XCTAssertNotNil(plainRunner.spec)

        // The same plain profile rejects a release binary.
        let releaseExecutable = try makeExecutable(
            named: "codex-release",
            body: "#!/bin/sh\nprintf '%s\\n' 'codex-cli 0.167.0'\n"
        )
        let releaseRunner = ConnectCapturingRunner()
        let release = runConnect(
            ["connect", "codex", "--profile", "alice", "--memory-profile", "mem1",
             "--executable", releaseExecutable],
            runner: releaseRunner
        )
        XCTAssertEqual(release.code, 2)
        XCTAssertEqual(
            release.stderr,
            "The installed Codex version does not match the saved catalog binding.\n")
        XCTAssertNil(releaseRunner.spec)

        // A catalog binding for another version fails before the binary runs.
        _ = try saveCatalogProfile(name: "bound", requiredVersion: "0.167.0")
        let log = temporary.appendingPathComponent("version-called.log")
        let logging = try makeExecutable(
            named: "codex-logging",
            body: "#!/bin/sh\nprintf 'called' > \"\(log.path)\"\nprintf '%s\\n' '\(alpha)'\n"
        )
        let boundRunner = ConnectCapturingRunner()
        let bound = runConnect(
            ["connect", "codex", "--profile", "bound", "--memory-profile", "mem1",
             "--executable", logging],
            runner: boundRunner
        )
        XCTAssertEqual(bound.code, 2)
        XCTAssertEqual(
            bound.stderr,
            "Memory attachment requires the qualified Codex version and a matching catalog binding.\n")
        XCTAssertNil(boundRunner.spec)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    }

    func testVersionCheckEnvironmentIsSanitized() throws {
        _ = try saveCatalogProfile(requiredVersion: "0.167.0")
        let dump = temporary.appendingPathComponent("version-env.txt")
        let executable = try makeExecutable(
            named: "codex",
            body: "#!/bin/sh\n/usr/bin/env > \"\(dump.path)\"\nprintf '%s\\n' 'codex-cli 0.167.0'\n"
        )
        let runner = ConnectCapturingRunner()
        let result = runConnect(
            ["connect", "codex", "--profile", "alice", "--executable", executable],
            environment: [
                "PATH": binDirectory.path,
                "JE_STUDIO_API_KEY": "stale-value",
                "SOME_VAR": "prefix-" + secret,
                "KEEP_ME": "plain"
            ],
            runner: runner
        )
        XCTAssertEqual(result.code, 0, result.stderr)
        let dumped = try String(contentsOf: dump, encoding: .utf8)
        XCTAssertFalse(dumped.contains(secret))
        XCTAssertFalse(dumped.contains("JE_STUDIO_API_KEY"))
        XCTAssertFalse(dumped.contains("SOME_VAR"))
        XCTAssertTrue(dumped.contains("KEEP_ME=plain"))
    }

    func testClaudeLaunchMatchesOracleSettingsAndEnvironment() throws {
        try saveGatewayProfile()
        let executable = try makeClaudeExecutable()
        let runner = ConnectCapturingRunner()
        runner.exitCode = 9
        var settingsText: String?
        var settingsPermissions: Int?
        var settingsDirectory: URL?
        runner.onRun = { spec in
            guard let index = spec.arguments.firstIndex(of: "--settings"),
                  index + 1 < spec.arguments.count else { return }
            let url = URL(fileURLWithPath: spec.arguments[index + 1])
            settingsText = try? String(contentsOf: url, encoding: .utf8)
            settingsPermissions = (try? FileManager.default
                .attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)??.intValue
            settingsDirectory = url.deletingLastPathComponent()
        }
        let result = runConnect(
            ["connect", "claude", "--profile", "alice", "--executable", executable],
            environment: [
                "PATH": binDirectory.path,
                "ANTHROPIC_API_KEY": "stale-key",
                "JE_GATEWAY_API_KEY": "stale-gateway"
            ],
            runner: runner
        )
        XCTAssertEqual(result.code, 9, result.stderr)
        let spec = try XCTUnwrap(runner.spec)
        XCTAssertEqual(spec.arguments.count, 4)
        XCTAssertEqual(spec.arguments[0], "--settings")
        XCTAssertEqual(spec.arguments.suffix(2), ["--model", "example-model"])

        let text = try XCTUnwrap(settingsText)
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let expectedEnv: [String: String] = [
            "ANTHROPIC_BASE_URL": "https://models.example.test",
            "ANTHROPIC_AUTH_TOKEN": secret,
            "ANTHROPIC_API_KEY": "",
            "CLAUDE_CODE_OAUTH_TOKEN": "",
            "CLAUDE_CODE_USE_BEDROCK": "",
            "CLAUDE_CODE_USE_VERTEX": "",
            "CLAUDE_CODE_USE_FOUNDRY": "",
            "CLAUDE_CODE_USE_ANTHROPIC_AWS": "",
            "ANTHROPIC_MODEL": "example-model",
            "ANTHROPIC_DEFAULT_MODEL": "example-model",
            "ANTHROPIC_CUSTOM_MODEL_OPTION": "example-model",
            "CLAUDE_CODE_SUBAGENT_MODEL": "example-model",
            "ANTHROPIC_DEFAULT_FABLE_MODEL": "example-model",
            "ANTHROPIC_DEFAULT_OPUS_MODEL": "example-model",
            "ANTHROPIC_DEFAULT_SONNET_MODEL": "example-model",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": "example-model"
        ]
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed["env"] as? [String: String], expectedEnv)
        XCTAssertEqual(settingsPermissions, 0o600)
        for (key, value) in expectedEnv {
            XCTAssertEqual(spec.environment[key], value, key)
        }
        XCTAssertEqual(spec.environment["JE_GATEWAY_API_KEY"], "stale-gateway")
        XCTAssertFalse(spec.arguments.contains { $0.contains(secret) })
        XCTAssertFalse((result.stdout + result.stderr).contains(secret))
        let directory = try XCTUnwrap(settingsDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testClaudeContextWindowAndMemoryConfiguration() throws {
        try saveGatewayProfile(contextWindow: 32768)
        try saveMemoryProfile()
        let serverName = try ProfileStore(directory: stateDirectory)
            .loadResolvedMemoryProfile(name: "mem1", secretStore: fakeSecrets).serverName
        let executable = try makeClaudeExecutable()
        let runner = ConnectCapturingRunner()
        var mcpText: String?
        runner.onRun = { spec in
            guard let index = spec.arguments.firstIndex(of: "--mcp-config"),
                  index + 1 < spec.arguments.count else { return }
            mcpText = try? String(
                contentsOf: URL(fileURLWithPath: spec.arguments[index + 1]),
                encoding: .utf8)
        }
        let connected = runConnect(
            ["connect", "claude", "--profile", "alice", "--memory-profile", "mem1",
             "--executable", executable],
            runner: runner
        )
        XCTAssertEqual(connected.code, 0, connected.stderr)
        let spec = try XCTUnwrap(runner.spec)
        XCTAssertEqual(spec.environment["CLAUDE_CODE_MAX_CONTEXT_TOKENS"], "32768")
        XCTAssertEqual(spec.arguments.count, 6)
        XCTAssertEqual(spec.arguments[2], "--mcp-config")
        XCTAssertEqual(spec.arguments.suffix(2), ["--model", "example-model"])
        let parsedMCP = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(XCTUnwrap(mcpText).utf8))
                as? [String: Any])
        let servers = try XCTUnwrap(parsedMCP["mcpServers"] as? [String: Any])
        let server = try XCTUnwrap(servers[serverName] as? [String: Any])
        XCTAssertEqual(server["type"] as? String, "http")
        XCTAssertEqual(server["url"] as? String, "https://memory.example.test/mcp")
        XCTAssertEqual(
            (server["headers"] as? [String: String])?["Authorization"],
            "Bearer " + token)
        XCTAssertFalse(spec.arguments.contains { $0.contains(token) })

        let overridden = ConnectCapturingRunner()
        let overriddenResult = runConnect(
            ["connect", "claude", "--profile", "alice", "--model", "other-model",
             "--executable", executable],
            runner: overridden
        )
        XCTAssertEqual(overriddenResult.code, 0, overriddenResult.stderr)
        XCTAssertNil(overridden.spec?.environment["CLAUDE_CODE_MAX_CONTEXT_TOKENS"])
        XCTAssertEqual(overridden.spec?.environment["ANTHROPIC_MODEL"], "other-model")
    }

    func testClaudeAuthenticationFailuresMatchOracle() throws {
        try saveGatewayProfile()
        let cases: [(name: String, json: String, exit: Int, message: String)] = [
            ("loggedout",
             "{\"loggedIn\":false,\"authMethod\":\"oauth_token\",\"apiProvider\":\"firstParty\"}",
             0,
             "Claude Code selected another sign-in or provider. Check its auth status before connecting.\n"),
            ("method",
             "{\"loggedIn\":true,\"authMethod\":\"api_key\",\"apiProvider\":\"firstParty\"}",
             0,
             "Claude Code selected another sign-in or provider. Check its auth status before connecting.\n"),
            ("garbage", "not json", 0,
             "Claude Code authentication could not be verified; no session was started.\n"),
            ("exitone",
             "{\"loggedIn\":true,\"authMethod\":\"oauth_token\",\"apiProvider\":\"firstParty\"}",
             1,
             "Claude Code could not confirm the selected gateway credentials; no session was started.\n")
        ]
        for testCase in cases {
            let executable = try makeClaudeExecutable(
                named: "claude-" + testCase.name, authJSON: testCase.json, authExit: testCase.exit)
            let runner = ConnectCapturingRunner()
            let result = runConnect(
                ["connect", "claude", "--profile", "alice", "--executable", executable],
                runner: runner
            )
            XCTAssertEqual(result.code, 2, testCase.name)
            XCTAssertEqual(result.stderr, testCase.message, testCase.name)
            XCTAssertNil(runner.spec, testCase.name)
            XCTAssertFalse((result.stdout + result.stderr).contains(secret), testCase.name)
        }
    }

    func testMissingProfilesAndCredentialGuards() throws {
        try saveGatewayProfile()
        try saveMemoryProfile()
        let codex = try makeExecutable(named: "codex")
        let claude = try makeClaudeExecutable()

        let missingProfile = runConnect(
            ["connect", "codex", "--profile", "nope", "--executable", codex],
            runner: ConnectCapturingRunner())
        XCTAssertEqual(missingProfile.code, 2)
        XCTAssertEqual(missingProfile.stderr, "The requested private file does not exist.\n")

        let missingMemory = runConnect(
            ["connect", "claude", "--profile", "alice", "--memory-profile", "nope",
             "--executable", claude],
            runner: ConnectCapturingRunner())
        XCTAssertEqual(missingMemory.code, 2)
        XCTAssertEqual(missingMemory.stderr, "The requested private file does not exist.\n")

        let trailingSecret = runConnect(
            ["connect", "codex", "--profile", "alice", "--executable", codex, "--", secret],
            runner: ConnectCapturingRunner())
        XCTAssertEqual(trailingSecret.code, 2)
        XCTAssertEqual(
            trailingSecret.stderr,
            "Do not place the gateway credential in command-line arguments.\n")
        XCTAssertFalse((trailingSecret.stdout + trailingSecret.stderr).contains(secret))

        let trailingToken = runConnect(
            ["connect", "claude", "--profile", "alice", "--memory-profile", "mem1",
             "--executable", claude, "--", token],
            runner: ConnectCapturingRunner())
        XCTAssertEqual(trailingToken.code, 2)
        XCTAssertEqual(
            trailingToken.stderr,
            "Keep credentials out of public connection metadata and command-line arguments.\n")

        let unloadedTokenRunner = ConnectCapturingRunner()
        let unloadedToken = runConnect(
            ["connect", "claude", "--profile", "alice", "--executable", claude, "--", token],
            runner: unloadedTokenRunner)
        XCTAssertEqual(unloadedToken.code, 0, unloadedToken.stderr)
        XCTAssertEqual(unloadedTokenRunner.spec?.arguments.last, token)

        let modelSecret = runConnect(
            ["connect", "codex", "--profile", "alice", "--model", secret,
             "--executable", codex],
            runner: ConnectCapturingRunner())
        XCTAssertEqual(modelSecret.code, 2)
        XCTAssertEqual(
            modelSecret.stderr,
            "Keep gateway credentials separate from the endpoint and model name.\n")

        let modelToken = runConnect(
            ["connect", "claude", "--profile", "alice", "--memory-profile", "mem1",
             "--model", token, "--executable", claude],
            runner: ConnectCapturingRunner())
        XCTAssertEqual(modelToken.code, 2)
        XCTAssertEqual(
            modelToken.stderr,
            "Keep credentials out of public connection metadata and command-line arguments.\n")

        for badModel in [" padded ", "a\nb"] {
            let result = runConnect(
                ["connect", "codex", "--profile", "alice", "--model", badModel,
                 "--executable", codex],
                runner: ConnectCapturingRunner())
            XCTAssertEqual(result.code, 2)
            XCTAssertEqual(
                result.stderr,
                "A nonempty model name without control characters is required.\n")
            XCTAssertFalse((result.stdout + result.stderr).contains(secret))
        }
    }

    func testExecutableResolutionAndFailures() throws {
        try saveGatewayProfile()
        let missingCodex = runConnect(
            ["connect", "codex", "--profile", "alice", "--executable", "/nonexistent/codex"],
            runner: ConnectCapturingRunner())
        XCTAssertEqual(missingCodex.code, 2)
        XCTAssertEqual(
            missingCodex.stderr, "Install Codex or provide the path to its executable.\n")

        let missingClaude = runConnect(
            ["connect", "claude", "--profile", "alice"],
            environment: ["PATH": binDirectory.path, "HOME": temporary.path],
            runner: ConnectCapturingRunner())
        XCTAssertEqual(missingClaude.code, 2)
        XCTAssertEqual(
            missingClaude.stderr,
            "Install Claude Code or provide the path to its executable.\n")

        // Claude falls back to ~/.local/bin when PATH has no claude.
        let homeBin = temporary.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: homeBin, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let homeClaude = homeBin.appendingPathComponent("claude")
        try Data(claudeScript(authJSON: defaultAuthJSON, authExit: 0).utf8).write(to: homeClaude)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: homeClaude.path)
        let fallbackRunner = ConnectCapturingRunner()
        let fallback = runConnect(
            ["connect", "claude", "--profile", "alice"],
            environment: ["PATH": binDirectory.path, "HOME": temporary.path],
            runner: fallbackRunner)
        XCTAssertEqual(fallback.code, 0, fallback.stderr)
        XCTAssertEqual(fallbackRunner.spec?.executableURL.path, homeClaude.path)

        // A secret inside the resolved path is rejected before launch.
        let secretBin = temporary.appendingPathComponent(secret, isDirectory: true)
        try FileManager.default.createDirectory(
            at: secretBin, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let secretExe = secretBin.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: secretExe)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: secretExe.path)
        let secretPath = runConnect(
            ["connect", "codex", "--profile", "alice", "--executable", secretExe.path],
            runner: ConnectCapturingRunner())
        XCTAssertEqual(secretPath.code, 2)
        XCTAssertEqual(
            secretPath.stderr,
            "Do not place the gateway credential in the executable path.\n")
        XCTAssertFalse((secretPath.stdout + secretPath.stderr).contains(secret))

        // A runner start failure uses the oracle launch message.
        let executable = try makeExecutable(named: "codex")
        let throwing = ConnectCapturingRunner()
        throwing.error = HarnessLaunchError.launchFailed
        let failed = runConnect(
            ["connect", "codex", "--profile", "alice", "--executable", executable],
            runner: throwing)
        XCTAssertEqual(failed.code, 2)
        XCTAssertEqual(failed.stderr, "The harness process could not be started.\n")
    }

    func testArgumentParsingMatchesNativeConventions() throws {
        try saveGatewayProfile()
        let executable = try makeExecutable(named: "codex")
        let invalidCases: [[String]] = [
            ["connect"],
            ["connect", "codex"],
            ["connect", "bogus", "--profile", "alice"],
            ["connect", "codex", "--profile", "alice", "extra"],
            ["connect", "codex", "--profile", "alice", "--verbose"],
            ["connect", "codex", "--profile", "alice", "--profile", "alice"],
            ["connect", "codex", "--", "--profile", "alice"],
            ["connect", "codex", "--profile"],
            ["connect", "codex", "--help"]
        ]
        for arguments in invalidCases {
            let result = runConnect(arguments, runner: ConnectCapturingRunner())
            XCTAssertEqual(result.code, 2, arguments.description)
            XCTAssertEqual(result.stderr, invalidMessage, arguments.description)
        }

        let reordered = ConnectCapturingRunner()
        let flagsFirst = runConnect(
            ["connect", "--profile=alice", "codex", "--executable=\(executable)"],
            runner: reordered)
        XCTAssertEqual(flagsFirst.code, 0, flagsFirst.stderr)
        XCTAssertNotNil(reordered.spec)
    }

    func testRealProcessExitAndSignalCodes() throws {
        try saveGatewayProfile()
        let exiting = try makeExecutable(
            named: "codex-exit", body: "#!/bin/sh\nprintf '%s' \"$JE_STUDIO_API_KEY\" > \"$CONNECT_TEST_OUT\"\nexit 7\n")
        let output = temporary.appendingPathComponent("real-env.txt")
        let exitResult = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "connect", "codex",
             "--profile", "alice", "--executable", exiting],
            environment: [
                "PATH": binDirectory.path,
                "CONNECT_TEST_OUT": output.path
            ],
            secretStore: fakeSecrets
        )
        XCTAssertEqual(exitResult.code, 7, exitResult.stderr)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), secret)

        let signaling = try makeExecutable(
            named: "codex-term", body: "#!/bin/sh\nkill -TERM $$\n")
        let signalResult = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "connect", "codex",
             "--profile", "alice", "--executable", signaling],
            environment: ["PATH": binDirectory.path],
            secretStore: fakeSecrets
        )
        XCTAssertEqual(signalResult.code, 128 + 15, signalResult.stderr)
    }

    func testLegacyEmbeddedProfileConnects() throws {
        let profiles = stateDirectory.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(
            at: profiles, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: stateDirectory.path)
        let path = profiles.appendingPathComponent("alice.json")
        let json = "{\"schema_version\":1,\"endpoint\":\"https://models.example.test\""
            + ",\"api_key\":\"\(secret)\",\"model\":\"example-model\",\"context_window\":null}"
        try Data(json.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let executable = try makeExecutable(named: "codex")
        let runner = ConnectCapturingRunner()
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "connect", "codex",
             "--profile", "alice", "--executable", executable],
            environment: ["PATH": binDirectory.path],
            secretStore: fakeSecrets,
            harnessRunner: runner
        )
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertEqual(runner.spec?.environment["JE_STUDIO_API_KEY"], secret)
    }

    private var defaultAuthJSON: String {
        "{\"loggedIn\":true,\"authMethod\":\"oauth_token\",\"apiProvider\":\"firstParty\"}"
    }

    private func runConnect(
        _ arguments: [String],
        environment: [String: String]? = nil,
        runner: ConnectCapturingRunner
    ) -> CLIResult {
        JECommandLine.run(
            ["--state-dir", stateDirectory.path] + arguments,
            environment: environment ?? ["PATH": binDirectory.path],
            secretStore: fakeSecrets,
            harnessRunner: runner
        )
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
    private func saveCatalogProfile(
        name: String = "alice",
        requiredVersion: String
    ) throws -> CodexCatalogBinding {
        let catalogURL = temporary.appendingPathComponent("catalog-\(name).json")
        let json = "{\"models\":[{\"slug\":\"example-model\",\"context_window\":32768,"
            + "\"max_context_window\":65536},{\"slug\":\"other-model\",\"context_window\":8192}]}"
        try Data(json.utf8).write(to: catalogURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: catalogURL.path)
        let binding = try CodexCatalogLoader.bind(
            path: catalogURL.path,
            requiredVersion: requiredVersion,
            model: "example-model",
            contextWindow: 32768,
            secret: secret
        )
        try ProfileStore(directory: stateDirectory).saveNativeProfile(
            name: name,
            endpoint: "https://models.example.test",
            secret: secret,
            model: "example-model",
            contextWindow: 32768,
            codexCatalog: binding,
            secretStore: fakeSecrets
        )
        return binding
    }

    private func saveMemoryProfile() throws {
        try ProfileStore(directory: stateDirectory).saveNativeMemoryProfile(
            name: "mem1",
            endpoint: "https://memory.example.test/mcp",
            secret: token,
            secretStore: fakeSecrets
        )
    }

    private func makeExecutable(
        named name: String, body: String = "#!/bin/sh\nexit 0\n"
    ) throws -> String {
        let url = binDirectory.appendingPathComponent(name)
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func makeClaudeExecutable(
        named name: String = "claude",
        authJSON: String? = nil,
        authExit: Int = 0
    ) throws -> String {
        try makeExecutable(
            named: name,
            body: claudeScript(authJSON: authJSON ?? defaultAuthJSON, authExit: authExit)
        )
    }

    private func claudeScript(authJSON: String, authExit: Int) -> String {
        """
        #!/bin/sh
        for a in "$@"; do
          if [ "$a" = "auth" ]; then
            printf '%s' '\(authJSON)'
            exit \(authExit)
          fi
        done
        exit 0
        """
    }
}

private final class ConnectCapturingRunner: HarnessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: HarnessLaunchSpec?
    var exitCode: Int32 = 0
    var error: Error?
    var onRun: ((HarnessLaunchSpec) -> Void)?

    var spec: HarnessLaunchSpec? {
        lock.withLock { captured }
    }

    func run(_ spec: HarnessLaunchSpec) throws -> Int32 {
        lock.withLock { captured = spec }
        onRun?(spec)
        if let error {
            throw error
        }
        return exitCode
    }
}

private final class ConnectFakeSecretStore: SecretStoring, @unchecked Sendable {
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
