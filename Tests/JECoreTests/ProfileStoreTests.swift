import Foundation
import XCTest
@testable import JECore

final class ProfileStoreTests: XCTestCase {
    private var temporary: URL!
    private var stateDirectory: URL!
    private var profilesDirectory: URL!
    private var store: ProfileStore!
    private let secret = "private-swift-test-credential"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("je-profile-tests-" + UUID().uuidString, isDirectory: true)
        stateDirectory = temporary.appendingPathComponent("state", isDirectory: true)
        profilesDirectory = stateDirectory.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(
            at: profilesDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDirectory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: profilesDirectory.path)
        store = ProfileStore(directory: stateDirectory)
    }

    override func tearDownWithError() throws {
        if let temporary {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    func testListAndShowExposePublicFieldsOnly() throws {
        try writeProfile(name: "zoe")
        try writeProfile(name: "alice")
        try Data("not a profile".utf8).write(to: profilesDirectory.appendingPathComponent("README.txt"))

        XCTAssertEqual(try store.listProfiles(), ["alice", "zoe"])
        let shown = try store.loadPublicProfile(name: "alice")
        XCTAssertEqual(shown.endpoint, "https://models.example.test")
        XCTAssertEqual(shown.model, "local-fast")
        XCTAssertEqual(shown.contextWindow, 32768)

        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "profile", "show", "alice"],
            environment: [:]
        )
        XCTAssertEqual(result.code, 0)
        XCTAssertTrue(result.stdout.contains("local-fast"))
        XCTAssertFalse((result.stdout + result.stderr).contains(secret))
        XCTAssertFalse(result.stdout.contains("api_key"))
    }

    func testEmptyProfileListUsesOracleMessage() {
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "profile", "list"],
            environment: [:]
        )
        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(result.stdout, "No saved connections. Run je profile add --help.\n")
        XCTAssertEqual(result.stderr, "")
    }

    func testSchemaTwoCatalogBindingIsShownWithoutSecret() throws {
        try writeProfile(name: "alice", schemaVersion: 2, catalog: true)
        let shown = try store.loadPublicProfile(name: "alice")
        XCTAssertEqual(shown.codexCatalog?.requiredVersion, "0.166.0")
        let json = try StableJSON.encode(shown)
        XCTAssertTrue(json.contains("required_version"))
        XCTAssertFalse(json.contains(secret))
        XCTAssertFalse(json.contains("api_key"))
    }

    func testInsecureProfileFileIsRejectedWithoutSecretOutput() throws {
        let path = try writeProfile(name: "alice")
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path.path)

        XCTAssertThrowsError(try store.loadPublicProfile(name: "alice")) { error in
            XCTAssertFalse(String(describing: error).contains(secret))
        }
        let permissions = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o640)
    }

    func testInsecureProfilesDirectoryIsRejected() throws {
        try writeProfile(name: "alice")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: profilesDirectory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: profilesDirectory.path)
        }
        XCTAssertThrowsError(try store.loadPublicProfile(name: "alice"))
    }

    func testInvalidJSONNeverAppearsInError() throws {
        let path = profilesDirectory.appendingPathComponent("alice.json")
        try Data("invalid \(secret) JSON".utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)

        XCTAssertThrowsError(try store.loadPublicProfile(name: "alice")) { error in
            XCTAssertFalse(String(describing: error).contains(secret))
        }
    }

    func testCredentialInFilenameIsRejected() throws {
        let original = try writeProfile(name: "alice")
        let unsafeName = "prefix-" + secret
        let moved = profilesDirectory.appendingPathComponent(unsafeName + ".json")
        try FileManager.default.moveItem(at: original, to: moved)

        XCTAssertThrowsError(try store.loadPublicProfile(name: unsafeName)) { error in
            XCTAssertFalse(String(describing: error).contains(secret))
        }
        XCTAssertThrowsError(try store.listProfiles()) { error in
            XCTAssertFalse(String(describing: error).contains(secret))
        }
    }

    func testSymlinkedProfileIsNotRead() throws {
        let source = try writeProfile(name: "bob")
        let target = temporary.appendingPathComponent("outside.json")
        try FileManager.default.copyItem(at: source, to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let link = profilesDirectory.appendingPathComponent("alice.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try store.loadPublicProfile(name: "alice"))
        XCTAssertEqual(try store.listProfiles(), ["bob"])
    }

    func testCatalogProfileAddStaysUnportedAndDoesNotEchoArguments() {
        let result = JECommandLine.run(
            ["--state-dir", stateDirectory.path, "profile", "add", "alice",
             "--endpoint", "https://models.example.test", "--model", "local-fast",
             "--key-env", "JE_TEST_KEY", "--codex-catalog", "/tmp/\(secret).json"],
            environment: ["JE_TEST_KEY": secret]
        )
        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.stderr.contains("catalog binding is not ported"))
        XCTAssertFalse((result.stdout + result.stderr).contains(secret))
    }

    @discardableResult
    private func writeProfile(name: String, schemaVersion: Int = 1, catalog: Bool = false) throws -> URL {
        var catalogJSON = ""
        if catalog {
            let sha = String(repeating: "0", count: 64)
            catalogJSON = ",\"codex_catalog\":{\"path\":\"/tmp/catalog.json\",\"required_version\":\"0.166.0\",\"sha256\":\"\(sha)\"}"
        }
        let json = """
        {"schema_version":\(schemaVersion),"endpoint":"https://models.example.test/v1","api_key":"\(secret)","model":"local-fast","context_window":32768\(catalogJSON)}
        """
        let path = profilesDirectory.appendingPathComponent(name + ".json")
        try Data(json.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        return path
    }
}
