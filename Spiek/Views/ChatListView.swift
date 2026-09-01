import SpiekCore
import SwiftUI

struct ChatListView: View {
    /// One enum rather than two `.sheet` modifiers on the same view: SwiftUI
    /// keeps a single presentation slot per view, so stacking them is fragile.
    private enum ActiveSheet: Identifiable {
        case newChat
        case details(ChannelRecord)

        var id: String {
            switch self {
            case .newChat: return "new"
            case let .details(channel): return "details-\(channel.channelId)"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @State private var activeSheet: ActiveSheet?

    var body: some View {
        @Bindable var model = model

        return VStack(spacing: 0) {
            header

            searchField

            if model.visibleChannels.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(model.visibleChannels) { channel in
                        Button {
                            Task { await model.open(channel: channel) }
                        } label: {
                            ChatRow(channel: channel)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.white)
                        .contextMenu {
                            Button {
                                activeSheet = .details(channel)
                            } label: {
                                Label("Name & picture", systemImage: "square.and.pencil")
                            }
                            if channel.kind != .note {
                                Button {
                                    model.copyToPasteboard(channel.inviteCode,
                                                           label: channel.kind == .group ? "Group code" : "Chat code",
                                                           sensitive: channel.kind == .group && channel.groupKey != nil)
                                } label: {
                                    Label("Copy chat code", systemImage: "doc.on.doc")
                                }
                                ShareLink(item: channel.inviteCode) {
                                    Label("Share chat code", systemImage: "square.and.arrow.up")
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(.white)
                .refreshable { await model.refresh() }
            }
        }
        .background(.white)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .newChat:
                NewChatSheet()
            case let .details(channel):
                ChatSettingsSheet(channel: channel)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image("SpiekLogoInk")
                .resizable()
                .scaledToFit()
                .frame(height: 28)

            Spacer(minLength: 4)

            MonoChip(text: "\(Format.sats(model.balance)) sats")

            IconButton(systemName: model.isSyncing ? "arrow.triangle.2.circlepath" : "arrow.clockwise") {
                Task { await model.refresh() }
            }
            .disabled(model.isSyncing)
            .opacity(model.isSyncing ? 0.5 : 1)

            IconButton(systemName: "plus",
                       background: Palette.primary,
                       foreground: .white,
                       border: nil) {
                activeSheet = .newChat
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private var searchField: some View {
        @Bindable var model = model
        return SquareField(placeholder: "Search chats and handles",
                           text: $model.searchQuery,
                           autocapitalization: .never)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text(model.searchQuery.isEmpty ? "No conversations yet." : "Nothing found.")
                .font(.sans(14))
                .foregroundStyle(Palette.muted)
            if model.searchQuery.isEmpty {
                Text("Tap + to open one.")
                    .font(.sans(13))
                    .foregroundStyle(Palette.stamp)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(.white)
    }
}

struct ChatRow: View {
    @Environment(AppModel.self) private var model
    let channel: ChannelRecord

    var body: some View {
        HStack(spacing: 13) {
            Avatar(text: Format.initials(model.displayName(for: channel), fallback: channel.channelId),
                   size: 46,
                   dark: channel.kind == .note,
                   image: model.chatPhoto(for: channel.channelId))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName(for: channel))
                        .font(.sans(15.5, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    if channel.kind == .group {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Palette.stamp)
                    }
                }

                Text(preview)
                    .font(.sans(13.5))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 5) {
                Text(channel.lastTime > 0 ? Format.shortTime(channel.lastTime) : "")
                    .font(.mono(10.5))
                    .foregroundStyle(Palette.stamp)
                if channel.unread > 0 { UnreadBadge(count: channel.unread) }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Painted here rather than only as a row trait, so the long-press
        // context-menu preview lifts on white instead of a transparent card.
        .background(.white)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.hairline).frame(height: 1).padding(.leading, 79)
        }
    }

    private var preview: String {
        if channel.kind == .note {
            return channel.plain ? "Only for you \u{2014} in the clear on the chain."
                                 : "Only for you \u{2014} encrypted on the chain."
        }
        if channel.peerPub == nil && channel.kind == .dm {
            return "Waiting for their first message"
        }
        // v1.20.1: never print a keyed group's invite (= its key) in the list.
        if channel.kind == .group, channel.groupKey != nil {
            return "Encrypted group — share the code from the chat"
        }
        return channel.inviteCode
    }
}
