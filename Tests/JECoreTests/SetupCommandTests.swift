import Foundation
import XCTest
@testable import JECore

final class SetupCommandTests: XCTestCase {
    private var temporary: URL!
    private var binDirectory: URL!
    private var runner: FakeSetupRunner!
    private var confirmer: FakeSetupConfirmer!
    private let intro = "Studio integration adds connection, status, and memory skills.\n"
        + "It does not change models, credentials, approvals, or memory connections.\n"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("je-setup-tests-" + UUID().uuidString, isDirectory: true)
        binDirectory = temporary.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: binDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        for name in ["codex", "claude"] {
            let url = binDirectory.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        runner = FakeSetupRunner()
        confirmer = FakeSetupConfirmer()
    }

    override func tearDownWithError() throws {
        if let temporary {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    func testDryRunShowsInstallPlansWithoutMutations() {
        let result = runSetup(["setup", "--dry-run"])
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.stdout, intro + """
        Codex 0.167.0 detected.
        Install je@jestudio from jestatsio/je in Codex for this user.
        Dry run. No plugin or marketplace changes were made.
        Claude Code 2.1.319 detected.
        Install je@jestudio from jestatsio/je in Claude Code at user scope.
        Dry run. No plugin or marketplace changes were made.

        """)
        XCTAssertEqual(runner.calls, [
            "codex --version", "codex plugin add --help",
            "codex plugin marketplace list --json", "codex plugin list --json",
            "claude --version", "claude plugin install --help",
            "claude plugin marketplace list --json", "claude plugin list --json"
        ])
    }

    func testConfirmedInstallRegistersMarketplaceAndPlugin() {
        let result = runSetup(["setup", "--yes"])
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains(
            "Installed the Codex je plugin. Start a new client session to use its skills.\n"))
        XCTAssertTrue(result.stdout.contains(
            "Installed the Claude Code je plugin. Start a new client session to use its skills.\n"))
        XCTAssertEqual(runner.calls, [
            "codex --version", "codex plugin add --help",
            "codex plugin marketplace list --json", "codex plugin list --json",
            "codex plugin marketplace add jestatsio/je --json",
            "codex plugin marketplace list --json", "codex plugin list --json",
            "codex plugin add je@jestudio --json",
            "codex plugin marketplace list --json", "codex plugin list --json",
            "claude --version", "claude plugin install --help",
            "claude plugin marketplace list --json", "claude plugin list --json",
            "claude plugin marketplace add jestatsio/je",
            "claude plugin marketplace list --json", "claude plugin list --json",
            "claude plugin install je@jestudio --scope user --json",
            "claude plugin marketplace list --json", "claude plugin list --json"
        ])
    }

    func testPromptAcceptAndDecline() {
        confirmer.answers = [true, false]
        let result = runSetup(["setup"])
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("Continue? [y/N] "))
        XCTAssertTrue(result.stdout.contains("Installed the Codex je plugin."))
        XCTAssertTrue(result.stdout.contains("Skipped Claude Code.\n"))
        XCTAssertFalse(runner.calls.contains { $0.hasPrefix("claude plugin install je@") })
    }

    func testNonInteractiveWithoutYesFails() {
        confirmer.canPrompt = false
        let result = runSetup(["setup", "--client", "codex"])
        XCTAssertEqual(result.code, 1)
        XCTAssertEqual(
            result.stderr,
            "Codex setup failed. Run setup interactively to confirm, or pass --yes for the displayed integration.\n")
        XCTAssertFalse(runner.calls.contains { $0.contains("marketplace add") })
    }

    func testAlreadyInstalledIsSuccessWithoutMutations() {
        runner.codexMarketplace = true
        runner.codexInstalled = true
        let result = runSetup(["setup", "--client", "codex"])
        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("Codex plugin is already installed and enabled.\n"))
        XCTAssertEqual(runner.calls.count, 4)
    }

    func testRemoveFlows() {
        runner.claudeMarketplace = true
        runner.claudeInstalled = true
        let removed = runSetup(["setup", "--remove", "--yes", "--client", "claude"])
        XCTAssertEqual(removed.code, 0, removed.stderr)
        XCTAssertTrue(removed.stdout.contains(
            "Remove je@jestudio from jestatsio/je in Claude Code at user scope.\n"))
        XCTAssertTrue(removed.stdout.contains(
            "Removed the Claude Code je plugin. Its marketplace remains registered.\n"))
        XCTAssertTrue(runner.calls.contains("claude plugin uninstall je@jestudio --scope user --json"))

        runner = FakeSetupRunner()
        let nothing = runSetup(["setup", "--remove", "--yes", "--client", "claude"])
        XCTAssertEqual(nothing.code, 0, nothing.stderr)
        XCTAssertTrue(nothing.stdout.contains(
            "Claude Code plugin is not installed. Nothing to remove.\n"))
    }

    func testMissingClients() throws {
        try FileManager.default.removeItem(at: binDirectory.appendingPathComponent("claude"))
        let one = runSetup(["setup", "--dry-run"])
        XCTAssertEqual(one.code, 0, one.stderr)
        XCTAssertTrue(one.stdout.contains(
            "Claude Code is not installed. Install it separately to add the Studio plugin.\n"))

        let selected = runSetup(["setup", "--dry-run", "--client", "claude"])
        XCTAssertEqual(selected.code, 1)

        try FileManager.default.removeItem(at: binDirectory.appendingPathComponent("codex"))
        let none = runSetup(["setup", "--dry-run"])
        XCTAssertEqual(none.code, 1)
        XCTAssertTrue(none.stdout.contains("Codex is not installed."))
    }

    func testDiscoveryFailures() {
        runner.overrides["codex --version"] = SetupCommandResult(status: 0, stdout: "garbage\n")
        var result = runSetup(["setup", "--dry-run", "--client", "codex"])
        XCTAssertEqual(result.code, 1)
        XCTAssertEqual(
            result.stderr,
            "Codex setup failed. Cannot read the client version. Update the client and retry.\n")

        runner = FakeSetupRunner()
        runner.overrides["codex plugin add --help"] = SetupCommandResult(status: 0, stdout: "no json here\n")
        result = runSetup(["setup", "--dry-run", "--client", "codex"])
        XCTAssertEqual(result.code, 1)
        XCTAssertEqual(
            result.stderr,
            "Codex setup failed. Update the client to a version with native plugin management and JSON output.\n")

        runner = FakeSetupRunner()
        runner.overrides["codex plugin marketplace list --json"] = SetupCommandResult(status: 0, stdout: "not json")
        result = runSetup(["setup", "--dry-run", "--client", "codex"])
        XCTAssertEqual(result.code, 1)
        XCTAssertEqual(
            result.stderr,
            "Codex setup failed. The native plugin command returned invalid JSON.\n")

        runner = FakeSetupRunner()
        runner.overrides["codex plugin marketplace list --json"] = SetupCommandResult(status: 3, stdout: "")
        result = runSetup(["setup", "--dry-run", "--client", "codex"])
        XCTAssertEqual(result.code, 1)
        XCTAssertEqual(
            result.stderr,
            "Codex setup failed. The native plugin command failed. Check the client's plugin settings and retry.\n")
    }

    func testStateValidationFailures() {
        runner.codexMarketplaceJSON = #"{"marketplaces":[{"name":"jestudio","root":"/r","marketplaceSource":{"sourceType":"local","source":"/tmp/je"}}]}"#
        var result = runSetup(["setup", "--dry-run", "--client", "codex"])
        XCTAssertEqual(result.code, 1)
        XCTAssertEqual(
            result.stderr,
            "Codex setup failed. The jestudio marketplace uses a different source. Resolve it in the native client first.\n")
        XCTAssertEqual(runner.calls.count, 3)

        runner = FakeSetupRunner()
        runner.codexMarketplace = true
        runner.codexInstalled = true
        runner.codexEnabled = false
        result = runSetup(["setup", "--dry-run", "--client", "codex"])
        XCTAssertEqual(result.code, 1)
        XCTAssertEqual(
            result.stderr,
            "Codex setup failed. The je plugin is installed but disabled. Enable it in the native client if intended.\n")

        runner = FakeSetupRunner()
        runner.codexMarketplace = true
        runner.codexListJSON = #"{"installed":[{"pluginId":"je@jestudio","name":"je","marketplaceName":"jestudio","installed":true}],"available":[]}"#
        result = runSetup(["setup", "--dry-run", "--client", "codex"])
        XCTAssertEqual(result.code, 1)
        XCTAssertEqual(
            result.stderr,
            "Codex setup failed. The native plugin listing has an invalid enabled state.\n")

        runner = FakeSetupRunner()
        runner.codexInstalled = true
        result = runSetup(["setup", "--dry-run", "--client", "codex"])
        XCTAssertEqual(result.code, 1)
        XCTAssertEqual(
            result.stderr,
            "Codex setup failed. Cannot verify the installed je plugin source. Check its marketplace in the native client.\n")

        runner = FakeSetupRunner()
        runner.claudeMarketplace = true
        runner.claudeListJSON = #"[{"id":"je@jestudio","version":"0.2.0","scope":"project","enabled":true}]"#
        result = runSetup(["setup", "--dry-run", "--client", "claude"])
        XCTAssertEqual(result.code, 1)
        XCTAssertEqual(
            result.stderr,
            "Claude Code setup failed. The je plugin is configured at another Claude scope. Manage that scope in Claude Code first.\n")
    }

    func testVerificationFailures() {
        runner.noStateChange = true
        var result = runSetup(["setup", "--yes", "--client", "codex"])
        XCTAssertEqual(result.code, 1)
        XCTAssertEqual(
            result.stderr,
            "Codex setup failed. Cannot verify marketplace registration. No plugin was installed.\n")

        runner = FakeSetupRunner()
        runner.codexMarketplace = true
        runner.noStateChange = true
        result = runSetup(["setup", "--yes", "--client", "codex"])
        XCTAssertEqual(result.code, 1)
        XCTAssertEqual(
            result.stderr,
            "Codex setup failed. Cannot verify the plugin change. Inspect je in the native client's plugin manager.\n")

        runner = FakeSetupRunner()
        runner.overrides["codex plugin marketplace add jestatsio/je --json"] =
            SetupCommandResult(status: 3, stdout: "")
        result = runSetup(["setup", "--yes", "--client", "codex"])
        XCTAssertEqual(result.code, 1)
        XCTAssertEqual(
            result.stderr,
            "Codex setup failed. The native plugin command failed. Check the client's plugin settings and retry.\n")
    }

    func testParseErrors() {
        for arguments in [
            ["setup", "--client", "bogus"],
            ["setup", "--verbose"],
            ["setup", "--yes", "--yes"],
            ["setup", "codex"],
            ["setup", "--client"]
        ] {
            let result = runSetup(arguments)
            XCTAssertEqual(result.code, 2, arguments.description)
            XCTAssertEqual(
                result.stderr,
                "Invalid arguments. Run je --help or the command's --help.\n",
                arguments.description)
            XCTAssertEqual(result.stdout, "", arguments.description)
        }
    }

    private func runSetup(_ arguments: [String]) -> CLIResult {
        JECommandLine.run(
            arguments,
            environment: [
                "PATH": binDirectory.path,
                "HOME": temporary.path
            ],
            setupRunner: runner,
            setupConfirmer: confirmer
        )
    }
}

private final class FakeSetupConfirmer: SetupConfirming, @unchecked Sendable {
    var canPrompt = true
    var answers: [Bool] = []

    func readAnswer() -> Bool {
        answers.isEmpty ? false : answers.removeFirst()
    }
}

private final class FakeSetupRunner: SetupCommandRunning, @unchecked Sendable {
    var calls: [String] = []
    var overrides: [String: SetupCommandResult] = [:]
    var noStateChange = false
    var codexMarketplace = false
    var codexInstalled = false
    var codexEnabled = true
    var claudeMarketplace = false
    var claudeInstalled = false
    var claudeEnabled = true
    var codexMarketplaceJSON: String?
    var codexListJSON: String?
    var claudeMarketplaceJSON: String?
    var claudeListJSON: String?

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) -> SetupCommandResult {
        let key = executable.lastPathComponent + " " + arguments.joined(separator: " ")
        calls.append(key)
        if let override = overrides[key] {
            return override
        }
        return respond(key: key)
    }

    private func respond(key: String) -> SetupCommandResult {
        switch key {
        case "codex --version":
            return ok("codex-cli 0.167.0\n")
        case "claude --version":
            return ok("2.1.319 (Claude Code)\n")
        case "codex plugin add --help", "codex plugin remove --help",
             "claude plugin install --help", "claude plugin uninstall --help":
            return ok("Usage\n  --json  machine-readable output\n")
        case "codex plugin marketplace list --json":
            if let codexMarketplaceJSON { return ok(codexMarketplaceJSON) }
            return ok(codexMarketplace
                ? #"{"marketplaces":[{"name":"jestudio","root":"/fake/root","marketplaceSource":{"sourceType":"git","source":"https://github.com/jestatsio/je.git"}}]}"#
                : #"{"marketplaces":[]}"#)
        case "codex plugin list --json":
            if let codexListJSON { return ok(codexListJSON) }
            return ok(codexInstalled
                ? #"{"installed":[{"pluginId":"je@jestudio","name":"je","marketplaceName":"jestudio","version":"0.2.0","installed":true,"enabled":\#(codexEnabled)}],"available":[]}"#
                : #"{"installed":[],"available":[]}"#)
        case "codex plugin marketplace add jestatsio/je --json":
            if !noStateChange { codexMarketplace = true }
            return ok(#"{"marketplaceName":"jestudio"}"#)
        case "codex plugin add je@jestudio --json":
            if !noStateChange { codexInstalled = true }
            return ok(#"{"pluginId":"je@jestudio"}"#)
        case "codex plugin remove je@jestudio --json":
            if !noStateChange { codexInstalled = false }
            return ok(#"{"pluginId":"je@jestudio"}"#)
        case "claude plugin marketplace list --json":
            if let claudeMarketplaceJSON { return ok(claudeMarketplaceJSON) }
            return ok(claudeMarketplace
                ? #"[{"name":"jestudio","source":"github","repo":"jestatsio/je","installLocation":"/fake/root"}]"#
                : "[]")
        case "claude plugin list --json":
            if let claudeListJSON { return ok(claudeListJSON) }
            return ok(claudeInstalled
                ? #"[{"id":"je@jestudio","version":"0.2.0","scope":"user","enabled":\#(claudeEnabled)}]"#
                : "[]")
        case "claude plugin marketplace add jestatsio/je":
            if !noStateChange { claudeMarketplace = true }
            return ok("Successfully added marketplace: jestudio\n")
        case "claude plugin install je@jestudio --scope user --json":
            if !noStateChange { claudeInstalled = true }
            return ok("Successfully installed plugin: je@jestudio\n")
        case "claude plugin uninstall je@jestudio --scope user --json":
            if !noStateChange { claudeInstalled = false }
            return ok("Successfully uninstalled plugin: je\n")
        default:
            return SetupCommandResult(status: 0, stdout: "")
        }
    }

    private func ok(_ stdout: String) -> SetupCommandResult {
        SetupCommandResult(status: 0, stdout: stdout)
    }
}
