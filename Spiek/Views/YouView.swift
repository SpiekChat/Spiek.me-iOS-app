import PhotosUI
import SpiekCore
import SwiftUI
import UIKit

struct YouView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    @State private var name = ""
    @State private var bio = ""
    @State private var draft = Settings()
    /// The picker is presented by the view, never from inside a Menu — see the
    /// composer for what happens when it is not.
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    /// One enum rather than two `.sheet` modifiers on the same view: SwiftUI
    /// keeps a single presentation slot per view, so stacking them is fragile.
    private enum ActiveSheet: String, Identifiable {
        case phrase, wif, names
        var id: String { rawValue }
    }

    @State private var activeSheet: ActiveSheet?
    @State private var confirmSignOut = false
    @State private var confirmWipe = false
    @State private var confirmPublish = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header

                SectionHeader(title: "Profile")
                GroupedList {
                    photoRow
                    SettingsRow(label: "Name") {
                        TextField("what you go by", text: $name)
                            .font(.mono(12))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 150)
                    }
                    SettingsRow(label: "Bio") {
                        TextField("one line", text: $bio)
                            .font(.mono(12))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 150)
                    }
                    // Two separate steps, deliberately. Saving keeps the name on
                    // this phone; publishing writes it to the chain where every
                    // chat can read it. Before this existed, the only way to
                    // keep what you typed was to publish it.
                    SettingsRow(label: "Save on this device") {
                        Button("Save") {
                            Task { await model.saveMyProfile(name: name, bio: bio) }
                        }
                        .font(.sans(13))
                        .foregroundStyle(Palette.primary)
                    }
                    SettingsRow(label: "Publish to the chain") {
                        Button(confirmPublish ? "Sure?" : "Publish") {
                            if confirmPublish {
                                confirmPublish = false
                                Task { await model.publishProfile(name: name, bio: bio) }
                            } else {
                                confirmPublish = true
                                model.show(model.profilePublishWarning)
                                Task {
                                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                                    confirmPublish = false
                                }
                            }
                        }
                        .font(.sans(13))
                        .foregroundStyle(Palette.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Palette.surface)
                        .squareEdge(Palette.border)
                    }
                }

                SectionHeader(title: "Keys")
                GroupedList {
                    SettingsRow(label: "Address") {
                        Button {
                            model.copyToPasteboard(model.address, label: "Address")
                        } label: {
                            Text(Format.truncatedMiddle(model.address, lead: 8, tail: 6))
                                .font(.mono(12))
                                .foregroundStyle(Palette.muted)
                        }
                    }
                    if model.phrase != nil {
                        SettingsRow(label: model.phraseScheme == .legacy
                                    ? "Recovery phrase (legacy)"
                                    : "Recovery phrase (BIP39)") {
                            Button("Show") { Task { await revealPhrase() } }
                                .font(.sans(13))
                                .foregroundStyle(Palette.primary)
                        }
                    }
                    SettingsRow(label: "Private key (WIF)") {
                        Button("Show") { Task { await revealWIF() } }
                            .font(.sans(13))
                            .foregroundStyle(Palette.primary)
                    }
                    SettingsRow(label: "Your SNS & OpNS names") {
                        Button("Show") { activeSheet = .names }
                            .font(.sans(13))
                            .foregroundStyle(Palette.primary)
                    }
                    // The per-conversation safety number lives in the chat
                    // header; what belongs here is your own key, so someone can
                    // check it against what they see on their side.
                    SettingsRow(label: "Public key") {
                        Button {
                            model.copyToPasteboard(model.publicKeyHex, label: "Public key")
                        } label: {
                            Text(Format.truncatedMiddle(model.publicKeyHex, lead: 8, tail: 6))
                                .font(.mono(12))
                                .foregroundStyle(Palette.muted)
                        }
                    }
                }

                // Grouped so the enclosing VStack stays within ViewBuilder's
                // ten-child limit.
                Group {
                SectionHeader(title: "Security")
                GroupedList {
                    SettingsRow(label: "Require \(model.lockAvailability.label) to open") {
                        Toggle("", isOn: Binding(
                            get: { model.settings.requireUnlock },
                            set: { value in Task { await model.setRequireUnlock(value) } }
                        ))
                        .labelsHidden()
                        .tint(Palette.primary)
                        .disabled(!model.lockAvailability.isUsable)
                    }
                    SettingsRow(label: "Notify about new messages") {
                        Toggle("", isOn: Binding(
                            get: { model.settings.notifyOnNewMessages },
                            set: { value in Task { await model.setNotifications(value) } }
                        ))
                        .labelsHidden()
                        .tint(Palette.primary)
                    }
                    SettingsRow(label: "Report a problem") {
                        Button("Email hello@spiek.me") {
                            if let url = model.reportURL() { openURL(url) }
                        }
                        .font(.sans(13))
                        .foregroundStyle(Palette.primary)
                    }
                }

                if !model.blockedSenders.isEmpty {
                    SectionHeader(title: "Blocked")
                    GroupedList {
                        ForEach(model.blockedSenders.sorted(), id: \.self) { sender in
                            SettingsRow(label: model.name(forSender: sender)) {
                                Button("Unblock") {
                                    Task { await model.setBlocked(sender, blocked: false) }
                                }
                                .font(.sans(13))
                                .foregroundStyle(Palette.danger)
                            }
                        }
                    }
                }
                }

                SectionHeader(title: "Network")
                GroupedList {
                    SettingsRow(label: "Mode") {
                        Text(modeLabel)
                            .font(.mono(12))
                            .foregroundStyle(Palette.muted)
                    }
                    SettingsRow(label: "Fee (sat/byte, min 0.1)") {
                        TextField("0.1", value: $draft.feePerByte, format: .number)
                            .keyboardType(.decimalPad)
                            .font(.mono(12))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                    SettingsRow(label: "Dust") {
                        TextField("1", value: $draft.dust, format: .number)
                            .keyboardType(.numberPad)
                            .font(.mono(12))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                    SettingsRow(label: "Sync interval (s)") {
                        TextField("30", value: $draft.pollSeconds, format: .number)
                            .keyboardType(.numberPad)
                            .font(.mono(12))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                    SettingsRow(label: "Media cache (MB)") {
                        TextField("200", value: $draft.mediaLimitMB, format: .number)
                            .keyboardType(.numberPad)
                            .font(.mono(12))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                    // Read-only on purpose. This used to be a number you typed,
                    // which meant every dollar figure in the app was whatever
                    // was last guessed. It is fetched now, once a minute.
                    SettingsRow(label: "BSV price (USD)") {
                        Button {
                            Task { await model.refreshPrice() }
                        } label: {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(priceValue)
                                    .font(.mono(12))
                                    .foregroundStyle(model.price == nil ? Palette.danger : Palette.ink)
                                Text(priceNote)
                                    .font(.mono(10))
                                    .foregroundStyle(Palette.stamp)
                                    .lineLimit(1)
                            }
                        }
                    }
                    SettingsRow(label: "Mirror broadcast to WhatsOnChain") {
                        Toggle("", isOn: $draft.mirrorBroadcast)
                            .labelsHidden()
                            .tint(Palette.primary)
                    }
                }

                if model.settings.mode == .node {
                    SectionHeader(title: "Endpoints")
                    GroupedList {
                        endpointRow("Transaction", text: $draft.getTxURL)
                        endpointRow("Watch address", text: $draft.watchURL)
                        endpointRow("Broadcast", text: $draft.broadcastURL)
                        endpointRow("UTXOs", text: $draft.utxoURL)
                    }
                }

                VStack(spacing: 10) {
                    Button("Save settings") {
                        // The profile fields sit on this screen too, and
                        // "Save settings" is the button people reach for after
                        // typing in any of them.
                        Task {
                            await model.saveMyProfile(name: name, bio: bio)
                            await model.saveSettings(draft)
                        }
                    }
                    .buttonStyle(SolidButtonStyle())

                    Button(confirmSignOut ? "Sure? Tap again" : "Sign out on this device") {
                        if confirmSignOut {
                            Task { await model.signOut() }
                        } else {
                            confirmSignOut = true
                            model.show("Without your recovery phrase there is no way back in.", kind: .error)
                        }
                    }
                    .buttonStyle(OutlineButtonStyle(foreground: confirmSignOut ? Palette.danger : Palette.muted))

                    Button(confirmWipe ? "Wipes key and chats — tap again" : "Forget this device") {
                        if confirmWipe {
                            Task { await model.wipeDevice() }
                        } else {
                            confirmWipe = true
                            Task {
                                try? await Task.sleep(nanoseconds: 4_000_000_000)
                                confirmWipe = false
                            }
                        }
                    }
                    .buttonStyle(OutlineButtonStyle(foreground: confirmWipe ? Palette.danger : Palette.muted))
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 30)
            }
        }
        .background(Palette.surface)
        .onAppear {
            draft = model.settings
            // The fields used to be pure `@State`, so everything typed here
            // vanished the moment the screen was left. They are read back from
            // the stored profile now.
            name = model.myProfile.name ?? ""
            bio = model.myProfile.bio ?? ""
        }
        // Saving clamps the values, so mirror the stored result back into the
        // form instead of leaving a rejected number on screen.
        .onChange(of: model.settings) { _, stored in draft = stored }
        // A profile arriving from the chain — after a restore on a new phone —
        // fills the fields in, but never overwrites something being typed.
        .onChange(of: model.myProfile) { _, stored in
            if name.isEmpty { name = stored.name ?? "" }
            if bio.isEmpty { bio = stored.bio ?? "" }
        }
        // Presented by the view, not from inside a control that dismisses
        // itself. No `photoLibrary:` argument: PHPicker then runs out of
        // process and needs no photo-library permission at all.
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .task(id: photoItem) { await storePickedPhoto() }
        .task { await model.refreshPrice() }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .phrase:
                RevealSheet(title: "Recovery phrase", value: model.phrase ?? "")
            case .wif:
                RevealSheet(title: "Private key", value: model.engine?.recoveryWIF ?? "")
            case .names:
                NamesSheet()
            }
        }
    }

    /// Your own picture. Local to this device and never inscribed — the same
    /// rule as a chat photo, and worth saying out loud on the screen that sets
    /// it, because everything else under Profile does go on the chain.
    private var photoRow: some View {
        HStack(spacing: 16) {
            Avatar(text: Format.initials(name.isEmpty ? nil : name, fallback: model.address),
                   size: 62,
                   dark: true,
                   image: model.myPhoto)

            VStack(alignment: .leading, spacing: 8) {
                Button(model.myPhoto == nil ? "Choose picture" : "Replace picture") {
                    // Cleared first, so picking the same picture twice still
                    // counts as a change.
                    photoItem = nil
                    Task { @MainActor in showPhotoPicker = true }
                }
                .font(.sans(13.5))
                .foregroundStyle(Palette.primary)

                if model.myPhoto != nil {
                    Button("Remove") {
                        Task { await model.setMyPhoto(nil) }
                    }
                    .font(.sans(13.5))
                    .foregroundStyle(Palette.danger)
                }

                Text("This phone only \u{2014} never put on the chain.")
                    .font(.mono(10.5))
                    .foregroundStyle(Palette.stamp)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.hairline).frame(height: 1).padding(.leading, 20)
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Avatar(text: Format.initials(name.isEmpty ? nil : name, fallback: model.address),
                   size: 62,
                   dark: true,
                   image: model.myPhoto)

            VStack(alignment: .leading, spacing: 3) {
                Text(name.isEmpty ? "Unnamed" : name)
                    .font(.display(22, bold: true))
                    .foregroundStyle(Palette.ink)
                Text(model.address)
                    .font(.mono(11))
                    .foregroundStyle(Palette.stamp)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.border).frame(height: 1) }
    }

    private func storePickedPhoto() async {
        guard let photoItem else { return }
        guard let data = try? await photoItem.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            model.show("That picture could not be read.", kind: .error)
            return
        }
        await model.setMyPhoto(image)
    }

    private var priceValue: String {
        guard let price = model.price else { return "unknown" }
        return Format.usdRate(price)
    }

    /// Says where the number came from and how old it is, or why there is none.
    private var priceNote: String {
        if model.price == nil {
            return model.priceError == nil ? "fetching…" : "feed unreachable \u{00B7} tap to retry"
        }
        let age = model.priceAge ?? ""
        // A rate the app has stopped quoting must say so here, or this screen
        // becomes the one place that still presents it as current.
        if !model.priceIsFresh { return "\(age) \u{00B7} too old to use \u{00B7} tap to refresh" }
        if model.priceError != nil { return "WhatsOnChain \u{00B7} \(age) \u{00B7} last try failed" }
        return "WhatsOnChain \u{00B7} \(age) \u{00B7} tap to refresh"
    }

    private var modeLabel: String {
        switch model.settings.mode {
        case .chain: return "blockchain"
        case .node: return "own node"
        case .demo: return "demo"
        case .none: return "—"
        }
    }

    /// Secrets are worth a second gate even once the app is open.
    private func revealPhrase() async {
        guard model.lockAvailability.isUsable else { activeSheet = .phrase; return }
        do {
            try await DeviceLock.authenticate(reason: "Show your recovery phrase")
            activeSheet = .phrase
        } catch DeviceLock.Failure.cancelled {
        } catch {
            model.report(error)
        }
    }

    private func revealWIF() async {
        guard model.lockAvailability.isUsable else { activeSheet = .wif; return }
        do {
            try await DeviceLock.authenticate(reason: "Show your private key")
            activeSheet = .wif
        } catch DeviceLock.Failure.cancelled {
        } catch {
            model.report(error)
        }
    }

    private func endpointRow(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).stampLabel()
            TextField("https://…", text: text)
                .font(.mono(11.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Palette.surface)
                .squareEdge(Palette.hairline)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.hairline).frame(height: 1).padding(.leading, 20)
        }
    }
}
