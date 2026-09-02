import SpiekCore
import SwiftUI
import UIKit

/// "Your account is a key." — the first screen, and the only place the
/// recovery phrase is shown before it disappears behind a confirmation.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    @State private var phrase = RecoveryPhrase.generate()
    @State private var revealed = false
    @State private var mode: WalletMode = .chain
    @State private var showRestore = false
    @State private var restoreInput = ""
    @State private var legacyPhrase = false
    @State private var busy = false

    /// Three words picked at random that must be typed back before continuing —
    /// the cheapest way to find out whether they were really written down.
    @State private var quizIndices: [Int] = []
    @State private var quizAnswers: [String] = ["", "", ""]
    @State private var quizError: String?

    private var words: [String] { RecoveryPhrase.words(in: phrase) }
    private var isQuizzing: Bool { !quizIndices.isEmpty }

    var body: some View {
        ZStack {
            Palette.ink.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Image("SpiekLogoWhite")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 34)
                        .padding(.bottom, 28)

                    Text("Your account\nis a key.")
                        .font(.display(38, bold: true))
                        .tracking(-1)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 16)

                    Text("Spiek generates a key pair right here. No phone number, no email, no central message database that can lock you out.")
                        .font(.sans(15.5))
                        .foregroundStyle(Palette.onDark)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 12)
                    // v1.21 (P0.1): the transaction model, up front.
                    Text("Every message is a transaction on the Bitcoin SV blockchain, fetched through replaceable network endpoints rather than a Spiek server. A transaction always costs a network fee (a fraction of a cent); Spiek adds a fixed service fee of \(ServiceFee.messageSats) sats per message and \(ServiceFee.imageSats) per image, always shown before you send.")
                        .font(.sans(13.5))
                        .foregroundStyle(Palette.onDark)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 24)

                    phraseGrid
                        .padding(.bottom, 16)

                    Text("Write these twelve words down. They are the only way back into your account — and into your entire history. Messages live on the chain forever: anyone who ever holds this key can read everything you sent.")
                        .font(.mono(11.5))
                        .lineSpacing(5)
                        .foregroundStyle(Palette.monoDark)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 24)

                    // Grouped so the enclosing VStack stays within
                    // ViewBuilder's ten-child limit.
                    Group {
                    if isQuizzing { quizPanel.padding(.bottom, 12) }

                    modePicker
                        .padding(.bottom, 14)

                    Button(isQuizzing ? "Check & continue" : "I have written them down") {
                        Task { await continueFromPhrase() }
                    }
                    .buttonStyle(SolidButtonStyle(background: Palette.soft,
                                                  foreground: Palette.ink,
                                                  font: .display(15)))
                    .disabled(busy || !revealed)
                    .opacity(revealed ? 1 : 0.5)
                    .padding(.bottom, 10)
                    }

                    Button(showRestore ? "Hide restore" : "Restore existing account") {
                        withAnimation(.easeOut(duration: 0.2)) { showRestore.toggle() }
                    }
                    .buttonStyle(OutlineButtonStyle(foreground: Palette.soft,
                                                    border: Color.white.opacity(0.28),
                                                    background: .clear))

                    if showRestore { restorePanel.padding(.top, 14) }

                    Button {
                        Task { await startDemo() }
                    } label: {
                        Text("or try the demo playground →")
                            .font(.sans(14))
                            .foregroundStyle(Palette.accent)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                }
                .padding(.horizontal, 24)
                .padding(.top, 40)
                .padding(.bottom, 40)
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    // MARK: Pieces

    private var phraseGrid: some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3),
                      alignment: .leading,
                      spacing: 10) {
                ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                    HStack(spacing: 6) {
                        Text("\(index + 1)")
                            .font(.mono(12.5))
                            .foregroundStyle(Palette.monoDark)
                        Text(revealed ? word : "••••")
                            .font(.mono(12.5))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 16)

            if !revealed {
                Button("Show the words") { revealed = true }
                    .font(.sans(13, weight: .medium))
                    .foregroundStyle(Palette.soft)
                    .padding(.bottom, 16)
            }
        }
        .background(Color.white.opacity(0.05))
        .overlay(Rectangle().stroke(Palette.soft.opacity(0.25), lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if revealed {
                Button {
                    // Sensitive: local-only, expires after a minute — the
                    // phrase must not ride Universal Clipboard to another
                    // device or sit in the pasteboard indefinitely.
                    model.copyToPasteboard(phrase, label: "Recovery phrase", sensitive: true)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.monoDark)
                        .padding(10)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var modePicker: some View {
        HStack(spacing: 10) {
            modeButton(.chain, title: "Blockchain")
            modeButton(.node, title: "Own node")
        }
    }

    private func modeButton(_ value: WalletMode, title: String) -> some View {
        Button {
            mode = value
        } label: {
            Text(title)
                .font(.sans(14, weight: .medium))
                .foregroundStyle(mode == value ? Palette.ink : Palette.soft)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(mode == value ? Palette.soft : Color.clear)
                .overlay(Rectangle().stroke(Palette.soft.opacity(mode == value ? 0 : 0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var quizPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ForEach(Array(quizIndices.enumerated()), id: \.offset) { slot, wordNumber in
                    TextField("word #\(wordNumber + 1)", text: Binding(
                        get: { quizAnswers.indices.contains(slot) ? quizAnswers[slot] : "" },
                        set: { value in
                            if quizAnswers.indices.contains(slot) { quizAnswers[slot] = value }
                        }
                    ))
                    .font(.mono(13))
                    .foregroundStyle(.white)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(Color.white.opacity(0.06))
                    .overlay(Rectangle().stroke(Palette.soft.opacity(0.3), lineWidth: 1))
                }
            }

            if let quizError {
                Text(quizError)
                    .font(.mono(11.5))
                    .foregroundStyle(Palette.dangerOnDark)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var restorePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: $restoreInput)
                .font(.mono(12.5))
                .foregroundStyle(.white)
                .scrollContentBackground(.hidden)
                .frame(height: 92)
                .padding(8)
                .background(Color.white.opacity(0.06))
                .overlay(Rectangle().stroke(Palette.soft.opacity(0.3), lineWidth: 1))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .overlay(alignment: .topLeading) {
                    if restoreInput.isEmpty {
                        Text("12 words, or a WIF key")
                            .font(.mono(12.5))
                            .foregroundStyle(Palette.monoDark)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }

            Button {
                legacyPhrase.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: legacyPhrase ? "checkmark.square.fill" : "square")
                        .font(.system(size: 13))
                    Text("older account (pre-BIP39 phrase)")
                        .font(.mono(11))
                }
                .foregroundStyle(Palette.monoDark)
            }
            .buttonStyle(.plain)

            Button("Import wallet") {
                Task { await restore() }
            }
            .buttonStyle(SolidButtonStyle(background: Palette.soft,
                                          foreground: Palette.ink,
                                          font: .display(15)))
            .disabled(busy || restoreInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: Actions

    /// First tap poses the quiz; the second checks it and creates the account.
    private func continueFromPhrase() async {
        guard isQuizzing else {
            var picked = Set<Int>()
            while picked.count < 3 { picked.insert(Int.random(in: 0..<12)) }
            quizIndices = picked.sorted()
            quizAnswers = ["", "", ""]
            quizError = nil
            return
        }

        let expected = quizIndices.map { words[$0] }
        let given = quizAnswers.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard given == expected else {
            quizError = "That does not match your 12 words — check what you wrote down."
            return
        }

        quizError = nil
        busy = true
        defer { busy = false }
        await model.createAccount(phrase: phrase, mode: mode)
    }

    private func restore() async {
        busy = true
        defer { busy = false }
        await model.importAccount(input: restoreInput, mode: mode, forceLegacy: legacyPhrase)
    }

    private func startDemo() async {
        busy = true
        defer { busy = false }
        await model.startDemo()
    }
}
