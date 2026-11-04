public enum ModuleOwnership: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case user
    case shared
    case hostOnly = "host_only"
}

public struct ModuleDescriptor: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let ownership: ModuleOwnership

    public init(name: String, ownership: ModuleOwnership) {
        self.name = name
        self.ownership = ownership
    }

    public var includedInUserArtifact: Bool {
        ownership != .hostOnly
    }
}

public enum ArtifactBoundary {
    public static let modules: [ModuleDescriptor] = [
        ModuleDescriptor(name: "contracts", ownership: .shared),
        ModuleDescriptor(name: "profiles", ownership: .shared),
        ModuleDescriptor(name: "routing_policy", ownership: .shared),
        ModuleDescriptor(name: "role_registry", ownership: .shared),
        ModuleDescriptor(name: "harness_adapters", ownership: .shared),
        ModuleDescriptor(name: "usage_ledger", ownership: .shared),
        ModuleDescriptor(name: "status", ownership: .shared),
        ModuleDescriptor(name: "cli", ownership: .user),
        ModuleDescriptor(name: "built_in_readonly", ownership: .user),
        ModuleDescriptor(name: "jobs_client", ownership: .user),
        ModuleDescriptor(name: "menu_bar_companion", ownership: .user),
        ModuleDescriptor(name: "workspaces", ownership: .hostOnly),
        ModuleDescriptor(name: "network_policy", ownership: .hostOnly),
        ModuleDescriptor(name: "service_control", ownership: .hostOnly),
        ModuleDescriptor(name: "host_lifecycle", ownership: .hostOnly),
        ModuleDescriptor(name: "workspace_administration", ownership: .hostOnly)
    ]

    public static var userArtifactModules: [ModuleDescriptor] {
        modules.filter(\.includedInUserArtifact)
    }

    public static var hostOnlyModules: [ModuleDescriptor] {
        modules.filter { $0.ownership == .hostOnly }
    }

    public static func userArtifactViolations(moduleNames: [String]) -> [String] {
        let hostOnlyNames = Set(hostOnlyModules.map(\.name))
        return moduleNames.filter { hostOnlyNames.contains($0) }.sorted()
    }
}
