import SwiftUI
import SpiekCore

// Trust & Safety sheets (v1.21, P0.2 / P0.3).

private let legalBase = "https://spiek.me"

/// Terms & Community Standards acceptance — blocking before the first post.
struct TermsSheet: View {
    @Environment(AppModel.self) private var model
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Before your first message", trailing: nil)
            Text("Everything you post is a transaction on a public blockchain: it is permanent, it is public unless encrypted, and Spiek cannot delete it for you. Posting means you accept the Terms and the Community Standards, and that you understand child sexual abuse material, threats and illegal content lead to blocking and reporting.")
                .font(.sans(13.5))
                .foregroundStyle(Palette.muted)
                .padding(.bottom, 12)
            HStack(spacing: 10) {
                Link("Terms", destination: URL(string: "\(legalBase)/terms.html")!)
                Link("Community Standards", destination: URL(string: "\(legalBase)/community-standards.html")!)
            }
            .font(.sans(13.5))
            .foregroundStyle(Palette.primary)
            .padding(.bottom, 16)
            HStack(spacing: 10) {
                Button("Not now") { onDismiss() }
                    .buttonStyle(OutlineButtonStyle(foreground: Palette.body))
                Button("I accept (v\(Moderation.termsVersion))") { Task { await model.acceptTerms() } }
                    .buttonStyle(SolidButtonStyle())
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface)
        .interactiveDismissDisabled()
    }
}

/// One specific, contextual warning before the first public-group post or media upload (P0.3).
struct DisclosureSheet: View {
    @Environment(AppModel.self) private var model
    let topic: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: topic == "media" ? "Images are public" : "Public group", trailing: nil)
            Text(topic == "media"
                 ? "An image you send is written to the blockchain in full and in the clear — in every chat kind, encrypted or not. Anyone can retrieve it, forever. Only the pointer in an encrypted chat is hidden."
                 : "This group has no key. Everything posted here is stored on the blockchain in the clear, readable by anyone, permanently. If that is not what you want, create a new (encrypted) group instead.")
                .font(.sans(13.5))
                .foregroundStyle(Palette.muted)
                .padding(.bottom, 16)
            HStack(spacing: 10) {
                Button("Cancel") { model.pendingDisclosure = nil; onDismiss() }
                    .buttonStyle(OutlineButtonStyle(foreground: Palette.body))
                Button("I understand") { Task { await model.confirmDisclosure() } }
                    .buttonStyle(SolidButtonStyle())
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface)
    }
}

/// Report a user, message, media or group — structured bundle, explicit consent for plaintext.
struct ReportSheet: View {
    @Environment(AppModel.self) private var model
    let channelId: String
    let txid: String?
    let sender: String?
    let op: String?
    let plaintext: String?
    let onDismiss: () -> Void

    @State private var category = Moderation.categories.first!.id
    @State private var includeText = false
    @State private var note = ""
    @State private var sending = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: "Report", trailing: nil)
                Text("Sends the channel id, sender hash and transaction id to Spiek's moderation service. Message text goes along only if you tick it. Group keys and your own keys never leave the device.")
                    .font(.sans(13))
                    .foregroundStyle(Palette.muted)
                    .padding(.bottom, 10)
                ForEach(Moderation.categories, id: \.id) { entry in
                    Button {
                        category = entry.id
                    } label: {
                        Text((category == entry.id ? "● " : "○ ") + entry.label)
                            .font(.sans(13.5))
                            .foregroundStyle(category == entry.id ? Palette.primary : Palette.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)
                    }
                }
                if plaintext != nil {
                    Toggle(isOn: $includeText) {
                        Text("Include the message text in the report").font(.sans(13)).foregroundStyle(Palette.body)
                    }
                    .tint(Palette.primary)
                    .padding(.vertical, 8)
                }
                SquareField(placeholder: "Optional note for the moderator", text: $note, multiline: true)
                    .frame(minHeight: 60)
                    .padding(.bottom, 14)
                HStack(spacing: 10) {
                    Button("Cancel") { onDismiss() }
                        .buttonStyle(OutlineButtonStyle(foreground: Palette.body))
                    Button(sending ? "Sending…" : "Send report") {
                        sending = true
                        Task {
                            let ok = await model.report(category: category, channelId: channelId, txid: txid, sender: sender, op: op,
                                                        plaintext: includeText ? plaintext : nil, note: note)
                            sending = false
                            if ok { onDismiss() }
                        }
                    }
                    .buttonStyle(SolidButtonStyle())
                    .disabled(sending)
                }
                let mailBody = "category: \(category)\nchannel: \(channelId)\ntxid: \(txid ?? "-")\nsender: \(sender ?? "-")\nnote: \(note)"
                if let mail = URL(string: "mailto:abuse@spiek.me?subject=\("Spiek report (\(category))".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&body=\(mailBody.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") {
                    Link("Service unreachable? Send by e-mail instead (no receipt).", destination: mail)
                        .font(.sans(12))
                        .foregroundStyle(Palette.primary)
                        .padding(.top, 8)
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.surface)
    }
}
