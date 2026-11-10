import Foundation

public enum CredentialMigrationStatus: String, Codable, Equatable, Sendable {
    case migrated
    case alreadyMigrated = "already_migrated"
    case failed
    case wouldMigrate = "would_migrate"
}

public enum CredentialMigrationCheck: String, Codable, Equatable, Sendable {
    case passed
    case failed
    case notRun = "not_run"
}

public struct CredentialMigrationResult: Codable, Equatable, Sendable {
    public let name: String
    public let status: CredentialMigrationStatus
    public let check: CredentialMigrationCheck
    public let detail: String?

    public init(
        name: String,
        status: CredentialMigrationStatus,
        check: CredentialMigrationCheck,
        detail: String? = nil
    ) {
        self.name = name
        self.status = status
        self.check = check
        self.detail = detail
    }
}

public struct CredentialMigrationSummary: Codable, Equatable, Sendable {
    public let migrated: Int
    public let alreadyMigrated: Int
    public let failed: Int
    public let wouldMigrate: Int

    enum CodingKeys: String, CodingKey {
        case migrated
        case alreadyMigrated = "already_migrated"
        case failed
        case wouldMigrate = "would_migrate"
    }

    public init(results: [CredentialMigrationResult]) {
        migrated = results.filter { $0.status == .migrated }.count
        alreadyMigrated = results.filter { $0.status == .alreadyMigrated }.count
        failed = results.filter { $0.status == .failed }.count
        wouldMigrate = results.filter { $0.status == .wouldMigrate }.count
    }
}

public struct CredentialMigrationReport: Codable, Equatable, Sendable {
    public let kind: String
    public let backupWarning: String
    public let results: [CredentialMigrationResult]
    public let summary: CredentialMigrationSummary

    enum CodingKeys: String, CodingKey {
        case kind
        case backupWarning = "backup_warning"
        case results
        case summary
    }

    public static let backupWarningText =
        "Older backups and exports may still contain embedded secrets. Review them separately."

    public init(kind: String, results: [CredentialMigrationResult]) {
        self.kind = kind
        self.backupWarning = Self.backupWarningText
        self.results = results
        self.summary = CredentialMigrationSummary(results: results)
    }

    public var hasFailures: Bool {
        summary.failed > 0
    }
}

public enum CredentialMigrator {
    public static func migrateGateway(
        store: ProfileStore,
        name: String,
        secretStore: SecretStoring,
        transport: BoundedHTTPTransport,
        dryRun: Bool
    ) throws -> CredentialMigrationResult {
        guard try store.gatewaySecretStorage(name: name) == .embeddedLegacy else {
            return CredentialMigrationResult(
                name: name, status: .alreadyMigrated, check: .notRun
            )
        }
        let resolved = try store.loadResolvedProfile(name: name, secretStore: secretStore)
        if dryRun {
            return CredentialMigrationResult(
                name: name, status: .wouldMigrate, check: .notRun
            )
        }
        if let binding = resolved.codexCatalog {
            do {
                _ = try CodexCatalogLoader.loadSnapshot(
                    binding: binding,
                    model: resolved.model,
                    contextWindow: resolved.contextWindow,
                    secret: resolved.secret
                )
            } catch let error as CodexCatalogError {
                return CredentialMigrationResult(
                    name: name, status: .failed, check: .failed, detail: error.message
                )
            } catch {
                return CredentialMigrationResult(
                    name: name, status: .failed, check: .failed,
                    detail: "The saved Codex catalog binding could not be verified."
                )
            }
        }
        let reference = "gateway/profile/\(name)/\(UUID().uuidString.lowercased())"
        guard storeAndVerify(resolved.secret, reference: reference, secretStore: secretStore) else {
            return CredentialMigrationResult(
                name: name, status: .failed, check: .notRun,
                detail: "The credential could not be stored in native secret storage."
            )
        }
        do {
            let report = try GatewayConnectionChecker.check(profile: resolved, transport: transport)
            guard report.passed else {
                try? secretStore.deleteSecret(reference: reference)
                return CredentialMigrationResult(
                    name: name, status: .failed, check: .failed,
                    detail: "Connected, but the selected model is not available to this key."
                )
            }
        } catch let error as GatewayCheckError {
            try? secretStore.deleteSecret(reference: reference)
            return CredentialMigrationResult(
                name: name, status: .failed, check: .failed, detail: error.message
            )
        } catch {
            try? secretStore.deleteSecret(reference: reference)
            return CredentialMigrationResult(
                name: name, status: .failed, check: .failed,
                detail: "The gateway connection could not be checked."
            )
        }
        do {
            try store.commitGatewayMigration(
                name: name, reference: reference, expectedSecret: resolved.secret
            )
        } catch let error as StateStoreError {
            try? secretStore.deleteSecret(reference: reference)
            return CredentialMigrationResult(
                name: name, status: .failed, check: .passed, detail: error.message
            )
        } catch {
            try? secretStore.deleteSecret(reference: reference)
            return CredentialMigrationResult(
                name: name, status: .failed, check: .passed,
                detail: "The connection profile could not be updated."
            )
        }
        return CredentialMigrationResult(
            name: name, status: .migrated, check: .passed
        )
    }

    public static func migrateMemory(
        store: ProfileStore,
        name: String,
        secretStore: SecretStoring,
        transport: MemoryHTTPTransport,
        dryRun: Bool
    ) throws -> CredentialMigrationResult {
        guard try store.memorySecretStorage(name: name) == .embeddedLegacy else {
            return CredentialMigrationResult(
                name: name, status: .alreadyMigrated, check: .notRun
            )
        }
        let resolved = try store.loadResolvedMemoryProfile(name: name, secretStore: secretStore)
        if dryRun {
            return CredentialMigrationResult(
                name: name, status: .wouldMigrate, check: .notRun
            )
        }
        let reference = "memory/profile/\(name)/\(UUID().uuidString.lowercased())"
        guard storeAndVerify(resolved.secret, reference: reference, secretStore: secretStore) else {
            return CredentialMigrationResult(
                name: name, status: .failed, check: .notRun,
                detail: "The credential could not be stored in native secret storage."
            )
        }
        do {
            let report = try MemoryConnectionChecker.check(profile: resolved, transport: transport)
            guard report.passed else {
                try? secretStore.deleteSecret(reference: reference)
                return CredentialMigrationResult(
                    name: name, status: .failed, check: .failed,
                    detail: "Connected, but the expected memory read tools are not available."
                )
            }
        } catch let error as MemoryCheckError {
            try? secretStore.deleteSecret(reference: reference)
            return CredentialMigrationResult(
                name: name, status: .failed, check: .failed, detail: error.message
            )
        } catch {
            try? secretStore.deleteSecret(reference: reference)
            return CredentialMigrationResult(
                name: name, status: .failed, check: .failed,
                detail: "The memory connection could not be checked."
            )
        }
        do {
            try store.commitMemoryMigration(
                name: name, reference: reference, expectedSecret: resolved.secret
            )
        } catch let error as StateStoreError {
            try? secretStore.deleteSecret(reference: reference)
            return CredentialMigrationResult(
                name: name, status: .failed, check: .passed, detail: error.message
            )
        } catch {
            try? secretStore.deleteSecret(reference: reference)
            return CredentialMigrationResult(
                name: name, status: .failed, check: .passed,
                detail: "The memory profile could not be updated."
            )
        }
        return CredentialMigrationResult(
            name: name, status: .migrated, check: .passed
        )
    }

    public static func migrateOllama(
        store: ProfileStore,
        name: String,
        secretStore: SecretStoring,
        transport: OllamaHTTPTransport,
        dryRun: Bool
    ) throws -> CredentialMigrationResult {
        guard try store.ollamaSecretStorage(name: name) == .embeddedLegacy else {
            return CredentialMigrationResult(
                name: name, status: .alreadyMigrated, check: .notRun
            )
        }
        let resolved = try store.loadResolvedOllamaProfile(name: name, secretStore: secretStore)
        if dryRun {
            return CredentialMigrationResult(
                name: name, status: .wouldMigrate, check: .notRun
            )
        }
        let reference = "ollama/profile/\(name)/\(UUID().uuidString.lowercased())"
        guard storeAndVerify(resolved.secret, reference: reference, secretStore: secretStore) else {
            return CredentialMigrationResult(
                name: name, status: .failed, check: .notRun,
                detail: "The credential could not be stored in native secret storage."
            )
        }
        do {
            let report = try OllamaConnectionChecker.check(profile: resolved, transport: transport)
            guard report.passed else {
                try? secretStore.deleteSecret(reference: reference)
                return CredentialMigrationResult(
                    name: name, status: .failed, check: .failed,
                    detail: "Connected, but the default native model is not available to this key."
                )
            }
        } catch let error as OllamaCheckError {
            try? secretStore.deleteSecret(reference: reference)
            return CredentialMigrationResult(
                name: name, status: .failed, check: .failed, detail: error.message
            )
        } catch {
            try? secretStore.deleteSecret(reference: reference)
            return CredentialMigrationResult(
                name: name, status: .failed, check: .failed,
                detail: "The native Ollama connection could not be checked."
            )
        }
        do {
            try store.commitOllamaMigration(
                name: name, reference: reference, expectedSecret: resolved.secret
            )
        } catch let error as StateStoreError {
            try? secretStore.deleteSecret(reference: reference)
            return CredentialMigrationResult(
                name: name, status: .failed, check: .passed, detail: error.message
            )
        } catch {
            try? secretStore.deleteSecret(reference: reference)
            return CredentialMigrationResult(
                name: name, status: .failed, check: .passed,
                detail: "The native Ollama profile could not be updated."
            )
        }
        return CredentialMigrationResult(
            name: name, status: .migrated, check: .passed
        )
    }

    private static func storeAndVerify(
        _ secret: String,
        reference: String,
        secretStore: SecretStoring
    ) -> Bool {
        do {
            try secretStore.setSecret(secret, reference: reference)
            guard try secretStore.secret(reference: reference) == secret else {
                try? secretStore.deleteSecret(reference: reference)
                return false
            }
            return true
        } catch {
            try? secretStore.deleteSecret(reference: reference)
            return false
        }
    }
}
