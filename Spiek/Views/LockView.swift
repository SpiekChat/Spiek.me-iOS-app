import SwiftUI

/// Shown in front of everything when the device lock is on. Nothing here
/// reaches the wallet — the key stays in the Keychain until Face ID, Touch ID
/// or the passcode says otherwise.
struct LockView: View {
    @Environment(AppModel.self) private var model
    @State private var isAuthenticating = false

    var body: some View {
        ZStack {
            Palette.ink.ignoresSafeArea()

            VStack(spacing: 0) {
                Image("SpiekMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 68)
                    .padding(.bottom, 26)

                Text("Locked")
                    .font(.display(30, bold: true))
                    .foregroundStyle(.white)
                    .padding(.bottom, 8)

                Text("This device asks for \(model.lockAvailability.label) before opening Spiek.")
                    .font(.sans(15))
                    .foregroundStyle(Palette.onDark)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 26)

                Button(isAuthenticating ? "Unlocking…" : "Unlock") {
                    Task { await authenticate() }
                }
                .buttonStyle(SolidButtonStyle(background: Palette.soft,
                                              foreground: Palette.ink,
                                              font: .display(15)))
                .disabled(isAuthenticating)
                .frame(maxWidth: 320)
                .padding(.horizontal, 24)
            }
        }
        .task { await authenticate() }
    }

    private func authenticate() async {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        await model.unlock()
    }
}
