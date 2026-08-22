import SpiekCore
import SwiftUI
import UIKit

/// The two keys in a conversation, rendered as five groups to read aloud.
struct VerifyKeysSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let fingerprint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Verify keys", trailing: nil)

            Text("Compare these five groups with the other person over another channel — a call, or in person. If they match on both sides, nobody is sitting in between.")
                .font(.sans(13.5))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 16)

            Text(fingerprint)
                .font(.mono(17, medium: true))
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(Palette.surface)
                .squareEdge(Palette.border)
                .padding(.bottom, 18)

            HStack(spacing: 10) {
                Button("Close") { dismiss() }
                    .buttonStyle(OutlineButtonStyle(foreground: Palette.body))
                Button("Copy") {
                    model.copyToPasteboard(fingerprint, label: "Fingerprint")
                    dismiss()
                }
                .buttonStyle(SolidButtonStyle(font: .display(14), verticalPadding: 13))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 24)
        .background(.white)
        .presentationDetents([.height(380)])
        .noticeOverlay(noticeBinding)
    }

    private var noticeBinding: Binding<Notice?> {
        @Bindable var model = model
        return $model.notice
    }
}

/// Tuning an image before it costs anything: every byte is inscribed on chain,
/// so size is money.
struct ImageComposerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var rendered: Data?
    @State private var sending = false

    private var pending: AppModel.PendingImage? { model.pendingImage }

    var body: some View {
        @Bindable var model = model

        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: "Send image", trailing: nil, onClose: { dismiss() })

                Text("Inscribed on chain as a 1Sat Ordinal — smaller is cheaper, and it goes to the other person's wallet.")
                    .font(.sans(13.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 12)

                if let image = pending?.original {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 200)
                        .background(Palette.surface)
                        .squareEdge(Palette.hairline)
                        .padding(.bottom, 6)
                }

                Text(statsLine)
                    .font(.mono(11))
                    .foregroundStyle(overBudget ? Palette.danger : Palette.stamp)
                    .padding(.bottom, 14)

                if let binding = model.pendingImage != nil ? $model.pendingImage : nil {
                    controls(binding)
                }

                HStack(spacing: 10) {
                    Button("Cancel") {
                        model.cancelPendingImage()
                        dismiss()
                    }
                    .buttonStyle(OutlineButtonStyle(foreground: Palette.body))

                    Button(sending ? "Inscribing…" : "Inscribe & send") {
                        Task {
                            sending = true
                            await model.sendPendingImage()
                            sending = false
                            if model.pendingImage == nil { dismiss() }
                        }
                    }
                    .buttonStyle(SolidButtonStyle(font: .display(14), verticalPadding: 13))
                    .disabled(sending || overBudget || rendered == nil)
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 24)
        }
        .background(.white)
        .presentationDetents([.large])
        .noticeOverlay($model.notice)
        // Debounced: dragging the quality slider changes `renderKey` on every
        // frame, and each render is a full JPEG encode. The task is cancelled
        // when the key changes again, so only the value you settle on is encoded.
        .task(id: renderKey) {
            if rendered != nil {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if Task.isCancelled { return }
            }
            refresh()
        }
    }

    // MARK: Controls

    @ViewBuilder
    private func controls(_ pending: Binding<AppModel.PendingImage?>) -> some View {
        Text("Max size").stampLabel().padding(.bottom, 5)
        HStack(spacing: 8) {
            ForEach(AppModel.PendingImage.dimensionChoices, id: \.self) { choice in
                Button {
                    pending.wrappedValue?.maxDimension = choice
                } label: {
                    Text(choice == 0 ? "original" : "\(Int(choice))px")
                        .font(.mono(12))
                        .foregroundStyle(isSelected(choice) ? .white : Palette.body)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(isSelected(choice) ? Palette.primary : Color.white)
                        .squareEdge(isSelected(choice) ? Palette.primary : Palette.border)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 14)
        .disabled(pending.wrappedValue?.keepOriginal == true)
        .opacity(pending.wrappedValue?.keepOriginal == true ? 0.4 : 1)

        HStack {
            Text("Quality").stampLabel()
            Spacer()
            Text("\(Int((pending.wrappedValue?.quality ?? 0.8) * 100))%")
                .font(.mono(11))
                .foregroundStyle(Palette.stamp)
        }
        .padding(.bottom, 2)

        Slider(value: Binding(
            get: { pending.wrappedValue?.quality ?? 0.8 },
            set: { pending.wrappedValue?.quality = $0 }
        ), in: 0.3...0.95)
        .tint(Palette.primary)
        .disabled(pending.wrappedValue?.keepOriginal == true)
        .padding(.bottom, 10)

        Button {
            pending.wrappedValue?.keepOriginal.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: pending.wrappedValue?.keepOriginal == true
                      ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.primary)
                Text("keep the original file (no compression)")
                    .font(.sans(13))
                    .foregroundStyle(Palette.muted)
            }
        }
        .buttonStyle(.plain)
        .padding(.bottom, 14)

        Text("Caption (optional)").stampLabel().padding(.bottom, 5)
        SquareField(placeholder: "", text: Binding(
            get: { pending.wrappedValue?.caption ?? "" },
            set: { pending.wrappedValue?.caption = $0 }
        ))
        .padding(.bottom, 4)
    }

    // MARK: Derived

    private func isSelected(_ choice: CGFloat) -> Bool {
        pending?.maxDimension == choice
    }

    /// Recomputed whenever any knob moves.
    private var renderKey: String {
        guard let pending else { return "" }
        return "\(pending.maxDimension)-\(pending.quality)-\(pending.keepOriginal)"
    }

    private var overBudget: Bool {
        (rendered?.count ?? 0) > Media.maximumBytes
    }

    private var statsLine: String {
        guard let rendered else { return "measuring…" }
        let kilobytes = Double(rendered.count) / 1024
        let size = kilobytes > 1024
            ? String(format: "%.1f MB", kilobytes / 1024)
            : String(format: "%.0f KB", kilobytes)
        if overBudget { return "\(size) — larger than 5 MB, compress further" }
        // Fee from the size we already rendered — asking the model to render
        // again would re-encode the JPEG on every frame of the slider.
        return "\(size) · about \(Format.sats(model.pendingImageFee(byteCount: rendered.count))) sats to inscribe · + \(Format.sats(ServiceFee.imageSats)) sats service fee"
    }

    private func refresh() {
        rendered = model.renderPendingImage()
    }
}
