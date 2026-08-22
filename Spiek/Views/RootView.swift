import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        ZStack {
            switch model.phase {
            case .loading:
                LaunchView()
            case .onboarding:
                OnboardingView()
            case .ready:
                MainView()
            }

            // In front of everything, so nothing behind it is even readable
            // in the app switcher.
            if model.isLocked && model.phase == .ready {
                LockView()
                    .transition(.opacity)
            }
        }
        .noticeOverlay($model.notice)
        .animation(.easeInOut(duration: 0.25), value: model.phase)
        .animation(.easeInOut(duration: 0.2), value: model.isLocked)
    }
}

struct LaunchView: View {
    var body: some View {
        ZStack {
            Palette.ink.ignoresSafeArea()
            Image("SpiekMark")
                .resizable()
                .scaledToFit()
                .frame(width: 84)
        }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model

    /// `navigationDestination(item:)` needs an Identifiable payload and a chat
    /// id is a plain String, so the presentation is driven by a bool instead.
    private var conversationBinding: Binding<Bool> {
        Binding(
            get: { model.activeChannelId != nil },
            set: { isPresented in
                if !isPresented { model.closeConversation() }
            }
        )
    }

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    switch model.tab {
                    case .chats: ChatListView()
                    case .wallet: WalletView()
                    case .you: YouView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                TabBar(selection: $model.tab, unread: model.totalUnread)
            }
            .background(Palette.surface)
            .navigationDestination(isPresented: conversationBinding) {
                if let channelId = model.activeChannelId {
                    ConversationView(channelId: channelId)
                }
            }
        }
    }
}

struct TabBar: View {
    @Binding var selection: AppModel.Tab
    var unread: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppModel.Tab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 4) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: tab.symbol)
                                .font(.system(size: 20, weight: .regular))
                                .frame(width: 26, height: 22)
                            if tab == .chats, unread > 0 {
                                Circle()
                                    .fill(Palette.primary)
                                    .frame(width: 7, height: 7)
                                    .offset(x: 3, y: -2)
                            }
                        }
                        Text(tab.title)
                            .font(.mono(10))
                            .tracking(1)
                            .textCase(.uppercase)
                    }
                    .foregroundStyle(selection == tab ? Palette.primary : Palette.stamp)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(.white)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.border).frame(height: 1)
        }
    }
}
