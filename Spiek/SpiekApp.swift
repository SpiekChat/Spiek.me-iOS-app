import SwiftUI
import UIKit

@main
struct SpiekApp: App {
    @State private var model = AppModel()
    /// Opaque branded cover shown the moment the scene loses focus, so the
    /// app-switcher snapshot shows the mark and never a conversation. This is
    /// a shield, not the lock: the real lock stays on `.background`, because
    /// raising it on `.inactive` would fight the Face ID prompt — which
    /// itself makes the scene inactive.
    @State private var privacyShield = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Typeface.register()
        // The design is light-on-white with an ink accent; a dark-mode variant
        // would need its own palette, so the app pins itself to light.
        UIScrollView.appearance().keyboardDismissMode = .interactive
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.light)
                .tint(Palette.primary)
                .overlay {
                    if privacyShield {
                        LaunchView()
                            .transition(.opacity)
                    }
                }
                .task { await model.bootstrap() }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        privacyShield = false
                        // v1.21 (P0.6): sidecars SQLite recreated meanwhile inherit
                        // the protection class; failure surfaces as a hard error.
                        model.reapplyStorageProtection()
                        guard model.phase == .ready, !model.isLocked else { return }
                        Task {
                            Notifier.clearDelivered()
                            await model.refresh()
                            await model.syncBadge()
                        }
                    case .inactive:
                        privacyShield = true
                    case .background:
                        privacyShield = true
                        // Re-lock on the way out, and leave the badge showing
                        // whatever is still unread.
                        model.lockIfNeeded()
                        Task { await model.syncBadge(announceNew: true) }
                    default:
                        break
                    }
                }
        }
    }
}
