import PhotosUI
import SpiekCore
import SwiftUI
import UIKit

/// Name and photo for a chat, both stored on this device only.
///
/// Nothing here is broadcast, which is exactly why anyone in a chat can set
/// them — not just whoever created it. Two people in the same conversation can
/// each call it whatever they like.
struct ChatSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let channel: ChannelRecord

    @State private var name: String = ""
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var working = false

    var body: some View {
        @Bindable var model = model

        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: "Chat details", trailing: nil)

                Text("The name and picture are kept on this device. Nothing is sent to the chain or to the other side, so what you choose here is yours alone.")
                    .font(.sans(13.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 18)

                photoRow
                    .padding(.bottom, 20)

                Text("Name").stampLabel().padding(.bottom, 5)
                SquareField(placeholder: fallbackName, text: $name)
                    .padding(.bottom, 6)

                Text("Leave it empty to fall back to \u{201C}\(fallbackName)\u{201D}.")
                    .font(.mono(11))
                    .foregroundStyle(Palette.stamp)
                    .padding(.bottom, 20)

                // Grouped so the enclosing VStack stays within ViewBuilder's
                // ten-child limit.
                Group {
                    if channel.kind == .dm, let peer = channel.peerHash {
                        // Local only: hides their messages on this device.
                        // Nothing goes on chain and they are never told.
                        Button(model.isBlocked(peer) ? "Unblock this contact"
                                                     : "Block this contact") {
                            Task { await model.setBlocked(peer, blocked: !model.isBlocked(peer)) }
                        }
                        .buttonStyle(OutlineButtonStyle(
                            foreground: model.isBlocked(peer) ? Palette.body : Palette.danger))
                        .padding(.bottom, 10)
                    }

                    Button("Report a problem") {
                        if let url = model.reportURL(channelId: channel.channelId) {
                            openURL(url)
                        }
                    }
                    .buttonStyle(OutlineButtonStyle(foreground: Palette.body))
                    .padding(.bottom, 20)
                }

                HStack(spacing: 10) {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(OutlineButtonStyle(foreground: Palette.body))
                    Button("Save") {
                        Task {
                            working = true
                            await model.rename(channelId: channel.channelId, to: name)
                            working = false
                            dismiss()
                        }
                    }
                    .buttonStyle(SolidButtonStyle(font: .display(14), verticalPadding: 13))
                    .disabled(working)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 24)
        }
        .background(.white)
        // Taller since the block and report buttons joined; the content
        // scrolls anyway if a smaller phone cannot fit it.
        .presentationDetents([.height(590)])
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .noticeOverlay($model.notice)
        .task(id: photoItem) { await stagePickedPhoto() }
        .onAppear { name = channel.name ?? "" }
    }

    // MARK: Pieces

    private var photoRow: some View {
        HStack(spacing: 16) {
            Avatar(text: Format.initials(name.isEmpty ? fallbackName : name,
                                         fallback: channel.channelId),
                   size: 66,
                   image: model.chatPhoto(for: channel.channelId))

            VStack(alignment: .leading, spacing: 8) {
                Button(model.chatPhoto(for: channel.channelId) == nil ? "Choose photo" : "Replace photo") {
                    // Cleared first, so picking the same photo twice still
                    // counts as a change.
                    photoItem = nil
                    Task { @MainActor in showPhotoPicker = true }
                }
                .font(.sans(13.5))
                .foregroundStyle(Palette.primary)

                if model.chatPhoto(for: channel.channelId) != nil {
                    Button("Remove") {
                        Task { await model.setChatPhoto(nil, for: channel.channelId) }
                    }
                    .font(.sans(13.5))
                    .foregroundStyle(Palette.danger)
                }

                Text("Scaled to 250\u{00D7}250 and squeezed under 20 KB.")
                    .font(.mono(10.5))
                    .foregroundStyle(Palette.stamp)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    /// What the chat is called when no local name is set.
    private var fallbackName: String {
        var stripped = channel
        stripped.name = nil
        return model.displayName(for: stripped)
    }

    private func stagePickedPhoto() async {
        guard let photoItem else { return }
        guard let data = try? await photoItem.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            model.show("That photo could not be read.", kind: .error)
            return
        }
        await model.setChatPhoto(image, for: channel.channelId)
    }
}

/// Messages that have not settled, held at the top of the conversation.
///
/// An unconfirmed message sorts after everything already in a block, so it
/// drops to the very bottom of the chat — nowhere near where it was written.
/// This bar keeps it in sight until it lands.
struct PinnedMessagesBar: View {
    @Environment(AppModel.self) private var model

    let messages: [ViewMessage]
    var onTap: (ViewMessage) -> Void

    /// The one message the bar is actually about: a failure if there is one,
    /// otherwise the oldest that has not landed. Everything shown — icon,
    /// colour, preview, and where tapping goes — follows this single choice,
    /// so the bar can never describe one message and open another.
    private var subject: ViewMessage? {
        messages.first { $0.record.error != nil } ?? messages.first
    }

    var body: some View {
        // Two sibling buttons, not one nested in the other's label: a control
        // inside a Button's label is not hit-tested on its own, so an x drawn
        // there would silently trigger the outer button instead.
        if let subject {
            HStack(spacing: 0) {
                Button {
                    onTap(subject)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: subject.record.error != nil
                              ? "exclamationmark.triangle" : "clock")
                            .font(.system(size: 13))
                            .foregroundStyle(tint)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(headline)
                                .font(.mono(11))
                                .foregroundStyle(tint)
                                .lineLimit(1)
                            Text(preview(subject))
                                .font(.sans(13))
                                .foregroundStyle(Palette.body)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 15)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.easeOut(duration: 0.2)) { model.dismissPin(subject) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.stamp)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide this notice")
            }
            .background(subject.record.error != nil ? Palette.danger.opacity(0.07) : Palette.surface)
            .overlay(alignment: .leading) { Rectangle().fill(tint).frame(width: 3) }
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.border).frame(height: 1) }
        }
    }

    private var tint: Color {
        messages.contains { $0.record.error != nil } ? Palette.danger : Palette.accent
    }

    private var headline: String {
        let failed = messages.filter { $0.record.error != nil }.count
        if failed > 0 {
            return failed == 1 ? "1 message failed \u{00B7} tap to open"
                               : "\(failed) messages failed \u{00B7} tap to open"
        }
        return messages.count == 1
            ? "still waiting for a block \u{00B7} tap to open"
            : "\(messages.count) messages waiting for a block \u{00B7} tap to open"
    }

    private func preview(_ message: ViewMessage) -> String {
        if let error = message.record.error { return error }
        if message.viewOp == .media { return "image" }
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "payment" : text
    }
}
