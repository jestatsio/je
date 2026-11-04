import Foundation
import XCTest
@testable import JECore

final class CodexCatalogTests: XCTestCase {
    private var temporary: URL!
    private let secret = "synthetic-catalog-secret"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("je-catalog-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    override func tearDownWithError() throws {
        if let temporary {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    func testSHA256KnownVectors() {
        XCTAssertEqual(
            SHA256.hexDigest(Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            SHA256.hexDigest(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testCatalogSnapshotPreservesExactBytes() throws {
        let raw = catalogData()
        let path = try writeCatalog(raw)
        let binding = binding(path: path, digest: SHA256.hexDigest(raw))
        let snapshot = try CodexCatalogLoader.loadSnapshot(
            binding: binding,
            model: "synthetic-model",
            contextWindow: 32768,
            secret: secret
        )
        XCTAssertEqual(snapshot, raw)
    }

    func testCatalogRejectsWrongDigestDuplicatesAndContextConflictsWithoutSecret() throws {
        let raw = catalogData()
        let path = try writeCatalog(raw)
        XCTAssertThrowsError(try CodexCatalogLoader.loadSnapshot(
            binding: binding(path: path, digest: String(repeating: "0", count: 64)),
            model: "synthetic-model",
            contextWindow: 32768,
            secret: secret
        )) { error in
            XCTAssertFalse(String(describing: error).contains(secret))
        }

        let duplicate = catalogData(duplicateSlug: true)
        let duplicatePath = try writeCatalog(duplicate, name: "duplicate.json")
        XCTAssertThrowsError(try CodexCatalogLoader.loadSnapshot(
            binding: binding(path: duplicatePath, digest: SHA256.hexDigest(duplicate)),
            model: "synthetic-model",
            contextWindow: 32768,
            secret: secret
        ))

        XCTAssertThrowsError(try CodexCatalogLoader.loadSnapshot(
            binding: binding(path: path, digest: SHA256.hexDigest(raw)),
            model: "synthetic-model",
            contextWindow: 16384,
            secret: secret
        ))
    }

    func testCatalogRejectsSecretContentsAndWorldWritableFile() throws {
        let raw = catalogData(extraField: secret)
        let path = try writeCatalog(raw, name: "secret.json")
        XCTAssertThrowsError(try CodexCatalogLoader.loadSnapshot(
            binding: binding(path: path, digest: SHA256.hexDigest(raw)),
            model: "synthetic-model",
            contextWindow: 32768,
            secret: secret
        )) { error in
            XCTAssertFalse(String(describing: error).contains(secret))
        }

        let insecureRaw = catalogData()
        let insecurePath = try writeCatalog(insecureRaw, name: "insecure.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: insecurePath.path)
        XCTAssertThrowsError(try CodexCatalogLoader.loadSnapshot(
            binding: binding(path: insecurePath, digest: SHA256.hexDigest(insecureRaw)),
            model: "synthetic-model",
            contextWindow: 32768,
            secret: secret
        ))
        XCTAssertEqual(try permissions(of: insecurePath), 0o666)
    }

    func testVersionCheckSanitizesEnvironmentAndRequiresExactVersion() throws {
        let dump = temporary.appendingPathComponent("version-env.txt")
        let script = """
        #!/bin/sh
        env > "$JE_TEST_ENV_DUMP"
        printf '%s\n' 'codex-cli 0.166.0'
        """
        let executable = try writeExecutable(name: "codex", contents: script)
        try CodexCatalogLoader.checkVersion(
            executable: executable,
            requiredVersion: "0.166.0",
            environment: [
                "PATH": temporary.path,
                "JE_TEST_ENV_DUMP": dump.path,
                "JE_STUDIO_API_KEY": secret,
                "OTHER_VALUE": "prefix-\(secret)"
            ],
            secret: secret
        )
        let environmentDump = try String(contentsOf: dump, encoding: .utf8)
        XCTAssertFalse(environmentDump.contains(secret))
        XCTAssertFalse(environmentDump.contains("JE_STUDIO_API_KEY"))

        XCTAssertThrowsError(try CodexCatalogLoader.checkVersion(
            executable: executable,
            requiredVersion: "0.167.0",
            environment: ["PATH": temporary.path, "JE_TEST_ENV_DUMP": dump.path],
            secret: secret
        )) { error in
            XCTAssertEqual(error as? CodexCatalogError, .versionMismatch)
        }
    }

    func testCatalogBoundCodexLaunchUsesPrivateExactSnapshot() throws {
        let raw = catalogData()
        let path = try writeCatalog(raw)
        let binding = binding(path: path, digest: SHA256.hexDigest(raw))
        let executable = try writeExecutable(
            name: "codex",
            contents: "#!/bin/sh\nprintf '%s\n' 'codex-cli 0.166.0'\n"
        )
        let profile = ResolvedConnectionProfile(
            name: "alice",
            endpoint: "https://models.example.test",
            secret: secret,
            model: "synthetic-model",
            contextWindow: 32768,
            codexCatalog: binding
        )
        let candidate = RouteCandidate(
            id: "fast-codex-catalog",
            role: .fast,
            engine: .ollama,
            harness: .codex,
            launchMode: .headless,
            executionPlace: .personalMachine,
            providerKind: .local,
            modelArtifact: "synthetic-model",
            engineVersion: "0.40.14",
            modelFormat: "gguf",
            protocolImplementation: "ollama-native",
            protocolVersion: "native-v1",
            configurationDigest: String(repeating: "a", count: 64),
            qualificationStatus: .qualified,
            allowedPersonIDs: ["alice"],
            connectionProfileName: "alice",
            qualificationEvidenceReference: "evidence:test"
        )
        let prepared = try HarnessLaunchPreparer().prepare(
            candidate: candidate,
            profile: profile,
            prompt: "synthetic prompt",
            environment: ["PATH": temporary.path],
            executableOverride: executable.path
        )
        let catalogArgument = try XCTUnwrap(prepared.spec.arguments.first {
            $0.hasPrefix("model_catalog_json=")
        })
        let encodedPath = String(catalogArgument.dropFirst("model_catalog_json=".count))
        let decodedPath = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(encodedPath.utf8),
                options: [.fragmentsAllowed]
            ) as? String
        )
        let snapshot = URL(fileURLWithPath: decodedPath)
        XCTAssertEqual(try Data(contentsOf: snapshot), raw)
        XCTAssertEqual(try permissions(of: snapshot), 0o600)
        XCTAssertEqual(try permissions(of: snapshot.deletingLastPathComponent()), 0o700)
        XCTAssertFalse(prepared.spec.arguments.joined(separator: "\n").contains(secret))
        let directory = snapshot.deletingLastPathComponent()
        prepared.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    private func binding(path: URL, digest: String) -> CodexCatalogBinding {
        CodexCatalogBinding(path: path.path, requiredVersion: "0.166.0", sha256: digest)
    }

    private func catalogData(duplicateSlug: Bool = false, extraField: String? = nil) -> Data {
        let duplicate = duplicateSlug ? ",\"slug\":\"synthetic-model\"" : ""
        let extra = extraField.map { ",\"note\":\"\($0)\"" } ?? ""
        let json = "{\"models\":[{\"slug\":\"synthetic-model\"\(duplicate),\"context_window\":32768,\"max_context_window\":65536\(extra)},{\"slug\":\"other-model\",\"context_window\":8192}]}"
        return Data(json.utf8)
    }

    @discardableResult
    private func writeCatalog(_ data: Data, name: String = "catalog.json") throws -> URL {
        let path = temporary.appendingPathComponent(name)
        try data.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
        return path
    }

    @discardableResult
    private func writeExecutable(name: String, contents: String) throws -> URL {
        let path = temporary.appendingPathComponent(name)
        try Data(contents.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    private func permissions(of url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        return value?.intValue ?? -1
    }
}
