import SpiekCore
import SwiftUI

struct WalletView: View {
    @Environment(AppModel.self) private var model

    /// One enum rather than two `.sheet` modifiers on the same view: SwiftUI
    /// keeps a single presentation slot per view, so stacking them is fragile.
    private enum ActiveSheet: String, Identifiable {
        case receive, send, names
        var id: String { rawValue }
    }

    @State private var activeSheet: ActiveSheet?
    @State private var activity: [MessageRecord] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero
                SectionHeader(title: "Names")
                namesEntry
                SectionHeader(title: "Activity")
                activityList
                runway
            }
        }
        .background(Palette.surface)
        .refreshable { await model.refresh() }
        .task { await loadActivity() }
        .task { await model.loadMyNames() }
        .onChange(of: model.balance) { _, _ in Task { await loadActivity() } }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .receive: ReceiveSheet()
            case .send: SendToAddressSheet()
            case .names: NamesSheet()
            }
        }
    }

    // MARK: Names

    /// The names this address holds, one tap from the wallet.
    ///
    /// This lived only under You → Keys, which is where a key belongs and not
    /// where a name is looked for: a name is what you pay *to*, so the wallet
    /// is the screen it is expected on. It is listed in both places on purpose
    /// — two doors, one room — and the subtitle is read from what the indexes
    /// actually answered rather than assumed.
    private var namesEntry: some View {
        GroupedList {
            Button {
                activeSheet = .names
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: "at")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.primary)
                        .frame(width: 36)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Your SNS & OpNS names")
                            .font(.sans(14.5, weight: .medium))
                            .foregroundStyle(Palette.ink)
                        Text(namesSubtitle)
                            .font(.mono(10.5))
                            .foregroundStyle(Palette.stamp)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 6)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.stamp)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var namesSubtitle: String {
        if model.myNames.loading && !model.myNames.hasLoaded { return "looking…" }
        guard model.myNames.hasLoaded else { return "tap to look them up" }
        // An index that could not be reached is not the same as an address
        // holding nothing, and the row says which of the two it is.
        if model.myNames.isEmpty {
            if model.myNames.snsError != nil || model.myNames.opnsError != nil {
                return "an index could not be reached \u{2014} tap for details"
            }
            return "none on this address"
        }
        var parts: [String] = []
        if !model.myNames.sns.isEmpty {
            parts.append("\(model.myNames.sns.count) SNS")
        }
        if !model.myNames.opns.isEmpty {
            parts.append("\(model.myNames.opns.count) OpNS")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Balance").stampLabel(Palette.accent, size: 10).tracking(1.4)

            Text(Format.sats(model.balance))
                .font(.display(44, bold: true))
                .tracking(-1.3)
                .foregroundStyle(.white)
                .padding(.top, 6)
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            // "sats" alone until a rate has actually been fetched. The old
            // hand-typed rate defaulted to 55 and quoted a euro figure nobody
            // had checked; showing nothing is the honest version of that.
            Text(model.usd(model.balance).map { "sats · \($0)" } ?? "sats")
                .font(.mono(12))
                .foregroundStyle(Palette.monoDark)
                .padding(.bottom, 20)

            HStack(spacing: 10) {
                Button("Send") { activeSheet = .send }
                    .buttonStyle(SolidButtonStyle(background: Palette.soft,
                                                  foreground: Palette.ink,
                                                  font: .display(14.5),
                                                  verticalPadding: 12))
                Button("Receive") { activeSheet = .receive }
                    .buttonStyle(SolidButtonStyle(background: Palette.primary,
                                                  foreground: .white,
                                                  font: .display(14.5),
                                                  verticalPadding: 12))
                if model.settings.mode == .demo {
                    Button("Top up") { Task { await model.topUpDemo() } }
                        .buttonStyle(OutlineButtonStyle(foreground: Palette.soft,
                                                        border: Palette.soft.opacity(0.4),
                                                        background: .clear))
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.ink)
    }

    // MARK: Activity

    @ViewBuilder
    private var activityList: some View {
        if activity.isEmpty {
            Text("No movements yet.")
                .font(.sans(14))
                .foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
        } else {
            GroupedList {
                ForEach(activity) { record in
                    ActivityRow(record: record)
                }
            }
        }
    }

    private var runway: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How far this balance goes")
                .stampLabel()
                .tracking(1.2)

            Text(runwayText)
                .font(.sans(14.5))
                .foregroundStyle(Palette.body2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(.white)
        .squareEdge(Palette.border)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    private var runwayText: String {
        let costPerMessage = max(UInt64(11), UInt64(Double(400) * model.settings.feePerByte) + model.settings.dust)
        guard costPerMessage > 0 else { return "—" }
        let count = model.balance / costPerMessage
        if count == 0 { return "Your balance is too low for a message. Top up through Receive." }
        return "About \(Format.sats(count)) messages, at roughly \(costPerMessage) sats each."
    }

    private func loadActivity() async {
        guard let store = model.engine?.store else { return }
        do {
            var records = [MessageRecord]()
            for channel in model.channels {
                records += try await store.messages(channel: channel.channelId, limit: 40)
            }
            // Bare Wallet → Send payments live in a reserved local-only
            // channel that never appears in the chat list — without this
            // they would move money with no trace anywhere in the app.
            records += try await store.messages(channel: Engine.paymentsChannel, limit: 40)
            activity = records
                .filter { $0.payIn > 0 || ($0.paySats ?? 0) > 0 || $0.payOut > 0 }
                .sorted { $0.sort > $1.sort }
                .prefix(40)
                .map { $0 }
        } catch {
            model.report(error)
        }
    }
}

struct ActivityRow: View {
    @Environment(AppModel.self) private var model
    let record: MessageRecord

    private var incoming: Bool { !record.mine && record.payIn > 0 }

    private var amount: UInt64 {
        let dust = model.settings.dust
        if incoming { return record.payIn > dust ? record.payIn - dust : record.payIn }
        return record.paySats ?? record.payOut
    }

    var body: some View {
        HStack(spacing: 13) {
            Circle()
                .fill(Palette.surface)
                .overlay(Circle().stroke(Palette.border, lineWidth: 1))
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: incoming ? "arrow.down.left" : "arrow.up.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.primary)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(incoming ? "Received" : "Sent")
                    .font(.sans(14.5, weight: .medium))
                    .foregroundStyle(Palette.ink)
                // A bare payment row carries the destination address in
                // `senderAddress` (the row is local-only and `mine`), and
                // the address is what identifies where the money went.
                Text(record.channel == Engine.paymentsChannel
                     ? "\(Format.truncatedMiddle(record.senderAddress, lead: 6, tail: 6)) · \(Format.truncatedMiddle(record.txid, lead: 6, tail: 4))"
                     : Format.truncatedMiddle(record.txid, lead: 10, tail: 8))
                    .font(.mono(10.5))
                    .foregroundStyle(Palette.stamp)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(incoming ? "+" : "−")\(Format.sats(amount))")
                    .font(.mono(13.5))
                    .foregroundStyle(incoming ? Palette.primary : Palette.ink)
                Text(Format.shortTime(record.time))
                    .font(.mono(10))
                    .foregroundStyle(Palette.stamp)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.hairline).frame(height: 1).padding(.leading, 20)
        }
    }
}
