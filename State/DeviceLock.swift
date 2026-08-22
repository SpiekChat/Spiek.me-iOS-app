import Foundation
import LocalAuthentication

/// The device lock in front of the app.
///
/// The web build encrypts the key with a password of its own. On iOS the key
/// already sits encrypted in the Keychain, so the useful thing to add is the
/// gate in front of it — and `deviceOwnerAuthentication` is the right policy
/// for that: it accepts Face ID or Touch ID *and* falls back to the device
/// passcode, so it works on a phone where biometrics are off or unavailable.
enum DeviceLock {
    enum Availability {
        case faceID
        case touchID
        /// No biometrics enrolled, but a passcode is set.
        case passcodeOnly
        /// No passcode at all — nothing to authenticate against.
        case none

        var label: String {
            switch self {
            case .faceID: return "Face ID"
            case .touchID: return "Touch ID"
            case .passcodeOnly: return "Passcode"
            case .none: return "Not available"
            }
        }

        var isUsable: Bool { self != .none }
    }

    static func availability() -> Availability {
        let context = LAContext()
        var error: NSError?

        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            switch context.biometryType {
            case .faceID: return .faceID
            case .touchID: return .touchID
            default: return .passcodeOnly
            }
        }
        // Biometrics unavailable or not enrolled; a passcode still counts.
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            return .passcodeOnly
        }
        return .none
    }

    enum Failure: Error, LocalizedError {
        case unavailable
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "This device has no passcode or biometrics set up."
            case .cancelled:
                return "Unlock cancelled."
            case let .failed(detail):
                return detail
            }
        }
    }

    /// Prompts once. Returns the authenticated context on success and throws
    /// otherwise, so a caller can tell "declined" from "not set up".
    ///
    /// The returned `LAContext` matters: Keychain reads pass it along via
    /// `kSecUseAuthenticationContext`, so an account item gated on user
    /// presence opens with this one prompt instead of raising a second.
    @discardableResult
    static func authenticate(reason: String) async throws -> LAContext {
        let context = LAContext()
        context.localizedFallbackTitle = ""  // the system offers the passcode itself
        // A just-passed Face ID may satisfy an immediate Keychain read
        // without prompting again — but never anything much later.
        context.touchIDAuthenticationAllowableReuseDuration = 10

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw Failure.unavailable
        }

        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                           localizedReason: reason)
            guard success else { throw Failure.cancelled }
            return context
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .appCancel, .systemCancel:
                throw Failure.cancelled
            default:
                throw Failure.failed(laError.localizedDescription)
            }
        }
    }
}
