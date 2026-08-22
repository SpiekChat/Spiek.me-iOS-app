import Foundation
import LocalAuthentication
import Security

/// The wallet key is the account. It lives in the keychain rather than in the
/// app's database so that a file-level backup or a stolen container does not
/// hand over funds.
///
/// `ThisDeviceOnly` keeps it out of iCloud Keychain and encrypted backups, which
/// matches the app's promise that the recovery phrase is the only way back in.
///
/// Two protection levels exist, switched by the device-lock toggle:
///
/// - Lock off: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — readable
///   by the app any time after the first unlock since boot.
/// - Lock on: a `SecAccessControl` of `WhenUnlockedThisDeviceOnly` plus
///   `.userPresence` — the keychain itself demands Face ID, Touch ID or the
///   passcode before releasing the item. The lock is then enforced by the
///   keychain and Secure Enclave, not merely by a screen the UI draws in
///   front of the app.
enum Keychain {
    private static let service = "me.spiek.wallet"

    enum Failure: Error, LocalizedError {
        case status(OSStatus)
        case accessControl

        var errorDescription: String? {
            switch self {
            case let .status(code):
                return "Keychain error \(code)."
            case .accessControl:
                return "The access-control policy for the Keychain could not be created."
            }
        }
    }

    /// Where the migration helper parks its copy — see `setProtection`.
    private static func scratchName(_ account: String) -> String { account + ".migration" }

    static func set(_ data: Data, for account: String, requireUserPresence: Bool = false) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        if requireUserPresence {
            var accessError: Unmanaged<CFError>?
            guard let control = SecAccessControlCreateWithFlags(
                kCFAllocatorDefault,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .userPresence,
                &accessError
            ) else {
                throw Failure.accessControl
            }
            attributes[kSecAttrAccessControl as String] = control
        } else {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.status(status) }
    }

    /// Reads an item. `context` carries an already-authenticated `LAContext`
    /// (from `DeviceLock.authenticate`) so an item gated on user presence
    /// opens with the one prompt the user just answered instead of raising a
    /// second; without it, the system shows its own prompt on demand.
    static func data(for account: String, context: LAContext? = nil) -> Data? {
        if let found = copyItem(account, context: context) { return found }
        // A crash in the middle of `setProtection` can leave only the scratch
        // copy. Reading it — rather than declaring the account gone — is what
        // makes the migration safe; the protection level is put right again
        // the next time the lock toggle runs `setProtection`.
        return copyItem(scratchName(account), context: context)
    }

    private static func copyItem(_ account: String, context: LAContext?) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let context { query[kSecUseAuthenticationContext as String] = context }
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    /// Whether an item exists, *without* triggering its authentication UI —
    /// a presence-gated item answers `errSecInteractionNotAllowed`, which is
    /// exactly "it exists but will not open silently". Bootstrap uses this to
    /// decide to show the lock screen before any Face ID prompt can appear.
    static func hasItem(for account: String) -> Bool {
        func exists(_ name: String) -> Bool {
            // `interactionNotAllowed` is the supported way to say "no UI" —
            // the older kSecUseAuthenticationUIFail constant is deprecated.
            let probe = LAContext()
            probe.interactionNotAllowed = true
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: name,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationContext as String: probe,
            ]
            let status = SecItemCopyMatching(query as CFDictionary, nil)
            return status == errSecSuccess || status == errSecInteractionNotAllowed
        }
        return exists(account) || exists(scratchName(account))
    }

    /// Re-stores an item under a different protection level, crash-safe.
    ///
    /// The order is chosen so an intact copy exists at every intermediate
    /// state:
    ///
    /// 1. the bytes are copied to a scratch item under the *new* protection —
    ///    `SecItemAdd` succeeding is the verification;
    /// 2. the real item is rewritten under the new protection (`set` deletes
    ///    and re-adds — the only vulnerable instant lives inside this step);
    /// 3. the scratch is removed.
    ///
    /// A crash inside step 2 leaves only the scratch, which `data(for:)`
    /// falls back to — the account is never lost. A thrown error leaves the
    /// original untouched (step 1 failing) or the scratch in place (step 2
    /// failing), and the caller reports it instead of flipping the lock
    /// setting.
    static func setProtection(userPresence: Bool, for account: String,
                              context: LAContext? = nil) throws {
        guard let existing = data(for: account, context: context) else {
            throw Failure.status(errSecItemNotFound)
        }
        let scratch = scratchName(account)
        try set(existing, for: scratch, requireUserPresence: userPresence)
        try set(existing, for: account, requireUserPresence: userPresence)
        remove(scratch)
    }

    static func remove(_ account: String) {
        func delete(_ name: String) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: name,
            ]
            SecItemDelete(query as CFDictionary)
        }
        delete(account)
        // A leftover migration copy must go with it, or "forget this device"
        // would leave the key behind under another name.
        delete(scratchName(account))
    }

    // MARK: Typed helpers

    static func setJSON<T: Encodable>(_ value: T, for account: String,
                                      requireUserPresence: Bool = false) throws {
        try set(try JSONEncoder().encode(value), for: account,
                requireUserPresence: requireUserPresence)
    }

    static func json<T: Decodable>(_ type: T.Type, for account: String,
                                   context: LAContext? = nil) -> T? {
        guard let data = data(for: account, context: context) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
