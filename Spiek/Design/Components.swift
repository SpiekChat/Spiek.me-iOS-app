import SwiftUI
import UIKit

// MARK: - Inline notice

/// The app never uses system alerts for errors — notices slide in at the top
/// and fade out, exactly like the web version's message bar.
struct Notice: Equatable, Identifiable {
    enum Kind { case error, info }

    let id = UUID()
    var text: String
    var kind: Kind

    static func == (lhs: Notice, rhs: Notice) -> Bool { lhs.id == rhs.id }
}

struct NoticeBar: View {
    let notice: Notice

    var body: some View {
        // The accent stripe is an overlay rather than a sibling in an HStack:
        // as a sibling it has no intrinsic height and stretches the bar to
        // fill whatever space the overlay is offered — the whole screen.
        Text(notice.text)
            .font(.mono(13))
            .foregroundStyle(notice.kind == .error ? Palette.dangerOnDark : Palette.soft)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 11)
            .padding(.leading, 15)
            .padding(.trailing, 15)
            .background(Palette.ink)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(notice.kind == .error ? Palette.danger : Palette.accent)
                    .frame(width: 3)
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 16)
            .shadow(color: Palette.ink.opacity(0.25), radius: 12, y: 4)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

private struct NoticeOverlay: ViewModifier {
    @Binding var notice: Notice?

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let notice {
                NoticeBar(notice: notice)
                    .padding(.top, 8)
                    // Keyed on the notice's id: replacing one notice with
                    // another restarts the timer instead of leaving the new
                    // one stuck on screen.
                    .task(id: notice.id) {
                        try? await Task.sleep(nanoseconds: 6_000_000_000)
                        guard !Task.isCancelled, self.notice?.id == notice.id else { return }
                        withAnimation(.easeOut(duration: 0.25)) { self.notice = nil }
                    }
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.2)) { self.notice = nil }
                    }
            }
        }
        .animation(.easeOut(duration: 0.25), value: notice)
    }
}

extension View {
    func noticeOverlay(_ notice: Binding<Notice?>) -> some View {
        modifier(NoticeOverlay(notice: notice))
    }
}

// MARK: - Buttons

struct SolidButtonStyle: ButtonStyle {
    var background: Color = Palette.ink
    var foreground: Color = .white
    var font: Font = .display(15)
    var verticalPadding: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, verticalPadding)
            .background(configuration.isPressed ? background.opacity(0.82) : background)
            .contentShape(Rectangle())
    }
}

struct OutlineButtonStyle: ButtonStyle {
    var foreground: Color = Palette.primary
    var border: Color = Palette.border
    var background: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.sans(14))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(configuration.isPressed ? Palette.surface : background)
            .squareEdge(border)
            .contentShape(Rectangle())
    }
}

/// Square icon button — the recurring 34/36/40pt control in the design.
struct IconButton: View {
    let systemName: String
    var size: CGFloat = 34
    var background: Color = Palette.surface
    var foreground: Color = Palette.primary
    var border: Color? = Palette.border
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.44, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background(background)
                .overlay {
                    if let border { Rectangle().stroke(border, lineWidth: 1) }
                }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Fields

/// Square-cornered text field matching the web app's inputs.
struct SquareField: View {
    var placeholder: String
    @Binding var text: String
    var mono: Bool = false
    var multiline: Bool = false
    var autocapitalization: TextInputAutocapitalization = .sentences

    var body: some View {
        Group {
            if multiline {
                TextEditor(text: $text)
                    .font(mono ? .mono(12.5) : .sans(14))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 84)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(placeholder)
                                .font(mono ? .mono(12.5) : .sans(14))
                                .foregroundStyle(Palette.stamp)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 14)
                                .allowsHitTesting(false)
                        }
                    }
            } else {
                TextField(placeholder, text: $text)
                    .font(mono ? .mono(12.5) : .sans(14))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
            }
        }
        .foregroundStyle(Palette.body)
        .background(Palette.surface)
        .squareEdge(Palette.hairline)
        .textInputAutocapitalization(autocapitalization)
        .autocorrectionDisabled(mono)
    }
}

// MARK: - Avatar

struct Avatar: View {
    var text: String
    var size: CGFloat = 46
    var dark: Bool = false
    /// A photo set for this chat on this device; falls back to the initials.
    var image: UIImage? = nil

    var body: some View {
        Circle()
            .fill(dark ? Palette.ink : Palette.soft)
            .frame(width: size, height: size)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(Circle())
                } else {
                    Text(text)
                        .font(.display(size * 0.33))
                        .foregroundStyle(dark ? Palette.soft : Palette.ink)
                }
            }
    }
}

// MARK: - Small pieces

struct MonoChip: View {
    var text: String
    var foreground: Color = Palette.primary

    var body: some View {
        Text(text)
            .font(.mono(11.5))
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Palette.surface)
            .squareEdge(Palette.border)
    }
}

struct UnreadBadge: View {
    var count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.mono(10.5))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 1.5)
            .background(Palette.primary)
    }
}

struct SectionHeader: View {
    var title: String

    var body: some View {
        Text(title)
            .stampLabel()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 6)
    }
}

/// The white, hairline-separated group used by the wallet and settings screens.
struct GroupedList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(.white)
            .overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.border).frame(height: 1) }
    }
}

struct SettingsRow<Trailing: View>: View {
    var label: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.sans(14.5))
                .foregroundStyle(Palette.ink)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .frame(minHeight: 48)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.hairline).frame(height: 1).padding(.leading, 20)
        }
    }
}

/// Reusable "hold and drag to confirm" control — the payment gesture.
struct SlideToConfirm: View {
    var label: String
    var confirmedLabel: String = "Sending…"
    var enabled: Bool = true
    var action: () -> Void

    @State private var offset: CGFloat = 0
    @State private var completed = false

    private let knobSize: CGFloat = 46
    private let trackHeight: CGFloat = 54

    var body: some View {
        GeometryReader { geometry in
            let travel = max(0, geometry.size.width - knobSize - 8)

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(completed ? Palette.primary : Palette.ink)

                Text(completed ? confirmedLabel : label)
                    .font(.sans(14.5, weight: .medium))
                    .foregroundStyle(Palette.onDark)
                    .frame(maxWidth: .infinity)
                    .opacity(1 - Double(offset / max(travel, 1)) * 0.9)

                Rectangle()
                    .fill(Palette.soft)
                    .frame(width: knobSize, height: knobSize)
                    .overlay {
                        Image(systemName: completed ? "checkmark" : "arrow.right")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                    }
                    .offset(x: offset + 4)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                guard enabled, !completed else { return }
                                offset = min(max(0, value.translation.width), travel)
                            }
                            .onEnded { _ in
                                guard enabled, !completed else { return }
                                if offset > travel * 0.85 {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        offset = travel
                                        completed = true
                                    }
                                    action()
                                } else {
                                    withAnimation(.spring(duration: 0.3)) { offset = 0 }
                                }
                            }
                    )
            }
        }
        .frame(height: trackHeight)
        .opacity(enabled ? 1 : 0.45)
        .onChange(of: enabled) { _, isEnabled in
            if isEnabled { reset() }
        }
    }

    func reset() {
        offset = 0
        completed = false
    }
}

// MARK: - Sheet chrome

struct SheetHeader: View {
    var title: String
    var trailing: String?
    /// A way out that does not depend on the swipe.
    ///
    /// These sheets are dismissed by dragging them down, which is fine until
    /// something else claims that drag. A `.refreshable` scroll view swallows
    /// it at the top of its content and turns the gesture into a reload — and
    /// then there is no way off the screen at all. Any sheet whose content
    /// scrolls should pass this.
    var onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Palette.border)
                .frame(width: 42, height: 4)
                .clipShape(Capsule())
                .padding(.top, 6)
                .padding(.bottom, 18)

            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.display(20))
                    .foregroundStyle(Palette.ink)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.mono(11))
                        .foregroundStyle(Palette.stamp)
                }
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                            .padding(8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                    .padding(.leading, 8)
                }
            }
            .padding(.bottom, 16)
        }
    }
}

/// Copy-to-clipboard block for keys, addresses and recovery phrases.
///
/// v1.21: `sensitive` marks a secret (recovery phrase, WIF, keyed group
/// invite). A secret is never text-selectable — the system copy menu would
/// bypass the local-only, expiring pasteboard route — and is flagged
/// privacy-sensitive for system contexts that honour it. Public values
/// (addresses, plain chat codes) keep ordinary selection.
struct RevealBox: View {
    var text: String
    var sensitive: Bool = false

    var body: some View {
        Group {
            if sensitive {
                Text(text)
                    .textSelection(.disabled)
                    .privacySensitive()
            } else {
                Text(text)
                    .textSelection(.enabled)
            }
        }
        .font(.mono(12))
        .foregroundStyle(Palette.body)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Palette.surface)
        .squareEdge(Palette.border)
    }
}
