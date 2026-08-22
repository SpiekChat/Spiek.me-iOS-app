import CoreText
import SpiekCore
import SwiftUI

/// The Spiek palette, carried over one-for-one from the web app.
enum Palette {
    static let ink = Color(hex: 0x0D2340)
    static let primary = Color(hex: 0x1D6FA5)
    static let accent = Color(hex: 0x4BA3DB)
    static let soft = Color(hex: 0xA8D4F0)
    static let surface = Color(hex: 0xF4F8FB)
    static let chatBackground = Color(hex: 0xFBFDFE)
    static let border = Color(hex: 0xDCE9F3)
    static let hairline = Color(hex: 0xEDF3F8)
    static let muted = Color(hex: 0x7E93A5)
    static let stamp = Color(hex: 0x94A7B8)
    static let body = Color(hex: 0x41525F)
    static let body2 = Color(hex: 0x4C5D6B)
    static let onDark = Color(hex: 0xA9C3D6)
    static let monoDark = Color(hex: 0x7FA8C6)
    static let danger = Color(hex: 0xC4402F)
    static let dangerOnDark = Color(hex: 0xFFB4A8)
}

/// Bundled typefaces. `Typeface.register()` runs once at launch; the
/// PostScript names below must match the files in Resources/Fonts.
enum Typeface {
    static let displaySemibold = "SpaceGrotesk-SemiBold"
    static let displayBold = "SpaceGrotesk-Bold"
    static let sansRegular = "IBMPlexSans-Regular"
    static let sansMedium = "IBMPlexSans-Medium"
    static let sansSemibold = "IBMPlexSans-SemiBold"
    static let monoRegular = "IBMPlexMono-Regular"
    static let monoMedium = "IBMPlexMono-Medium"

    private static var didRegister = false

    /// Registers the bundled fonts. Fonts listed in Info.plist under
    /// `UIAppFonts` are normally enough, but registering explicitly keeps
    /// previews and unit tests working too.
    static func register() {
        guard !didRegister else { return }
        didRegister = true
        let names = ["SpaceGrotesk_600SemiBold", "SpaceGrotesk_700Bold",
                     "IBMPlexSans_400Regular", "IBMPlexSans_500Medium", "IBMPlexSans_600SemiBold",
                     "IBMPlexMono_400Regular", "IBMPlexMono_500Medium"]
        for name in names {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

extension Font {
    /// Space Grotesk — headlines and numbers.
    static func display(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? Typeface.displayBold : Typeface.displaySemibold, size: size)
    }

    /// IBM Plex Sans — body copy.
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch weight {
        case .medium: return .custom(Typeface.sansMedium, size: size)
        case .semibold, .bold, .heavy, .black: return .custom(Typeface.sansSemibold, size: size)
        default: return .custom(Typeface.sansRegular, size: size)
        }
    }

    /// IBM Plex Mono — timestamps, keys, labels.
    static func mono(_ size: CGFloat, medium: Bool = false) -> Font {
        .custom(medium ? Typeface.monoMedium : Typeface.monoRegular, size: size)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

extension View {
    /// The uppercase, wide-tracked mono label used throughout the design.
    func stampLabel(_ color: Color = Palette.stamp, size: CGFloat = 10) -> some View {
        self.font(.mono(size))
            .tracking(size * 0.12)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }

    /// Spiek's shape language is square. This is the one-line reminder.
    func squareEdge(_ color: Color = Palette.border, width: CGFloat = 1) -> some View {
        self.overlay(Rectangle().stroke(color, lineWidth: width))
    }
}

// MARK: - Number and time formatting

enum Format {
    static func sats(_ value: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func sats(_ value: Int) -> String {
        sats(UInt64(max(0, value)))
    }

    /// Dollars, from the live rate. Returns nil when no rate is known, so a
    /// caller shows nothing rather than a made-up number: this used to be a
    /// hand-typed setting that defaulted to 55, which meant every screen quoted
    /// a price that had never been checked against anything.
    static func usd(sats: UInt64, price: BSVPrice?) -> String? {
        guard let price else { return nil }
        let value = price.dollars(sats: sats)
        if value > 0 && value < 0.01 { return "< $0.01" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = Locale(identifier: "en_US")
        // Sub-cent amounts are the normal case here — a message costs a few
        // hundred satoshis — so the usual two decimals would print $0.00 for
        // everything below a cent, which the guard above already handles.
        return formatter.string(from: NSNumber(value: value)) ?? "$0"
    }

    /// The rate itself, as shown in the settings row.
    static func usdRate(_ price: BSVPrice) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = price.usd < 10 ? 4 : 2
        return formatter.string(from: NSNumber(value: price.usd)) ?? "$\(price.usd)"
    }

    static func shortTime(_ timestamp: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
        } else if calendar.isDateInYesterday(date) {
            return "yesterday"
        } else if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            formatter.dateFormat = "EEE"
        } else {
            formatter.dateFormat = "d MMM"
        }
        return formatter.string(from: date)
    }

    static func dayDivider(_ timestamp: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "today" }
        if calendar.isDateInYesterday(date) { return "yesterday" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter.string(from: date)
    }

    static func clockTime(_ timestamp: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    /// Two-letter monogram for an avatar.
    static func initials(_ name: String?, fallback: String) -> String {
        let source = (name?.isEmpty == false ? name! : fallback)
        let words = source.split(separator: " ")
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        return String(source.prefix(2)).uppercased()
    }

    static func truncatedMiddle(_ text: String, lead: Int = 10, tail: Int = 8) -> String {
        guard text.count > lead + tail + 1 else { return text }
        return "\(text.prefix(lead))…\(text.suffix(tail))"
    }
}
