import SpiekCore
import SwiftUI
import UIKit

/// A chat bubble with the asymmetric corner from the web design: 18pt all
/// round, except the corner nearest the sender, which is 4pt.
struct BubbleShape: Shape {
    var mine: Bool

    func path(in rect: CGRect) -> Path {
        let large: CGFloat = 18
        let small: CGFloat = 4
        let topLeft = large
        let topRight = large
        let bottomRight: CGFloat = mine ? small : large
        let bottomLeft: CGFloat = mine ? large : small

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topRight, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - topRight, y: rect.minY + topRight),
                    radius: topRight, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight))
        path.addArc(center: CGPoint(x: rect.maxX - bottomRight, y: rect.maxY - bottomRight),
                    radius: bottomRight, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY - bottomLeft),
                    radius: bottomLeft, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeft))
        path.addArc(center: CGPoint(x: rect.minX + topLeft, y: rect.minY + topLeft),
                    radius: topLeft, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}

struct MessageBubble: View {
    /// The same five the web build offers.
    static let reactionEmoji = ["👍", "❤️", "😂", "🔥", "🙏"]

    @Environment(AppModel.self) private var model

    let message: ViewMessage
    var showSender: Bool
    var onReact: (String) -> Void
    var onReply: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void

    @State private var image: UIImage?
    @State private var loadingImage = false
    @State private var showLightbox = false

    private var mine: Bool { message.record.mine }
    /// A message counts as a payment when it carries more than the dust
    /// output every direct message already includes.
    private var isPayment: Bool {
        if let paid = message.record.paySats, paid > 0 { return true }
        return message.record.payIn > model.settings.dust
    }

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
            if showSender && !mine {
                Text(model.senderName(for: message))
                    .font(.sans(12, weight: .medium))
                    .foregroundStyle(Palette.primary)
                    .padding(.horizontal, 4)
            }

            // Above the bubble rather than inside it: a reply can be an image,
            // a payment, a withdrawn or an unreadable message, and only the
            // plain-text bubble had room for the quote.
            quoteBlock

            content

            stampLine
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(.bottom, 8)
        .contextMenu { contextMenu }
        .fullScreenCover(isPresented: $showLightbox) {
            if let image { Lightbox(image: image) }
        }
        .task(id: message.record.txid) { await loadMediaIfNeeded() }
    }

    // MARK: Content variants

    /// The message a reply points at, shown above the bubble.
    @ViewBuilder
    private var quoteBlock: some View {
        if let quote = message.replyTo {
            VStack(alignment: .leading, spacing: 1) {
                Text(quote.isMissing ? "in reply to" : (quote.mine ? "You" : model.name(forSender: quote.sender)))
                    .font(.sans(11, weight: .medium))
                    .foregroundStyle(Palette.primary)
                Text(quote.preview)
                    .font(.sans(12.5))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: 240, alignment: .leading)
            .padding(.leading, 10)
            .padding(.trailing, 9)
            .padding(.vertical, 5)
            .background(Palette.accent.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Palette.accent)
                    .frame(width: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            // Tucked slightly under the bubble it belongs to.
            .padding(mine ? .trailing : .leading, 6)
            .padding(.bottom, 2)
        }
    }

    @ViewBuilder
    private var content: some View {
        if message.deleted {
            bubble {
                Text("Message withdrawn")
                    .font(.sans(15))
                    .italic()
                    .opacity(0.65)
            }
        } else if isPayment {
            paymentBubble
        } else if message.unreadable {
            bubble {
                HStack(spacing: 6) {
                    Image(systemName: "lock.slash")
                        .font(.system(size: 12))
                    Text("Encrypted — not readable on this device")
                        .font(.sans(14))
                }
                .opacity(0.75)
            }
        } else if message.viewOp == .media {
            mediaBubble
        } else {
            bubble {
                Text(message.text)
                    .font(.sans(15))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if !message.reactions.isEmpty {
            HStack(spacing: 4) {
                ForEach(Array(groupedReactions.enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: 3) {
                        Text(entry.emoji).font(.system(size: 12.5))
                        if entry.count > 1 {
                            Text("\(entry.count)").font(.mono(10)).foregroundStyle(Palette.muted)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.white)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Palette.border, lineWidth: 1))
                }
            }
            .padding(.top, 1)
        }
    }

    private func bubble<Content: View>(@ViewBuilder _ inner: () -> Content) -> some View {
        inner()
            .foregroundStyle(mine ? Color.white : Palette.body2)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(mine ? Palette.primary : Color.white)
            .clipShape(BubbleShape(mine: mine))
            .overlay {
                if !mine {
                    BubbleShape(mine: mine).stroke(Palette.border, lineWidth: 1)
                }
            }
            .frame(maxWidth: 300, alignment: mine ? .trailing : .leading)
    }

    /// The payment block is deliberately square and ink-coloured — the one
    /// element that breaks the bubble language, so money always reads as money.
    private var paymentBubble: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(mine ? "sent" : "received")
                .stampLabel(Palette.accent)
                .tracking(1.2)
                .padding(.bottom, 6)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Format.sats(amount))
                    .font(.display(26, bold: true))
                    .foregroundStyle(.white)
                Text("sats")
                    .font(.mono(12))
                    .foregroundStyle(Palette.onDark)
            }

            if let dollars = model.usd(amount) {
                Text(dollars)
                    .font(.mono(10.5))
                    .foregroundStyle(Palette.monoDark)
                    .padding(.top, 6)
            }

            if !message.text.isEmpty {
                Text(message.text)
                    .font(.sans(13.5))
                    .foregroundStyle(Color(hex: 0xE6F0F8))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(minWidth: 210, alignment: .leading)
        .background(Palette.ink)
    }

    private var amount: UInt64 {
        if mine { return message.record.paySats ?? message.record.payOut }
        let dust = model.settings.dust
        return message.record.payIn > dust ? message.record.payIn - dust : message.record.payIn
    }

    private var mediaBubble: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onTapGesture { showLightbox = true }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: loadingImage ? "clock" : "photo")
                        .font(.system(size: 24))
                        .foregroundStyle(Palette.primary)
                    Text(loadingImage ? "fetching from the chain…" : "image")
                        .font(.mono(10.5))
                        .foregroundStyle(Palette.stamp)
                }
                .frame(minWidth: 210, minHeight: 110)
                .background(Palette.surface)
                .squareEdge(Palette.border)
            }

            if let caption = message.mediaRef?.caption, !caption.isEmpty {
                Text(caption)
                    .font(.sans(13.5))
                    .foregroundStyle(mine ? .white : Palette.body2)
            }
        }
        .padding(mine ? 4 : 4)
        .background(mine ? Palette.primary : Color.white)
        .clipShape(BubbleShape(mine: mine))
        .overlay {
            if !mine { BubbleShape(mine: mine).stroke(Palette.border, lineWidth: 1) }
        }
    }

    // MARK: Meta

    private var stampLine: some View {
        HStack(spacing: 6) {
            Text(Format.clockTime(message.record.time))
            if message.encrypted {
                Image(systemName: "lock.fill").font(.system(size: 8))
            }
            if message.editTime != nil {
                Text("edited").opacity(0.7)
            }
            statusGlyph
            if let error = message.record.error {
                Text(error).foregroundStyle(Palette.danger).lineLimit(1)
            }
        }
        .font(.mono(10))
        .foregroundStyle(Palette.stamp)
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch message.record.status {
        case .pending:
            Image(systemName: "clock").font(.system(size: 8))
        case .sent:
            Image(systemName: "checkmark").font(.system(size: 8))
        case .confirmed:
            HStack(spacing: -3) {
                Image(systemName: "checkmark")
                Image(systemName: "checkmark")
            }
            .font(.system(size: 8))
            .foregroundStyle(Palette.primary)
        }
    }

    private var groupedReactions: [(emoji: String, count: Int)] {
        var order = [String]()
        var counts = [String: Int]()
        for reaction in message.reactions {
            if counts[reaction.emoji] == nil { order.append(reaction.emoji) }
            counts[reaction.emoji, default: 0] += 1
        }
        return order.map { ($0, counts[$0] ?? 0) }
    }

    @ViewBuilder
    private var contextMenu: some View {
        // A palette-styled ControlGroup is what puts the reactions in one row,
        // the way Messages does it. Plain Buttons in a menu each get their own
        // full-width line, which is what made this a vertical column of emoji.
        ControlGroup {
            ForEach(Self.reactionEmoji, id: \.self) { emoji in
                Button {
                    onReact(emoji)
                } label: {
                    Text(emoji)
                }
            }
        }
        .controlGroupStyle(.palette)

        if !message.deleted {
            Button { onReply() } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
        }
        if !message.text.isEmpty {
            Button {
                UIPasteboard.general.string = message.text
                model.show("Message copied.")
            } label: {
                Label("Copy text", systemImage: "doc.on.doc")
            }
        }
        Button {
            UIPasteboard.general.string = message.record.txid
            model.show("Transaction id copied.")
        } label: {
            Label("Copy transaction id", systemImage: "link")
        }
        if mine && !message.deleted {
            if message.viewOp == .msg {
                Button { onEdit() } label: { Label("Edit", systemImage: "pencil") }
            }
            Button(role: .destructive) { onDelete() } label: {
                Label("Withdraw", systemImage: "trash")
            }
        }
        // Per sender, so it also works in a group where only individual
        // messages identify who wrote them. Local only — see AppModel.
        if !mine {
            Button(role: .destructive) {
                Task { await model.setBlocked(message.record.sender, blocked: true) }
            } label: {
                Label("Block sender", systemImage: "hand.raised")
            }
        }
    }

    private func loadMediaIfNeeded() async {
        guard message.viewOp == .media, image == nil, let reference = message.mediaRef else { return }
        loadingImage = true
        defer { loadingImage = false }
        image = await model.loadMedia(for: reference)
    }
}

struct Lightbox: View {
    @Environment(\.dismiss) private var dismiss
    let image: UIImage

    var body: some View {
        ZStack {
            Palette.ink.opacity(0.94).ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .padding(12)
        }
        .onTapGesture { dismiss() }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(16)
            }
        }
    }
}
