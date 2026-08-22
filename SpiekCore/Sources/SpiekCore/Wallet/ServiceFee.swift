import Foundation

/// The operator's service fee, added as one extra P2PKH output on the
/// transactions the user initiates. Hardcoded on purpose: the address is part
/// of the build, not a setting, so it cannot be edited away in the UI.
///
/// The schedule (v1.16.0):
///   - 3 sats per text message
///   - 10 sats per image
///   - 10 sats per payment (in a chat, or straight to an address)
///
/// Protocol overhead — opening a chat, reactions, edits, withdrawals and
/// profile publishes — carries no service fee. To change any of this, change
/// the constants below; every call site reads them from here.
public enum ServiceFee {
    /// Where the fee goes. A mainnet P2PKH address.
    public static let address = "1ATEXPH6FSctbZdAz8MnXCfDpCvDnFrWma"

    public static let messageSats: UInt64 = 3
    public static let imageSats: UInt64 = 10
    public static let paymentSats: UInt64 = 10

    /// Decoded once. Empty only if the address constant above is ever edited
    /// into something that does not pass its Base58Check — in which case no
    /// fee output is added rather than sats being burned to a bad script.
    public static let hash160: [UInt8] = Address.hash160(from: ServiceFee.address) ?? []

    /// What a message transaction owes. A payment (paySats > 0) is charged as
    /// a payment even though it travels as a message record.
    public static func amount(op: SpiekOp, paySats: UInt64) -> UInt64 {
        if paySats > 0 { return paymentSats }
        switch op {
        case .msg: return messageSats
        case .media: return imageSats
        default: return 0
        }
    }

    /// The extra output for a message transaction, or nil when nothing is owed.
    public static func target(op: SpiekOp, paySats: UInt64) -> PayTarget? {
        let sats = amount(op: op, paySats: paySats)
        guard sats > 0, hash160.count == 20 else { return nil }
        return PayTarget(hash: hash160, satoshis: sats)
    }

    /// The extra output for a bare payment (Wallet → Send), or nil if the
    /// address constant is broken.
    public static var paymentTarget: PayTarget? {
        guard hash160.count == 20 else { return nil }
        return PayTarget(hash: hash160, satoshis: paymentSats)
    }
}
