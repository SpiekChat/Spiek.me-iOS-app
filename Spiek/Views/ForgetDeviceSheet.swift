import SwiftUI
import SpiekCore

/// P0.8 (v1.21): "Forget this device" is not an ordinary delete button. It
/// re-authenticates, makes the person confirm the recovery phrase is written
/// down, shows the balance and address when there are funds and demands a
/// typed confirmation for them, and is explicit that nothing on the chain
/// disappears — only this device forgets. The flow itself never signs or
/// broadcasts anything.
struct ForgetDeviceSheet: View {
    @Environment(AppModel.self) private var model
    let onDismiss: () -> Void

    @State private var phraseSaved = false
    @State private var typed = ""
    @State private var working = false

    private var hasFunds: Bool { model.balance > 0 && model.settings.mode != .demo }
    private var typedOk: Bool { !hasFunds || typed.trimmingCharacters(in: .whitespaces).uppercased() == "FORGET" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Forget this device", trailing: nil)

            Text("This removes your key, chats, caches and settings from this device. Your identity, messages and coins stay on the blockchain exactly as they are — they are not deleted, and they cannot be. Without your recovery phrase you will not get back in.")
                .font(.sans(13.5))
                .foregroundStyle(Palette.muted)
                .padding(.bottom, 14)

            if hasFunds {
                VStack(alignment: .leading, spacing: 4) {
                    Text("This wallet still holds \(Format.sats(model.balance)) sats")
                        .font(.sans(14, weight: .semibold))
                        .foregroundStyle(Palette.danger)
                    Text(model.address)
                        .font(.mono(11))
                        .foregroundStyle(Palette.stamp)
                        .textSelection(.enabled)
                    Text("The coins are not lost by forgetting — but only the recovery phrase brings them back. Type FORGET to continue.")
                        .font(.sans(12.5))
                        .foregroundStyle(Palette.muted)
                }
                .padding(.bottom, 12)
                SquareField(placeholder: "FORGET", text: $typed, mono: true, autocapitalization: .characters)
                    .padding(.bottom, 12)
            }

            Toggle(isOn: $phraseSaved) {
                Text("I have my recovery phrase written down and can restore this account.")
                    .font(.sans(13))
                    .foregroundStyle(Palette.body)
            }
            .tint(Palette.primary)
            .padding(.bottom, 16)

            HStack(spacing: 10) {
                Button("Cancel") { onDismiss() }
                    .buttonStyle(OutlineButtonStyle(foreground: Palette.body))
                Button(working ? "Forgetting…" : "Forget this device") {
                    working = true
                    Task {
                        // Re-authentication first: this is a destructive local
                        // action and must never run from a stray tap.
                        do { _ = try await DeviceLock.authenticate(reason: "Confirm forgetting this device") }
                        catch {
                            working = false
                            model.show("Authentication failed — nothing was removed.", kind: .error)
                            return
                        }
                        await model.wipeDevice()
                        onDismiss()
                    }
                }
                .buttonStyle(SolidButtonStyle())
                .disabled(!phraseSaved || !typedOk || working)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface)
    }
}
