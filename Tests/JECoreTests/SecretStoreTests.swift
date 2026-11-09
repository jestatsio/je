import XCTest
@testable import JECore

final class SecretStoreTests: XCTestCase {
    func testExplicitHelperPathWins() {
        let resolved = ProcessSecretStore.helperURL(
            explicitPath: "/opt/example/je-secret-helper",
            executablePath: "/usr/local/bin/je",
            pathValue: "/usr/bin"
        )
        XCTAssertEqual(resolved?.path, "/opt/example/je-secret-helper")
    }

    func testHelperResolvesThroughExecutableSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("je-secret-store-\(UUID().uuidString)")
        let libexec = root.appendingPathComponent("libexec")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: libexec, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let realExecutable = libexec.appendingPathComponent("je")
        try Data().write(to: realExecutable)
        let linkedExecutable = bin.appendingPathComponent("je")
        try FileManager.default.createSymbolicLink(at: linkedExecutable, withDestinationURL: realExecutable)

        let resolved = ProcessSecretStore.helperURL(
            explicitPath: nil,
            executablePath: linkedExecutable.path,
            pathValue: ""
        )
        let expected = libexec.appendingPathComponent("je-secret-helper")
        XCTAssertEqual(
            resolved?.resolvingSymlinksInPath().path,
            expected.resolvingSymlinksInPath().path
        )
    }

    func testPathFallbackFindsExecutableHelper() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("je-secret-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let helper = root.appendingPathComponent("je-secret-helper")
        try Data().write(to: helper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let resolved = ProcessSecretStore.helperURL(
            explicitPath: nil,
            executablePath: "je",
            pathValue: root.path
        )
        XCTAssertEqual(resolved?.path, helper.path)
    }
}
