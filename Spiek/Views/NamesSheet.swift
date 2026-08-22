import SpiekCore
import SwiftUI

/// The names this wallet holds, in two categories.
///
/// Neither list is a verification. `/reverse` and `/owner` are directory
/// listings — they say which names an index believes this address holds, and
/// carry no signature. Tapping a name runs the real check and shows what came
/// back. That distinction is stated on screen rather than left to be inferred.
///
/// Read-only on purpose: no minting, no buying, no listing for sale. That
/// decision has not been taken.
struct NamesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var detail: Detail?

    private struct Detail: Identifiable {
        let name: String
        var result: AppModel.NameDetail?
        var id: String { name }
    }

    var body: some View {
        @Bindable var model = model

        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: "Your names", trailing: nil, onClose: { dismiss() })

                Text("Names held by this wallet's address. The two indexes are asked separately, so one being down does not hide the other. Neither list is signed — tap a name to check it properly.")
                    .font(.sans(13.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 14)

                // A button, not pull-to-refresh. `.refreshable` claims the
                // downward drag at the top of a scroll view — the same gesture
                // that dismisses a sheet — so this screen became a trap: every
                // attempt to swipe it away reloaded the list instead, and there
                // was no other way off it.
                HStack(spacing: 12) {
                    Button("Refresh") { Task { await model.loadMyNames() } }
                        .font(.sans(13))
                        .foregroundStyle(model.myNames.loading ? Palette.stamp : Palette.primary)
                        .disabled(model.myNames.loading)

                    if model.myNames.loading {
                        Text("looking\u{2026}")
                            .font(.mono(11))
                            .foregroundStyle(Palette.stamp)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.bottom, 16)

                snsSection
                opnsSection

                if let detail { detailPanel(detail) }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 24)
        }
        .background(.white)
        .presentationDetents([.large])
        .noticeOverlay($model.notice)
        .task { await model.loadMyNames() }
    }

    // MARK: Sections

    private var snsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "SNS domains")

            if let error = model.myNames.snsError {
                unavailable(error)
            } else if model.myNames.sns.isEmpty {
                // Only once an index has actually answered. Saying "no names"
                // before asking is a claim, not a report.
                if model.myNames.hasLoaded { empty("No SNS names on this address.") }
            } else {
                GroupedList {
                    ForEach(model.myNames.sns, id: \.self) { name in
                        row(name, symbol: "checkmark.seal")
                    }
                }
                if model.myNames.snsTruncated {
                    Text("Only the first \(model.myNames.sns.count) are shown.")
                        .font(.mono(10.5))
                        .foregroundStyle(Palette.stamp)
                        .padding(.top, 6)
                }
            }
        }
        .padding(.bottom, 8)
    }

    private var opnsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "OpNS names")

            if let error = model.myNames.opnsError {
                unavailable(error)
            } else if model.myNames.opns.isEmpty {
                if model.myNames.hasLoaded { empty("No OpNS names on this address.") }
            } else {
                GroupedList {
                    // The @ icon, never the checkmark: that mark belongs to
                    // ORDnet's own inscriptions and putting it on an OpNS row
                    // would devalue it.
                    ForEach(model.myNames.opns, id: \.name) { held in
                        row(held.name,
                            symbol: "at",
                            note: held.ambiguous ? "ambiguous"
                                : (held.lineageVerified ? nil : "lineage not traced yet"))
                    }
                }
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: Pieces

    private func row(_ name: String, symbol: String, note: String? = nil) -> some View {
        Button {
            open(name)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.primary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.sans(14.5))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let note {
                        Text(note)
                            .font(.mono(10))
                            .foregroundStyle(Palette.danger)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.stamp)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(.sans(13))
            .foregroundStyle(Palette.muted)
            .padding(.vertical, 8)
    }

    /// One index being unreachable says nothing about the other, so it is
    /// reported in place rather than as a failure of the whole screen.
    private func unavailable(_ reason: String) -> some View {
        Text(reason)
            .font(.sans(12.5))
            .foregroundStyle(Palette.danger)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8)
    }

    @ViewBuilder
    private func detailPanel(_ detail: Detail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(detail.name)
                    .font(.mono(11))
                    .foregroundStyle(Palette.stamp)
                    .lineLimit(1)
                Spacer()
                Button("Close") { self.detail = nil }
                    .font(.mono(11))
                    .foregroundStyle(Palette.muted)
                    .underline()
            }
            .padding(.bottom, 8)

            switch detail.result {
            case nil:
                Text("Checking…")
                    .font(.mono(12))
                    .foregroundStyle(Palette.stamp)
            case let .sns(found):
                SNSResultPanel(found: found, consequence: Self.consequence)
            case let .opns(found):
                OpNSResultPanel(found: found, consequence: Self.consequence)
            case let .failed(reason):
                Text(reason)
                    .font(.sans(12.5))
                    .foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 10)
    }

    private static let consequence =
        "This is what the resolver answers for this name right now. Nothing is being sent."

    private func open(_ name: String) {
        detail = Detail(name: name)
        Task {
            let result = await model.verify(name: name)
            // The user may have tapped another name meanwhile.
            guard detail?.name == name else { return }
            detail?.result = result
        }
    }
}
