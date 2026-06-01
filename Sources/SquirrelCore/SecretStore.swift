import Foundation

/// File-based secret store at `~/Library/Application Support/Squirrel/secrets.json` (0600).
/// Used in lieu of Keychain because ad-hoc signing changes code identity per rebuild,
/// triggering repeated Keychain auth prompts. Switch back to Keychain once the app
/// ships with a stable Developer ID signature.
///
/// Kept the historical name `KeychainStore` to avoid churn at call sites.
public enum KeychainStore {
    public static func set(_ value: String, for key: String) {
        var dict = readAll()
        if value.isEmpty {
            dict.removeValue(forKey: key)
        } else {
            dict[key] = value
        }
        writeAll(dict)
    }

    public static func get(_ key: String) -> String? {
        readAll()[key]
    }

    public static func delete(_ key: String) {
        var dict = readAll()
        dict.removeValue(forKey: key)
        writeAll(dict)
    }

    // MARK: - Storage

    public static let appSupportFolder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Squirrel", isDirectory: true)
    }()

    private static var storeURL: URL {
        appSupportFolder.appendingPathComponent("secrets.json")
    }

    private static func readAll() -> [String: String] {
        guard let data = try? Data(contentsOf: storeURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private static func writeAll(_ dict: [String: String]) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: appSupportFolder.path) {
            try? fm.createDirectory(at: appSupportFolder, withIntermediateDirectories: true)
        }
        guard let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: storeURL, options: [.atomic])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
    }
}

public enum SecretKey {
    public static let openAI = "openai_api_key"
    public static let anthropic = "anthropic_api_key"
}
