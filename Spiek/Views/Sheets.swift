import SpiekCore
import SwiftUI

// MARK: - Send sats inside a chat

struct PaySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var amountText = "1000"
    @State private var note = ""
    @State private var sending = false

    private let quickAmounts: [UInt64] = [1_000, 10_000, 25_000, 100_000]

    private var amount: UInt64 {
        UInt64(amountText.filter(\.isNumber)) ?? 0
    }

    private var estimatedFee: UInt64 {
        max(10, UInt64(Double(450) * model.settings.feePerByte))
    }

    /// Compared by subtracting from the balance: adding first would trap on a
    /// UInt64 overflow, and the number pad happily accepts twenty digits.
    private var affordable: Bool {
        let overhead = estimatedFee + model.settings.dust + ServiceFee.paymentSats
        guard amount > 0, model.balance >= overhead else { return false }
        return amount <= model.balance - overhead
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: "Send",
                            trailing: "balance \(Format.sats(model.balance)) sats")

                VStack(spacing: 4) {
                    TextField("0", text: $amountText)
                        .font(.display(34, bold: true))
                        .multilineTextAlignment(.center)
                        .keyboardType(.numberPad)
                        .foregroundStyle(Palette.ink)
                    // Nothing at all rather than a made-up figure when the rate
                    // is not in yet — this is a payment screen.
                    Text(model.usd(amount) ?? "sats")
                        .font(.mono(11.5))
                        .foregroundStyle(Palette.stamp)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .padding(.horizontal, 16)
                .background(Palette.surface)
                .padding(.bottom, 12)

                HStack(spacing: 8) {
                    ForEach(quickAmounts, id: \.self) { value in
                        Button {
                            amountText = String(value)
                        } label: {
                            Text(shortLabel(value))
                                .font(.mono(12))
                                .foregroundStyle(amount == value ? .white : Palette.body)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(amount == value ? Palette.primary : Color.white)
                                .squareEdge(amount == value ? Palette.primary : Palette.border)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 12)

                SquareField(placeholder: "Add a note (optional)", text: $note)
                    .padding(.bottom, 12)

                HStack {
                    Text("Network fee")
                    Spacer()
                    Text("± \(Format.sats(estimatedFee)) sats")
                }
                .font(.mono(11))
                .foregroundStyle(Palette.stamp)
                .padding(.bottom, 6)

                HStack {
                    Text("Service fee")
                    Spacer()
                    Text("\(Format.sats(ServiceFee.paymentSats)) sats")
                }
                .font(.mono(11))
                .foregroundStyle(Palette.stamp)
                .padding(.bottom, 16)

                SlideToConfirm(label: "Slide to confirm →",
                               enabled: affordable && !sending) {
                    Task {
                        sending = true
                        let before = model.notice
                        await model.sendPayment(satoshis: amount, note: note)
                        sending = false
                        // Stay open on failure so the error stays in context.
                        if model.notice == before || model.notice?.kind != .error {
                            dismiss()
                        }
                    }
                }

                if !affordable && amount > 0 {
                    Text("Your balance will not cover this amount plus the fee.")
                        .font(.mono(11.5))
                        .foregroundStyle(Palette.danger)
                        .padding(.top, 10)
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 24)
        }
        .background(.white)
        .presentationDetents([.height(500)])
        .presentationDragIndicator(.hidden)
        .noticeOverlay(noticeBinding)
    }

    private var noticeBinding: Binding<Notice?> {
        @Bindable var model = model
        return $model.notice
    }

    private func shortLabel(_ value: UInt64) -> String {
        value >= 1000 ? "\(value / 1000)k" : "\(value)"
    }
}

// MARK: - Send to a bare address

struct SendToAddressSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var amountText = "1000"
    @State private var working = false
    /// What the shown panel was looked up for. Kept locally: a resolver's echo
    /// of the input is not covered by its signature.
    @State private var lookedUpName: String?

    /// Carries the amount on purpose. This panel is the whole confirmation
    /// surface on this screen, and confirming an address while the number that
    /// decides how much money moves goes unmentioned is not a confirmation.
    private var consequence: String {
        guard let amount else {
            return "Enter a whole number of sats. Nothing has been sent yet."
        }
        return "Tapping again pays \(Format.sats(amount)) sats to this address. Nothing has been sent yet."
    }

    /// Parsed, not filtered. Stripping non-digits turns "1.5" into 15 and
    /// "0.5" into 5 — an amount ten or a hundred times off, with no error.
    /// Capped at the coin supply: the number pad accepts twenty digits, and
    /// an amount near `UInt64.max` would trap the fee arithmetic downstream.
    private var amount: UInt64? {
        let trimmed = amountText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = UInt64(trimmed), value >= 1, value <= Wallet.maximumSats else { return nil }
        return value
    }

    var body: some View {
        @Bindable var model = model

        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: "Send",
                            trailing: "balance \(Format.sats(model.balance)) sats",
                            onClose: { dismiss() })

                Text("Sends coins straight to an address, or to an SNS or OpNS name. No chat is opened and nothing is written to a conversation.")
                    .font(.sans(13.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 14)

                Text("Address or name").stampLabel().padding(.bottom, 5)
                SquareField(placeholder: "1…, name.web3 or a bare OpNS name",
                            text: $address, mono: true, autocapitalization: .never)
                    // Frozen while a lookup is in flight: editing mid-resolve is
                    // what lets a stale panel outlive the text it describes.
                    .disabled(working || model.snsBusy || model.opnsBusy)
                    .padding(.bottom, 14)

                Text("Amount in sats").stampLabel().padding(.bottom, 5)
                SquareField(placeholder: "1000", text: $amountText, mono: true)
                    .keyboardType(.numberPad)
                    .disabled(working)
                    .padding(.bottom, 6)

                Text("Service fee: \(Format.sats(ServiceFee.paymentSats)) sats, on top of the network fee.")
                    .font(.mono(11))
                    .foregroundStyle(Palette.stamp)
                    .padding(.bottom, 14)

                // Gated on the field as well as the model: a lookup that
                // resumes after the text changed would otherwise leave a panel
                // describing an address the field no longer names — and with
                // both namespaces it could show two panels, two addresses, one
                // button.
                if panelMatchesField, let found = model.snsResult {
                    SNSResultPanel(found: found, consequence: consequence)
                }
                if panelMatchesField, let found = model.opnsResult {
                    OpNSResultPanel(found: found, consequence: consequence)
                }

                Button(buttonLabel) { Task { await go() } }
                    .buttonStyle(SolidButtonStyle())
                    .disabled(working || model.snsBusy || model.opnsBusy || address.isEmpty)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 24)
        }
        .background(.white)
        .presentationDetents([.large])
        .noticeOverlay($model.notice)
        .onChange(of: address) { _, _ in clearLookup() }
        // Results outlive this sheet, so a panel from a previous visit would
        // otherwise greet an empty field.
        .onAppear { clearLookup() }
    }

    private var buttonLabel: String {
        // The busy flags come first. `working` covers the whole window in which
        // a lookup runs, so testing it first would label the tap that sends
        // *nothing* as "Sending…" — on a screen whose entire safety property is
        // that the first tap does not send.
        if model.snsBusy || model.opnsBusy { return "Looking up…" }
        if working { return "Sending…" }
        if panelMatchesField, model.snsResult != nil || model.opnsResult != nil {
            return "Confirm & send"
        }
        return "Send"
    }

    /// True when the panel on screen was looked up for the text now in the
    /// field. Both namespaces normalise the same way, so one check covers both.
    private var panelMatchesField: Bool {
        NameLookupMatcher.matches(lookedUp: lookedUpName, field: address)
    }

    private func clearLookup() {
        model.clearSNSResult()
        model.clearOpNSResult()
        lookedUpName = nil
    }

    // MARK: Sending

    private func go() async {
        let typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !working else { return }
        guard let amount else {
            model.show("Enter a whole number of sats — at most the coin supply.", kind: .error)
            return
        }
        working = true
        defer { working = false }

        // Address first. Base58 is a subset of the OpNS character set, so an
        // address also reads as a valid bare name — only the checksum separates
        // them, and the wrong order would refuse every pasted address.
        if Address.isValid(typed) {
            clearLookup()
            if await model.payToAddress(typed, satoshis: amount) { dismiss() }
            return
        }

        if await model.inputLooksLikeSNS(typed) {
            await sendToSNS(typed, satoshis: amount)
            return
        }
        if model.inputLooksLikeOpNS(typed) {
            await sendToOpNS(typed, satoshis: amount)
            return
        }
        model.show("That is not a valid address, SNS name or OpNS name.", kind: .error)
    }

    /// Two taps, and the lookup runs on *both*. The second tap therefore
    /// re-resolves immediately before the transaction is built — a name can be
    /// sold between typing it and confirming it, which is exactly what the
    /// freshness window and the outpoint check exist for.
    private func sendToSNS(_ input: String, satoshis: UInt64) async {
        // One namespace at a time on screen.
        model.clearOpNSResult()
        let seen = model.snsResult
        guard let found = await model.lookUpSNS(input) else { return }

        guard !found.warnings.contains(where: { $0.severity == .high }) else {
            // Clear it, or the panel sits there captioned "tapping again pays
            // this address" for a name that can never be confirmed.
            model.clearSNSResult()
            model.show("That name is written to be misread. Check it character by character, or paste the address instead.",
                       kind: .error)
            return
        }

        guard let seen, panelMatchesField else {
            lookedUpName = input
            return
        }
        guard seen.address == found.address, seen.resolution.name == found.resolution.name else {
            model.show("The verified details of \u{201C}\(found.resolution.name)\u{201D} changed while you were confirming. Nothing was sent \u{2014} check them and tap again.",
                       kind: .error)
            return
        }

        if await model.payToAddress(found.address, satoshis: satoshis) {
            clearLookup()
            dismiss()
        }
    }

    private func sendToOpNS(_ input: String, satoshis: UInt64) async {
        model.clearSNSResult()
        let seen = model.opnsResult
        guard let found = await model.lookUpOpNS(input) else { return }
        guard let payable = found.payableAddress else {
            model.show("The holder of \u{201C}\(found.name.name)\u{201D} could not be confirmed. Nothing was sent.",
                       kind: .error)
            return
        }

        guard let seen, panelMatchesField else {
            lookedUpName = input
            return
        }
        guard seen.name.name == found.name.name,
              seen.verifiedHolder == found.verifiedHolder,
              seen.name.currentTxid == found.name.currentTxid,
              seen.name.currentVout == found.name.currentVout else {
            model.show("The verified details of \u{201C}\(found.name.name)\u{201D} changed while you were confirming. Nothing was sent \u{2014} check them and tap again.",
                       kind: .error)
            return
        }

        if await model.payToAddress(payable, satoshis: satoshis) {
            clearLookup()
            dismiss()
        }
    }
}

// MARK: - New chat

struct NewChatSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// A freshly created channel, held here so the sheet can show its code
    /// instead of vanishing. Without this the code is gone the moment the
    /// chat exists, and it is the one thing the other side needs.
    private struct Created: Identifiable {
        let channelId: String
        let kind: ChannelKind
        /// v1.20: a fresh group's symmetric key, folded into the code.
        var groupKey: String? = nil
        var id: String { channelId }
        var code: String { InviteCode.encode(channelId: channelId, kind: kind, groupKey: groupKey) }
    }

    @State private var name = ""
    @State private var code = ""
    @State private var peerAddress = ""
    @State private var working = false
    @State private var created: Created?
    /// What the shown SNS panel was looked up for. Kept here rather than read
    /// from the answer: `input` is not one of the signed fields, so a resolver
    /// could echo back anything it liked.
    @State private var lookedUpName: String?

    private static let chatConsequence =
        "Opening a chat sends the smallest possible amount to this address, so the other side sees it."


    var body: some View {
        @Bindable var model = model

        // One detent modifier for both states, so switching to the code panel
        // animates the sheet down instead of fighting two modifiers.
        return Group {
            if let created {
                createdView(created)
            } else {
                formView
            }
        }
        .background(.white)
        .presentationDetents(created == nil ? [.large] : [.height(440)])
        // The root overlay sits behind this sheet, so errors raised here need
        // their own copy or they are simply never seen.
        .noticeOverlay($model.notice)
    }

    // MARK: Created

    private func createdView(_ created: Created) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: created.kind == .group ? "Group created" : "Chat created",
                        trailing: nil,
                        onClose: { dismiss() })

            Text(created.kind == .group
                 ? (created.groupKey != nil
                    ? "Share this code with the members — it holds the group key, so everyone with the invite can read the group. It is the only thing they need to join."
                    : "Share this code with the members. It is the only thing they need to join.")
                 : "Send this code to the other person. It is the only thing they need to join.")
                .font(.sans(13.5))
                .foregroundStyle(Palette.muted)
                .padding(.bottom, 14)

            RevealBox(text: created.code)
                .padding(.bottom, 10)

            Text("You can find it back any time under the chat name in the list.")
                .font(.mono(11))
                .foregroundStyle(Palette.stamp)
                .padding(.bottom, 18)

            HStack(spacing: 10) {
                ShareLink(item: created.code) {
                    Text("Share")
                        .font(.sans(14))
                        .foregroundStyle(Palette.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .squareEdge(Palette.border)
                }
                Button("Copy code") {
                    model.copyToPasteboard(created.code, label: "Chat code")
                }
                .buttonStyle(SolidButtonStyle(font: .display(14), verticalPadding: 13))
            }
            .padding(.bottom, 10)

            Button(working ? "Opening…" : "Open the chat") {
                guard !working else { return }
                Task {
                    working = true
                    await model.openChannel(id: created.channelId)
                    dismiss()
                }
            }
            .buttonStyle(OutlineButtonStyle(foreground: Palette.body))
            .disabled(working)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Form

    private var formView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: "New chat", trailing: nil, onClose: { dismiss() })

                Text("Create a chat and share its code — the other person loads it with that code. Nothing else to exchange. A new group is encrypted and its code carries the group key, so everyone with the invite can read; a keyless group code joins a public group, stored on-chain in the clear.")
                    .font(.sans(13.5))
                    .foregroundStyle(Palette.muted)
                    .padding(.bottom, 14)

                Text("Chat name (local only)").stampLabel().padding(.bottom, 5)
                SquareField(placeholder: "e.g. Deal with Bob", text: $name)
                    .padding(.bottom, 12)

                HStack(spacing: 10) {
                    Button("Create chat") { Task { await create(group: false) } }
                        .buttonStyle(SolidButtonStyle(font: .display(14), verticalPadding: 12))
                    Button("Create group") { Task { await create(group: true) } }
                        .buttonStyle(OutlineButtonStyle())
                }
                .disabled(working)
                .padding(.bottom, 22)

                // Grouped so the enclosing VStack stays within ViewBuilder's
                // ten-child limit.
                Group {
                    Text("Load a chat — paste the code you received").stampLabel().padding(.bottom, 5)
                    SquareField(placeholder: "spiek:chat:… or spiek:group:…",
                                text: $code, mono: true, autocapitalization: .never)
                        .padding(.bottom, 10)
                    Button("Load chat") { Task { await load() } }
                        .buttonStyle(OutlineButtonStyle())
                        .disabled(working || code.isEmpty)
                        .padding(.bottom, 22)
                }

                Group {
                    Text("Know their address or SNS name? Open directly").stampLabel().padding(.bottom, 5)
                    SquareField(placeholder: "1…, name.web3 or a bare OpNS name",
                                text: $peerAddress, mono: true, autocapitalization: .never)
                        // Frozen while a lookup runs, like the wallet's field:
                        // editing mid-resolve re-arms the matcher against text
                        // the field no longer shows.
                        .disabled(working || model.snsBusy || model.opnsBusy)
                        .padding(.bottom, 10)

                    // Gated on the field, not just on the model: a lookup that
                    // resumes after the text changed would otherwise leave a
                    // panel describing an address the field no longer names.
                    if panelMatchesField, let found = model.snsResult {
                        SNSResultPanel(found: found, consequence: Self.chatConsequence)
                    }
                    if panelMatchesField, let found = model.opnsResult {
                        OpNSResultPanel(found: found, consequence: Self.chatConsequence)
                    }

                    Button(busyLabel) { Task { await openByAddress() } }
                        .buttonStyle(OutlineButtonStyle())
                        .disabled(working || model.snsBusy || model.opnsBusy || peerAddress.isEmpty)
                }
                .onChange(of: peerAddress) { _, _ in
                    model.clearSNSResult()
                    model.clearOpNSResult()
                    lookedUpName = nil
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 30)
        }
        // `snsResult` outlives this sheet, so a panel from a previous visit
        // would otherwise greet an empty field.
        .onAppear {
            model.clearSNSResult()
            model.clearOpNSResult()
            lookedUpName = nil
        }
    }

    private func create(group: Bool) async {
        guard !working else { return }
        working = true
        defer { working = false }
        let id = group ? await model.newGroup(name: name) : await model.newChat(name: name)
        guard let id else { return }
        // Show the code rather than jumping straight into the empty chat.
        // v1.20: the fresh group's key travels inside the code.
        let key = group ? model.channels.first(where: { $0.channelId == id })?.groupKey : nil
        withAnimation(.easeOut(duration: 0.2)) {
            created = Created(channelId: id, kind: group ? .group : .dm, groupKey: key)
        }
    }

    private func load() async {
        working = true
        defer { working = false }
        if let id = await model.loadInvite(code: code) {
            await model.openChannel(id: id)
            dismiss()
        }
    }

    private func openByAddress() async {
        let trimmed = peerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !working else { return }
        working = true
        defer { working = false }

        // An SNS name has a dot and a known extension. A bare name without one
        // belongs to a different service and must never be sent here. This can
        // fetch the extension list, so the button stays disabled throughout.
        if await model.inputLooksLikeSNS(trimmed) {
            await openBySNS(trimmed)
            return
        }

        // Address first. Base58 is a subset of the OpNS character set, so an
        // address also reads as a valid bare name — the checksum is the only
        // thing that separates them, and getting the order wrong here would
        // answer every pasted address with "that looks like an OpNS name".
        if Address.isValid(trimmed) {
            if let id = await model.openByAddress(trimmed) {
                await model.openChannel(id: id)
                dismiss()
            }
            return
        }

        // A bare name is OpNS: a separate namespace with its own index.
        if model.inputLooksLikeOpNS(trimmed) {
            await openByOpNS(trimmed)
            return
        }

        model.show("That is not a valid address, SNS name or OpNS name.", kind: .error)
    }

    private var busyLabel: String {
        if model.snsBusy || model.opnsBusy { return "Looking up…" }
        if panelMatchesField, model.snsResult != nil || model.opnsResult != nil {
            return "Confirm & open"
        }
        return "Open"
    }

    private var panelMatchesField: Bool {
        matchesLookup(peerAddress.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Two taps for an SNS name, on purpose. The first shows what the resolver
    /// answered — the name, and the address derived from its *signed* script —
    /// and only the second opens the chat. A `high` look-alike warning means
    /// the name is built to be misread, so there is no one-tap path past it.
    /// Two taps, and the lookup runs on *both*. The second tap therefore
    /// re-resolves immediately before anything is written to that address — a
    /// name can be sold between typing it and confirming it, which is exactly
    /// what the freshness window and the outpoint check exist for. Opening a
    /// chat binds both a dust output *and* the chat identity to the address, so
    /// it gets the same treatment as a payment.
    private func openBySNS(_ input: String) async {
        model.clearOpNSResult()
        let seen = model.snsResult
        guard let found = await model.lookUpSNS(input) else { return }

        // A name built to be misread has no confirm path at all here. Copying
        // the address across is the honest way past it.
        guard !found.warnings.contains(where: { $0.severity == .high }) else {
            model.clearSNSResult()
            model.show("That name is written to be misread. Check it character by character, or paste the address instead.",
                       kind: .error)
            return
        }

        guard let seen, matchesLookup(input) else {
            lookedUpName = input
            return
        }
        guard seen.address == found.address,
              seen.resolution.name == found.resolution.name else {
            model.show("The verified details of \u{201C}\(found.resolution.name)\u{201D} changed while you were confirming. Nothing was opened \u{2014} check them and tap again.",
                       kind: .error)
            return
        }

        await open(address: found.address, named: found.resolution.name)
    }

    private func openByOpNS(_ input: String) async {
        model.clearSNSResult()
        let seen = model.opnsResult
        guard let found = await model.lookUpOpNS(input) else { return }
        guard let payable = found.payableAddress else {
            model.show("The holder of \u{201C}\(found.name.name)\u{201D} could not be confirmed. Nothing was opened.",
                       kind: .error)
            return
        }

        guard let seen, matchesLookup(input) else {
            lookedUpName = input
            return
        }
        guard seen.name.name == found.name.name,
              seen.verifiedHolder == found.verifiedHolder,
              seen.name.currentTxid == found.name.currentTxid,
              seen.name.currentVout == found.name.currentVout else {
            model.show("The verified details of \u{201C}\(found.name.name)\u{201D} changed while you were confirming. Nothing was opened \u{2014} check them and tap again.",
                       kind: .error)
            return
        }

        await open(address: payable, named: found.name.name)
    }

    /// True when the panel on screen was looked up for the text now in the
    /// field. The resolver's echo of the input is not signed, so what was asked
    /// is remembered here instead.
    private func matchesLookup(_ input: String) -> Bool {
        NameLookupMatcher.matches(lookedUp: lookedUpName, field: input)
    }

    private func open(address: String, named name: String) async {
        guard let id = await model.openByAddress(address) else { return }
        // The resolved name becomes the local chat label, like any other here.
        if let channel = model.channels.first(where: { $0.channelId == id }),
           channel.name?.isEmpty ?? true {
            await model.rename(channelId: channel.channelId, to: name)
        }
        model.clearSNSResult()
        model.clearOpNSResult()
        await model.openChannel(id: id)
        dismiss()
    }
}

// MARK: - Receive

struct ReceiveSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Receive", trailing: nil)

            Text("This address is your inbox and your balance. Share it freely.")
                .font(.sans(13.5))
                .foregroundStyle(Palette.muted)
                .padding(.bottom, 14)

            QRCodeView(text: model.address, size: 170)
                .padding(.bottom, 12)

            RevealBox(text: model.address)
                .padding(.bottom, 18)

            HStack(spacing: 10) {
                Button("Close") { dismiss() }
                    .buttonStyle(OutlineButtonStyle(foreground: Palette.body))
                Button("Copy") {
                    model.copyToPasteboard(model.address, label: "Address")
                    dismiss()
                }
                .buttonStyle(SolidButtonStyle(font: .display(14), verticalPadding: 13))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 24)
        .background(.white)
        .presentationDetents([.height(560)])
        .noticeOverlay(noticeBinding)
    }

    private var noticeBinding: Binding<Notice?> {
        @Bindable var model = model
        return $model.notice
    }
}

// MARK: - Reveal a secret

struct RevealSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let title: String
    let value: String

    @State private var revealed = false
    @State private var showQR = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: title, trailing: nil)

            Text("For your eyes only. Whoever holds this, is you.")
                .font(.sans(13.5))
                .foregroundStyle(Palette.muted)
                .padding(.bottom, 14)

            if revealed {
                if showQR {
                    QRCodeView(text: value, size: 160).padding(.bottom, 10)
                }
                RevealBox(text: value).padding(.bottom, 12)
                Button(showQR ? "Hide QR" : "Show QR") { showQR.toggle() }
                    .font(.mono(11.5))
                    .foregroundStyle(Palette.primary)
                    .padding(.bottom, 14)
            } else {
                Button("Show") { revealed = true }
                    .buttonStyle(OutlineButtonStyle())
                    .padding(.bottom, 18)
            }

            HStack(spacing: 10) {
                Button("Close") { dismiss() }
                    .buttonStyle(OutlineButtonStyle(foreground: Palette.body))
                Button("Copy") {
                    // This sheet only ever shows secrets — the phrase or the
                    // WIF key — so the copy is local-only and short-lived.
                    model.copyToPasteboard(value, label: title, sensitive: true)
                    dismiss()
                }
                .buttonStyle(SolidButtonStyle(font: .display(14), verticalPadding: 13))
                .disabled(!revealed)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 24)
        .background(.white)
        .presentationDetents([.height(revealed && showQR ? 620 : 400)])
        .noticeOverlay(noticeBinding)
    }

    private var noticeBinding: Binding<Notice?> {
        @Bindable var model = model
        return $model.notice
    }
}
