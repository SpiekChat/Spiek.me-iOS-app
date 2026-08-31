import PhotosUI
import SpiekCore
import SwiftUI
import UIKit

struct ConversationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let channelId: String

    /// One enum instead of three separate `.sheet` modifiers. Stacking several
    /// `.sheet`s on the same view is unreliable — SwiftUI keeps one presentation
    /// slot per view, and the later modifiers quietly win.
    private enum ActiveSheet: Identifiable {
        case pay
        case verifyKeys(String)
        case image
        /// Carries the channel, so the sheet cannot open blank if the chat
        /// disappears between tapping and presenting.
        case details(ChannelRecord)

        var id: String {
            switch self {
            case .pay: return "pay"
            case let .verifyKeys(value): return "keys-\(value)"
            case .image: return "image"
            case let .details(channel): return "details-\(channel.channelId)"
            }
        }
    }

    /// Set by the pinned bar; the message list scrolls to it and clears it.
    @State private var jumpTarget: String?

    @State private var activeSheet: ActiveSheet?
    /// Drives the photo picker. It cannot live inside the `Menu` — see the
    /// comment on the attachment button.
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var armDelete = false
    @FocusState private var composerFocused: Bool

    private var channel: ChannelRecord? { model.activeChannel }

    var body: some View {
        VStack(spacing: 0) {
            // Above the list, not inside it: an unsettled message sorts after
            // everything already in a block, so on its own it would sit at the
            // very bottom of the chat.
            if !model.pinnedMessages.isEmpty {
                PinnedMessagesBar(messages: model.pinnedMessages) { message in
                    jumpTarget = message.id
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            messageList

            if model.editingTxid != nil { editHint }
            if let reply = model.replyingTo { replyHint(reply) }

            composer
        }
        .background(Palette.chatBackground)
        .animation(.easeOut(duration: 0.2), value: model.pinnedMessages.count)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { titleView }
            ToolbarItem(placement: .topBarTrailing) { trailingButtons }
        }
        .toolbarBackground(.white, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        // The picker is presented by the view, not by the menu item.
        // No `photoLibrary:` argument on purpose: that would run the picker
        // in-process and trigger a photo-library permission prompt. Left off,
        // PHPicker runs out-of-process and needs no permission at all — the app
        // only ever receives the one image the user picked.
        .photosPicker(isPresented: $showPhotoPicker,
                      selection: $photoItem,
                      matching: .images)
        // Unconditional on purpose: the composer is the only sheet that can
        // coexist with a staged image, so dismissing pay or verify-keys has
        // nothing to clear. Swiping the composer away is a cancel.
        .sheet(item: $activeSheet, onDismiss: { model.cancelPendingImage() }) { sheet in
            switch sheet {
            case .pay:
                PaySheet()
            case let .verifyKeys(value):
                VerifyKeysSheet(fingerprint: value)
            case .image:
                ImageComposerSheet()
            case let .details(channel):
                ChatSettingsSheet(channel: channel)
            }
        }
        // `.task(id:)` rather than `.onChange` + `Task { }`: this one is bound to
        // the view's lifetime, so backing out of the chat while a photo is still
        // loading from iCloud cancels it instead of leaving a full-resolution
        // image stranded on the model.
        .task(id: photoItem) {
            guard let item = photoItem else { return }

            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                model.show("That photo could not be read.", kind: .error)
                return
            }
            model.stageImage(image, data: data)

            // The picker is a presentation of its own. Opening the composer
            // before it has finished dismissing makes UIKit drop one of the
            // two, so wait out the dismissal animation first.
            try? await Task.sleep(nanoseconds: 400_000_000)

            // In that window the person can leave the chat, or open another
            // sheet from the same menu. Neither may be overwritten — replacing a
            // live sheet fires its `onDismiss`, which would clear the very image
            // just staged.
            guard !Task.isCancelled,
                  model.activeChannelId == channelId,
                  activeSheet == nil else {
                model.cancelPendingImage()
                return
            }
            activeSheet = .image
        }
    }

    // MARK: Header

    private var titleView: some View {
        // Tapping the subtitle copies the chat code — the same shortcut the
        // web version offers, and the way back to a code you did not save.
        Button {
            guard let channel, channel.kind != .note else { return }
            // An encrypted one-to-one offers the fingerprint instead: that is
            // the thing worth checking once the chat is running.
            if channel.kind == .dm, model.chatIsEncrypted {
                Task {
                    if let value = await model.keyFingerprint() {
                        activeSheet = .verifyKeys(value)
                    }
                }
            } else {
                model.copyToPasteboard(channel.inviteCode, label: "Chat code")
            }
        } label: {
            VStack(spacing: 1) {
                Text(channel.map { model.displayName(for: $0) } ?? "Chat")
                    .font(.display(16))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.mono(10.5))
                    .foregroundStyle(Palette.stamp)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        // Not `.disabled`, which would dim the title of notes-to-self.
        .allowsHitTesting(channel?.kind != .note)
    }

    private var subtitle: String {
        guard let channel else { return "" }
        switch channel.kind {
        case .note:
            // Notes are encrypted to your own key. Say it, because it is the
            // difference between a private diary and a public one.
            return model.chatIsEncrypted ? "just you · encrypted" : "just you · not encrypted"
        case .group:
            // v1.20: a keyed group is encrypted under the invite key; a
            // keyless one is public. Say which, rather than let the absent
            // lock icon imply either way.
            return channel.groupKey != nil
                ? "encrypted group · everyone with the invite can read"
                : "public group · permanently stored on-chain · tap to copy code"
        case .dm:
            if channel.peerPub == nil { return "waiting for them · tap to copy code" }
            if model.chatIsEncrypted { return "encrypted · tap to verify keys" }
            return "not encrypted · tap to copy code"
        }
    }

    private var trailingButtons: some View {
        HStack(spacing: 14) {
            // Notes-to-self carry the lock too: they encrypt against your own
            // key, and without the icon there is no way to tell whether your
            // private notes are on the chain in the clear.
            if model.chatCanBeEncrypted {
                Button {
                    Task { await model.toggleEncryption() }
                } label: {
                    Image(systemName: model.chatIsEncrypted ? "lock.fill" : "lock.open")
                        .foregroundStyle(model.chatIsEncrypted ? Palette.primary : Palette.stamp)
                        .opacity(model.canEncrypt ? 1 : 0.35)
                }
                .disabled(!model.canEncrypt)
                .accessibilityLabel(model.lockCaption)
            }

            Button {
                if let channel { activeSheet = .details(channel) }
            } label: {
                Image(systemName: "square.and.pencil")
                    .foregroundStyle(Palette.stamp)
            }
            .accessibilityLabel("Chat name and picture")

            // Two-step delete, confirmed in place rather than through a
            // full-width notice: the button itself turns into the question.
            Button {
                if armDelete {
                    Task { await model.deleteActiveChannel() }
                } else {
                    armDelete = true
                    Task {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        withAnimation(.easeOut(duration: 0.2)) { armDelete = false }
                    }
                }
            } label: {
                if armDelete {
                    Text("Remove?")
                        .font(.mono(11))
                        .foregroundStyle(Palette.danger)
                } else {
                    Image(systemName: "trash")
                        .foregroundStyle(Palette.stamp)
                        .accessibilityLabel("Remove chat from this device — the chain keeps its history")
                }
            }
            .animation(.easeOut(duration: 0.2), value: armDelete)
        }
    }

    // MARK: Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.canLoadOlder && model.messages.count >= 20 {
                        Button("Load older messages") {
                            Task { await model.loadOlder() }
                        }
                        .font(.mono(11))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .squareEdge(Palette.border)
                        .padding(.vertical, 10)
                    }

                    ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
                        if shouldShowDivider(at: index) {
                            Text(Format.dayDivider(message.record.time))
                                .stampLabel()
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Palette.surface)
                                .padding(.top, 14)
                                .padding(.bottom, 10)
                        }

                        MessageBubble(
                            message: message,
                            showSender: channel?.kind == .group,
                            onReact: { emoji in Task { await model.react(to: message, emoji: emoji) } },
                            onReply: { model.beginReply(to: message); composerFocused = true },
                            onEdit: { model.beginEditing(message); composerFocused = true },
                            onDelete: { Task { await model.deleteMessage(message) } }
                        )
                        .id(message.id)
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            // v1.20: a tap between the bubbles closes the keyboard too.
            .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
            .onChange(of: model.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: jumpTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(target, anchor: .center) }
                jumpTarget = nil
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private func shouldShowDivider(at index: Int) -> Bool {
        guard index < model.messages.count else { return false }
        guard index > 0 else { return true }
        let calendar = Calendar.current
        let current = Date(timeIntervalSince1970: TimeInterval(model.messages[index].record.time))
        let previous = Date(timeIntervalSince1970: TimeInterval(model.messages[index - 1].record.time))
        return !calendar.isDate(current, inSameDayAs: previous)
    }

    // MARK: Composer

    private var editHint: some View {
        HStack(spacing: 8) {
            Text("editing message")
                .font(.mono(11.5))
                .foregroundStyle(Palette.primary)
            Button("cancel") { model.cancelEditing() }
                .font(.mono(11.5))
                .foregroundStyle(Palette.muted)
                .underline()
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .background(Palette.surface)
        .overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1) }
    }

    private func replyHint(_ reply: ViewMessage) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left")
                .font(.system(size: 11))
                .foregroundStyle(Palette.primary)
            Text("replying to \u{201C}\(reply.text.prefix(40))\u{201D}")
                .font(.mono(11.5))
                .foregroundStyle(Palette.primary)
                .lineLimit(1)
            Button("cancel") { model.cancelReply() }
                .font(.mono(11.5))
                .foregroundStyle(Palette.muted)
                .underline()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .background(Palette.surface)
        .overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1) }
    }

    private var composer: some View {
        @Bindable var model = model

        return HStack(spacing: 9) {
            // A plain Button, NOT a `PhotosPicker`. A PhotosPicker placed inside
            // a Menu draws as a row but does nothing when tapped on a device:
            // the menu tears its presentation down as it dismisses, so the
            // picker never gets to appear. The button only flips a flag; the
            // `.photosPicker` modifier on the view does the presenting.
            Menu {
                Button {
                    // Cleared here rather than after loading: picking the same
                    // photo twice would otherwise be no change at all, and the
                    // second pick would silently do nothing.
                    photoItem = nil
                    // One runloop later, so the flag is not set while the menu
                    // is still tearing itself down.
                    Task { @MainActor in showPhotoPicker = true }
                } label: {
                    Label("Image (1Sat Ordinal)", systemImage: "photo")
                }
                if channel?.kind == .dm {
                    Button {
                        activeSheet = .pay
                    } label: {
                        Label("Send sats", systemImage: "bitcoinsign.circle")
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Palette.body)
                    .frame(width: 36, height: 36)
                    .background(Palette.surface)
                    .squareEdge(Palette.border)
            }

            TextField("Message", text: $model.draft, axis: .vertical)
                .font(.sans(15))
                .foregroundStyle(Palette.body)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Palette.surface)
                .squareEdge(Palette.hairline)
                .focused($composerFocused)
                .submitLabel(.send)

            Button {
                // v1.20: fold the keyboard away on send — `composerFocused`
                // used to stay true forever, so the keyboard never closed.
                composerFocused = false
                Task { await model.sendDraft() }
            } label: {
                Image(systemName: model.editingTxid != nil ? "checkmark" : "arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(canSend ? Palette.primary : Palette.stamp)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.white)
        .overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1) }
    }

    private var canSend: Bool {
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
