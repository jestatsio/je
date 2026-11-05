import Foundation

public struct BuiltInContextFile: Equatable, Sendable {
    public let relativePath: String
    public let text: String

    public init(relativePath: String, text: String) {
        self.relativePath = relativePath
        self.text = text
    }
}

public enum BuiltInContextError: Error, Equatable, Sendable {
    case invalidRoot
    case invalidPath
    case outsideRoot
    case missingFile
    case notRegularFile
    case symbolicLink
    case fileTooLarge
    case totalTooLarge
    case tooManyFiles
    case duplicateFile
    case binaryFile
    case secretInContext
    case unreadable

    public var message: String {
        switch self {
        case .invalidRoot:
            return "The built-in context root is not an available directory."
        case .invalidPath, .outsideRoot:
            return "A built-in context file must stay inside the explicit context root."
        case .missingFile:
            return "A built-in context file does not exist."
        case .notRegularFile:
            return "A built-in context path is not a regular file."
        case .symbolicLink:
            return "Built-in context files may not use symbolic links."
        case .fileTooLarge:
            return "A built-in context file exceeds the supported size."
        case .totalTooLarge:
            return "The built-in context exceeds the supported total size."
        case .tooManyFiles:
            return "The built-in context contains too many files."
        case .duplicateFile:
            return "A built-in context file was listed more than once."
        case .binaryFile:
            return "Built-in context files must contain UTF-8 text."
        case .secretInContext:
            return "Built-in context may not contain the selected profile credential."
        case .unreadable:
            return "A built-in context file could not be read."
        }
    }

    public var launchStatus: String {
        switch self {
        case .invalidRoot:
            return "context_root_invalid"
        case .invalidPath, .outsideRoot:
            return "context_outside_root"
        case .missingFile:
            return "context_missing"
        case .notRegularFile:
            return "context_not_regular_file"
        case .symbolicLink:
            return "context_symbolic_link"
        case .fileTooLarge:
            return "context_file_too_large"
        case .totalTooLarge:
            return "context_too_large"
        case .tooManyFiles:
            return "context_too_many_files"
        case .duplicateFile:
            return "context_duplicate_file"
        case .binaryFile:
            return "context_binary_file"
        case .secretInContext:
            return "context_secret_rejected"
        case .unreadable:
            return "context_unreadable"
        }
    }
}

public enum BuiltInContextLoader {
    public static let maximumFiles = 8
    public static let maximumFileBytes = 16_384
    public static let maximumTotalBytes = 32_768
    public static let maximumListedFiles = 256
    public static let maximumSearchMatches = 50
    public static let maximumSearchQueryCharacters = 128
    public static let maximumSearchFileBytes = 262_144
    private static let maximumDepth = 8
    private static let maximumSearchLineCharacters = 256

    public static func load(
        root: URL,
        relativePaths: [String],
        secret: String
    ) throws -> [BuiltInContextFile] {
        guard relativePaths.count <= maximumFiles else {
            throw BuiltInContextError.tooManyFiles
        }
        guard Set(relativePaths).count == relativePaths.count else {
            throw BuiltInContextError.duplicateFile
        }
        let canonicalRoot = try canonicalDirectory(root)
        var total = 0
        var files: [BuiltInContextFile] = []
        for relativePath in relativePaths {
            let file = try loadOne(
                root: canonicalRoot,
                relativePath: relativePath,
                secret: secret
            )
            total += file.text.utf8.count
            guard total <= maximumTotalBytes else {
                throw BuiltInContextError.totalTooLarge
            }
            files.append(file)
        }
        return files
    }

    public static func list(root: URL, secret: String) throws -> BuiltInContextFile {
        let canonicalRoot = try canonicalDirectory(root)
        let paths = try regularFilePaths(root: canonicalRoot, secret: secret)
        let text = paths.isEmpty ? "" : paths.joined(separator: "\n") + "\n"
        guard text.utf8.count <= maximumFileBytes else {
            throw BuiltInContextError.totalTooLarge
        }
        return BuiltInContextFile(relativePath: "[file list]", text: text)
    }

    public static func search(
        root: URL,
        query: String,
        secret: String
    ) throws -> BuiltInContextFile {
        guard !query.isEmpty,
              query.count <= maximumSearchQueryCharacters,
              !query.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw BuiltInContextError.invalidPath
        }
        if !secret.isEmpty && query.contains(secret) {
            throw BuiltInContextError.secretInContext
        }
        let canonicalRoot = try canonicalDirectory(root)
        let paths = try regularFilePaths(root: canonicalRoot, secret: secret)
        var matches: [String] = []
        for relativePath in paths {
            guard let text = try searchText(
                root: canonicalRoot,
                relativePath: relativePath,
                secret: secret
            ) else {
                continue
            }
            for (index, rawLine) in text.split(
                separator: "\n",
                omittingEmptySubsequences: false
            ).enumerated() {
                let line = String(rawLine)
                guard line.contains(query) else { continue }
                let boundedLine = line.count > maximumSearchLineCharacters
                    ? String(line.prefix(maximumSearchLineCharacters))
                    : line
                matches.append("\(relativePath):\(index + 1): \(boundedLine)")
                guard matches.count <= maximumSearchMatches else {
                    throw BuiltInContextError.totalTooLarge
                }
            }
        }
        let text = matches.isEmpty ? "" : matches.joined(separator: "\n") + "\n"
        guard text.utf8.count <= maximumFileBytes else {
            throw BuiltInContextError.totalTooLarge
        }
        return BuiltInContextFile(relativePath: "[search: \(query)]", text: text)
    }

    private static func regularFilePaths(root: URL, secret: String) throws -> [String] {
        var paths: [String] = []
        try collectFiles(
            root: root,
            directory: root,
            relativeDirectory: "",
            depth: 0,
            secret: secret,
            paths: &paths
        )
        return paths.sorted()
    }

    private static func collectFiles(
        root: URL,
        directory: URL,
        relativeDirectory: String,
        depth: Int,
        secret: String,
        paths: inout [String]
    ) throws {
        guard depth <= maximumDepth else {
            throw BuiltInContextError.totalTooLarge
        }
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )
        } catch {
            throw BuiltInContextError.unreadable
        }
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values: URLResourceValues
            do {
                values = try entry.resourceValues(forKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey
                ])
            } catch {
                throw BuiltInContextError.unreadable
            }
            if values.isSymbolicLink == true {
                throw BuiltInContextError.symbolicLink
            }
            let relativePath = relativeDirectory.isEmpty
                ? entry.lastPathComponent
                : relativeDirectory + "/" + entry.lastPathComponent
            if !secret.isEmpty && relativePath.contains(secret) {
                throw BuiltInContextError.secretInContext
            }
            if values.isDirectory == true {
                try collectFiles(
                    root: root,
                    directory: entry,
                    relativeDirectory: relativePath,
                    depth: depth + 1,
                    secret: secret,
                    paths: &paths
                )
            } else if values.isRegularFile == true {
                paths.append(relativePath)
                guard paths.count <= maximumListedFiles else {
                    throw BuiltInContextError.totalTooLarge
                }
            } else {
                throw BuiltInContextError.notRegularFile
            }
            let resolved = entry.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path == entry.standardizedFileURL.path,
                  resolved.path.hasPrefix(root.path + "/") else {
                throw BuiltInContextError.outsideRoot
            }
        }
    }

    private static func searchText(
        root: URL,
        relativePath: String,
        secret: String
    ) throws -> String? {
        let components = try validatedComponents(relativePath)
        var current = root
        for component in components {
            current.appendPathComponent(component)
        }
        let values: URLResourceValues
        do {
            values = try current.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
            ])
        } catch {
            throw BuiltInContextError.unreadable
        }
        if values.isSymbolicLink == true {
            throw BuiltInContextError.symbolicLink
        }
        guard values.isRegularFile == true else {
            throw BuiltInContextError.notRegularFile
        }
        if let size = values.fileSize, size > maximumSearchFileBytes {
            return nil
        }
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: current)
            defer { try? handle.close() }
            data = try handle.read(upToCount: maximumSearchFileBytes + 1) ?? Data()
        } catch {
            throw BuiltInContextError.unreadable
        }
        if data.count > maximumSearchFileBytes {
            return nil
        }
        guard let text = String(data: data, encoding: .utf8), !isBinary(text) else {
            return nil
        }
        if !secret.isEmpty && text.contains(secret) {
            throw BuiltInContextError.secretInContext
        }
        return text
    }

    private static func canonicalDirectory(_ root: URL) throws -> URL {
        let standardized = root.standardizedFileURL
        let values: URLResourceValues
        do {
            values = try standardized.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey
            ])
        } catch {
            throw BuiltInContextError.invalidRoot
        }
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw values.isSymbolicLink == true
                ? BuiltInContextError.symbolicLink
                : BuiltInContextError.invalidRoot
        }
        return standardized.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func loadOne(
        root: URL,
        relativePath: String,
        secret: String
    ) throws -> BuiltInContextFile {
        let components = try validatedComponents(relativePath)
        var current = root
        for (index, component) in components.enumerated() {
            current.appendPathComponent(component, isDirectory: index < components.count - 1)
            let values: URLResourceValues
            do {
                values = try current.resourceValues(forKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
                ])
            } catch {
                throw BuiltInContextError.missingFile
            }
            if values.isSymbolicLink == true {
                throw BuiltInContextError.symbolicLink
            }
            if index < components.count - 1 {
                guard values.isDirectory == true else {
                    throw BuiltInContextError.notRegularFile
                }
            } else {
                guard values.isRegularFile == true else {
                    throw BuiltInContextError.notRegularFile
                }
                if let size = values.fileSize, size > maximumFileBytes {
                    throw BuiltInContextError.fileTooLarge
                }
            }
        }

        let resolved = current.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path == current.standardizedFileURL.path,
              resolved.path.hasPrefix(root.path + "/") else {
            throw BuiltInContextError.outsideRoot
        }
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: current)
            defer { try? handle.close() }
            data = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
        } catch {
            throw BuiltInContextError.unreadable
        }
        guard data.count <= maximumFileBytes else {
            throw BuiltInContextError.fileTooLarge
        }
        guard let text = String(data: data, encoding: .utf8), !isBinary(text) else {
            throw BuiltInContextError.binaryFile
        }
        if !secret.isEmpty && (text.contains(secret) || relativePath.contains(secret)) {
            throw BuiltInContextError.secretInContext
        }
        return BuiltInContextFile(relativePath: relativePath, text: text)
    }

    private static func validatedComponents(_ relativePath: String) throws -> [String] {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.hasPrefix("~"),
              !relativePath.contains("\\"),
              !relativePath.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw BuiltInContextError.invalidPath
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw BuiltInContextError.outsideRoot
        }
        return components
    }

    private static func isBinary(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            if scalar == "\n" || scalar == "\r" || scalar == "\t" {
                return false
            }
            return scalar.value < 32 || scalar.value == 127
        }
    }
}
