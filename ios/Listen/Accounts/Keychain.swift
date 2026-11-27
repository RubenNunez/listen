import Foundation
import Security

/// Secrets (API keys, tokens) live in the Keychain of this device only:
/// never in the repository, never synced.
///
/// One exception, measured: a Mac build that is only signed to run locally has
/// no keychain entitlement and every call fails with -34018. Such a build keeps
/// its secrets in a file only the user can read (`usesFile` is true then, and
/// the app says so). A properly signed build never touches that file.
enum Keychain {
    struct Failure: Error, Equatable {
        let status: OSStatus
        var message: String { "Keychain error \(status)" }
    }

    private static let service = "com.meowop.listen.connectors"

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// True when this build cannot use the Keychain and falls back to a file.
    static let usesFile: Bool = {
        #if targetEnvironment(macCatalyst)
        var item = query("probe-\(UUID().uuidString)")
        item[kSecValueData as String] = Data("probe".utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecSuccess { SecItemDelete(item as CFDictionary) }
        return status == errSecMissingEntitlement
        #else
        return false
        #endif
    }()

    static func set(_ secret: String, for account: String) throws {
        if usesFile {
            var all = fileSecrets()
            all[account] = secret
            try writeFile(all)
            return
        }
        SecItemDelete(query(account) as CFDictionary)
        var item = query(account)
        item[kSecValueData as String] = Data(secret.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    static func get(_ account: String) -> String? {
        if usesFile { return fileSecrets()[account] }
        var item = query(account)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func remove(_ account: String) {
        if usesFile {
            var all = fileSecrets()
            all[account] = nil
            try? writeFile(all)
            return
        }
        SecItemDelete(query(account) as CFDictionary)
    }

    // MARK: File fallback for locally signed Mac builds

    private static var file: URL {
        URL.applicationSupportDirectory.appending(path: "Listen/secrets.json")
    }

    private static func fileSecrets() -> [String: String] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private static func writeFile(_ secrets: [String: String]) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(secrets)
        // Readable and writable by the user only.
        guard manager.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw Failure(status: errSecIO)
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
