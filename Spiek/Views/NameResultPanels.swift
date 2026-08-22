import SpiekCore
import SwiftUI

/// What a name lookup answered, shown before anything is written to that
/// address. Shared by the new-chat sheet and the wallet's send sheet so the two
/// cannot drift apart — a payment screen and a chat screen must not describe
/// the same verification differently.
///
/// The two panels are deliberately separate types rather than one with a mode
/// flag: the namespaces prove different things, and saying so precisely is the
/// point of the panel.
struct SNSResultPanel: View {
    let found: SNSResolved
    /// What is about to happen with this address, in the caller's words.
    let consequence: String

    /// Three levels, three colours. A two-way colour would paint a successful
    /// `verify` — signature checked, freshness enforced — in the same red as
    /// `trust`, which checked nothing at all. The filled seal stays exclusive
    /// to `prove`.
    private var tint: Color {
        switch found.assurance {
        case .prove: return Palette.primary
        case .verify: return Palette.accent
        case .trust: return Palette.danger
        }
    }

    /// Derived from the evidence, never hard-coded. A browsing screen resolves
    /// at `verify` and a payment screen at `prove`; a fixed caption would let
    /// the weaker one claim the stronger one's proof.
    private var caption: String {
        switch found.assurance {
        case .prove:
            return "SNS \u{00B7} signature checked against the pinned resolver key, outpoint proved unspent"
        case .verify:
            return "SNS \u{00B7} signature checked against the pinned resolver key \u{00B7} the holder's outpoint was not checked"
        case .trust:
            return "SNS \u{00B7} not checked \u{2014} neither the signature nor the outpoint was verified"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: found.assurance == .prove ? "checkmark.seal.fill" : "checkmark.seal")
                    .font(.system(size: 12))
                    .foregroundStyle(tint)
                Text(caption)
                    .font(.mono(10.5))
                    .foregroundStyle(found.assurance == .trust ? Palette.danger : Palette.stamp)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(found.resolution.name)
                .font(.sans(15, weight: .medium))
                .foregroundStyle(Palette.ink)

            // Derived from the *signed* script. The answer's own
            // `holder_address` field is not covered by the signature and is
            // never what is shown.
            Text(found.address)
                .font(.mono(11))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(consequence)
                .font(.sans(12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)

            if found.fellBackToDomain {
                Text("Mailbox unknown \u{2014} this goes to the holder of \(found.resolution.name).")
                    .font(.sans(12))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(found.warnings) { warning in
                Text(warning.text)
                    .font(.sans(12))
                    .foregroundStyle(warning.severity == .high ? Palette.danger : Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .panelFrame()
    }
}

struct OpNSResultPanel: View {
    let found: OpNSResolver.Resolved
    let consequence: String

    private var settled: Bool {
        found.name.lineageVerified && found.verifiedHolder != nil && found.outpointState == .unspent
    }

    /// Three claims, three kinds of truth — and each one is read back from what
    /// actually happened. A payment resolves with all three enforced; a
    /// browsing screen does not, and must not borrow the payment screen's
    /// wording.
    private var caption: String {
        var parts = ["OpNS"]
        parts.append(found.name.lineageVerified
                     ? "lineage certified by the index"
                     : "lineage NOT yet certified by the index")
        parts.append(found.verifiedHolder != nil
                     ? "holder recomputed from the chain"
                     : "holder NOT recomputed \u{2014} the chain could not be read")
        switch found.outpointState {
        case .unspent: parts.append("outpoint proved unspent by this app")
        case .spent: parts.append("outpoint is SPENT \u{2014} this name has changed hands")
        case .unknown: parts.append("outpoint not confirmed")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "at")
                    .font(.system(size: 12))
                    .foregroundStyle(settled ? Palette.primary : Palette.danger)
                Text(caption)
                    .font(.mono(10.5))
                    .foregroundStyle(settled ? Palette.stamp : Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(found.name.name)
                .font(.sans(15, weight: .medium))
                .foregroundStyle(Palette.ink)

            // Only ever the address read back from the chain.
            if let holder = found.verifiedHolder {
                Text(holder)
                    .font(.mono(11))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Text(consequence)
                .font(.sans(12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)

            if !found.intermediates.isEmpty {
                Text("Shorter names mined from this one (\u{2026}\(found.intermediates.suffix(3).joined(separator: ", "))) are separate names with possibly other owners \u{2014} this is the exact one.")
                    .font(.sans(12))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .panelFrame()
    }
}

private extension View {
    func panelFrame() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Palette.surface)
            .squareEdge(Palette.border)
            .padding(.bottom, 10)
    }
}

/// Whether the panel on screen was looked up for the text now in the field.
///
/// One implementation for both sheets and both namespaces. A resolver's echo of
/// the input is not covered by its signature, so what was asked is remembered
/// locally — and that memory is what decides whether a second tap is a
/// confirmation or a fresh lookup. Two copies of that rule could drift apart,
/// and one of them is on the payment path.
enum NameLookupMatcher {
    static func matches(lookedUp: String?, field: String) -> Bool {
        guard let lookedUp else { return false }
        // `SNS.normalize` and `OpNS.normalize` are the same operation — trim
        // and lowercase — and the OpNS charset is ASCII, so one covers both.
        return SNS.normalize(lookedUp) == SNS.normalize(field)
    }
}
