import Foundation

public enum ProfileNameValidator {
    public static func isValid(_ name: String) -> Bool {
        let characters = Array(name)
        guard (1...64).contains(characters.count), let first = characters.first else {
            return false
        }
        guard isASCIIAlphanumeric(first) else {
            return false
        }
        return characters.dropFirst().allSatisfy { character in
            isASCIIAlphanumeric(character) || character == "_" || character == "." || character == "-"
        }
    }

    private static func isASCIIAlphanumeric(_ character: Character) -> Bool {
        character.unicodeScalars.count == 1 && character.unicodeScalars.first.map { scalar in
            (48...57).contains(scalar.value)
                || (65...90).contains(scalar.value)
                || (97...122).contains(scalar.value)
        } == true
    }
}

public struct OracleContract: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let pythonOracleVersion: String
    public let profileSchemaVersions: [Int]
    public let publicProfileFields: [String]
    public let legacyCommandNames: [String]
    public let secretHandling: String
    public let invalidArgumentBehavior: String

    public static let frozen = OracleContract(
        schemaVersion: JEVersion.contractSchemaVersion,
        pythonOracleVersion: JEVersion.pythonOracleVersion,
        profileSchemaVersions: [1, 2],
        publicProfileFields: ["endpoint", "model", "context_window", "codex_catalog"],
        legacyCommandNames: [
            "setup", "workspace", "profile", "memory", "ollama", "connect",
            "run", "doctor", "export", "credential"
        ],
        secretHandling: "Secret values stay outside public metadata, process arguments, logs, traces, and exports.",
        invalidArgumentBehavior: "Invalid arguments fail with a fixed message and never echo argument text."
    )
}

public struct StatusReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let nativeVersion: String
    public let pythonOracleVersion: String
    public let artifact: String
    public let userModules: [String]
    public let excludedHostOnlyModules: [String]
    public let supportMatrix: SupportMatrixSummary
    public let notes: [String]

    public static var current: StatusReport {
        StatusReport(
            schemaVersion: JEVersion.contractSchemaVersion,
            nativeVersion: JEVersion.current,
            pythonOracleVersion: JEVersion.pythonOracleVersion,
            artifact: "user",
            userModules: ArtifactBoundary.userArtifactModules.map(\.name),
            excludedHostOnlyModules: ArtifactBoundary.hostOnlyModules.map(\.name),
            supportMatrix: SupportMatrix.summary,
            notes: [
                "Experimental native core. Contracts are pre-1.0.",
                "Legacy Python commands are not ported yet.",
                "Status does not open profile storage or contact a service."
            ]
        )
    }
}

public enum StableJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(value)
        data.append(10)
        return data
    }
}
