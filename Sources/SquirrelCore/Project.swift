import Foundation

public struct Project: Codable, Hashable, Identifiable, Sendable {
    public var id: String { path }
    /// Absolute path of the project root. Canonical identity.
    public var path: String
    /// Display name. Defaults to the final path component but can be overridden by the user.
    public var name: String
    /// Last time this project was seen (e.g. last Claude Code session, last manual touch).
    public var lastSeenAt: Date

    public init(path: String, name: String, lastSeenAt: Date = Date()) {
        self.path = path
        self.name = name
        self.lastSeenAt = lastSeenAt
    }

    public static func defaultName(for path: String) -> String {
        ((path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent)
    }
}

/// JSON-backed registry of known projects.
/// Stored at `~/Library/Application Support/Squirrel/projects.json`.
public enum ProjectRegistry {
    private static var storeURL: URL {
        KeychainStore.appSupportFolder.appendingPathComponent("projects.json")
    }

    public static func all() -> [Project] {
        guard let data = try? Data(contentsOf: storeURL),
              let projects = try? JSONDecoder.iso8601.decode([Project].self, from: data) else {
            return []
        }
        return projects.sorted(by: { $0.lastSeenAt > $1.lastSeenAt })
    }

    public static func find(byName name: String) -> Project? {
        all().first { $0.name.lowercased() == name.lowercased() }
    }

    public static func find(byPath path: String) -> Project? {
        let canonical = canonicalize(path)
        return all().first { canonicalize($0.path) == canonical }
    }

    /// Register a new project or touch an existing one's lastSeenAt.
    @discardableResult
    public static func register(path: String, name: String? = nil) throws -> Project {
        let canonical = canonicalize(path)
        var projects = all()
        if let index = projects.firstIndex(where: { canonicalize($0.path) == canonical }) {
            projects[index].lastSeenAt = Date()
            if let name { projects[index].name = name }
            try write(projects)
            return projects[index]
        }
        let project = Project(
            path: canonical,
            name: name ?? Project.defaultName(for: canonical)
        )
        projects.append(project)
        try write(projects)
        return project
    }

    public static func remove(path: String) throws {
        let canonical = canonicalize(path)
        let projects = all().filter { canonicalize($0.path) != canonical }
        try write(projects)
    }

    public static func remove(name: String) throws {
        let projects = all().filter { $0.name.lowercased() != name.lowercased() }
        try write(projects)
    }

    public static func rename(path: String, to newName: String) throws {
        let canonical = canonicalize(path)
        var projects = all()
        guard let index = projects.firstIndex(where: { canonicalize($0.path) == canonical }) else { return }
        projects[index].name = newName
        try write(projects)
    }

    // MARK: - Internals

    private static func write(_ projects: [Project]) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: KeychainStore.appSupportFolder.path) {
            try fm.createDirectory(at: KeychainStore.appSupportFolder, withIntermediateDirectories: true)
        }
        let data = try JSONEncoder.iso8601.encode(projects)
        try data.write(to: storeURL, options: [.atomic])
    }

    private static func canonicalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        // Resolve to absolute, but don't fail if the path doesn't exist yet.
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        return url.path
    }
}

private extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

private extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
