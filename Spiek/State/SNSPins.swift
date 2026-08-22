import Foundation
import SpiekCore

/// Where the accepted SNS resolver key lives between launches.
///
/// The Keychain rather than the database: a pin is a trust decision, and moving
/// it silently is exactly the attack it exists to stop. It is stored with the
/// same `…ThisDeviceOnly` protection as the wallet key, so it does not travel
/// to another device in a backup.
actor KeychainSNSPins: SNSPinStore {
    private struct Pin: Codable {
        var signer: String
        var seq: Int
    }

    private let account = "sns-pin"

    func pinnedSigner() async -> String? {
        Keychain.json(Pin.self, for: account)?.signer
    }

    func pinnedSequence() async -> Int {
        Keychain.json(Pin.self, for: account)?.seq ?? 0
    }

    func setPinnedSigner(_ signer: String, seq: Int) async {
        // A rotation only ever moves forward. Refusing to go back stops a
        // replayed old deed chain from restoring a retired key.
        guard seq >= (Keychain.json(Pin.self, for: account)?.seq ?? 0) else { return }
        try? Keychain.setJSON(Pin(signer: signer, seq: seq), for: account)
    }
}
