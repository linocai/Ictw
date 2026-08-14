import SwiftUI

/// Clean-room visual tokens for the v2 Desk. These are intentionally separate
/// from the v1 theme: a v2 screen must opt in rather than inheriting old cards,
/// chrome, or rounded-control conventions.
enum V2DeskColorToken: Sendable {
    case manuscriptPaper
    case acceptedPaper
    case desk
    case intentPanel
    case rail
    case card
    case titleBar
    case ink
    case secondaryInk
    case tertiaryInk
    case disabledInk
    case metadataInk
    case accent
    case accentPressed
    case success
    case warning
    case danger
    case line
    case strongLine
    case staleStripeBase
    case staleStripeLine
    case taskWriting
    case taskSuccess
    case taskWarning
    case taskFailure
}

enum V2DeskPalette {
    static func color(_ token: V2DeskColorToken, scheme: ColorScheme) -> Color {
        if token == .line {
            return scheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.08)
        }
        if token == .strongLine {
            return scheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.20)
        }
        let hex: UInt32
        if scheme == .dark {
            switch token {
            case .manuscriptPaper: hex = 0x14120F
            case .acceptedPaper: hex = 0x191612
            case .desk: hex = 0x100E0C
            case .intentPanel, .rail, .card: hex = 0x1A1714
            case .titleBar: hex = 0x221F1B
            case .ink: hex = 0xE8E2D6
            case .secondaryInk: hex = 0xB5AEA2
            case .tertiaryInk: hex = 0x8A8378
            case .disabledInk: hex = 0x6B655C
            case .metadataInk: hex = 0x7D766C
            case .accent, .accentPressed: hex = 0xC89552
            case .success: hex = 0x7FA487
            case .warning: hex = 0xD2A64F
            case .danger: hex = 0xDF7768
            case .staleStripeBase: hex = 0x211E19
            case .staleStripeLine: hex = 0x191612
            case .taskWriting: hex = 0x2A2118
            case .taskSuccess: hex = 0x1D2920
            case .taskWarning: hex = 0x2C2619
            case .taskFailure: hex = 0x301D1A
            case .line, .strongLine: fatalError("handled above")
            }
        } else {
            switch token {
            case .manuscriptPaper: hex = 0xFFFDF8
            case .acceptedPaper: hex = 0xFBF8F1
            case .desk: hex = 0xF7F4EC
            case .intentPanel: hex = 0xF2EDE3
            case .rail: hex = 0xEFEAE0
            case .card: hex = 0xF5F2EB
            case .titleBar: hex = 0xEDE8DE
            case .ink: hex = 0x1B1917
            case .secondaryInk: hex = 0x57514A
            case .tertiaryInk: hex = 0x8C857A
            case .disabledInk: hex = 0xB0A899
            case .metadataInk: hex = 0xA79F92
            case .accent: hex = 0xA0713A
            case .accentPressed: hex = 0x7E5729
            case .success: hex = 0x4A6B52
            case .warning: hex = 0xC08A2E
            case .danger: hex = 0xA6392B
            case .staleStripeBase: hex = 0xF0EBE1
            case .staleStripeLine: hex = 0xF7F4EC
            case .taskWriting: hex = 0xF6EEE0
            case .taskSuccess: hex = 0xF2EFE4
            case .taskWarning: hex = 0xF6F1E4
            case .taskFailure: hex = 0xF7EBE7
            case .line, .strongLine: fatalError("handled above")
            }
        }
        return Self.hex(hex)
    }

    static func hex(_ value: UInt32, opacity: Double = 1) -> Color {
        Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: opacity
        )
    }
}

enum V2DeskType {
    static func prose(_ size: CGFloat = 16.5, weight: Font.Weight = .regular) -> Font {
        .custom("Songti SC", size: size).weight(weight)
    }

    static func control(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("PingFang SC", size: size).weight(weight)
    }

    static func chapterNumber(_ size: CGFloat = 13) -> Font {
        .custom("Spectral", size: size)
    }

    static let bodyLineSpacing: CGFloat = 18
    static let proseLineSpacing: CGFloat = 12
}

enum V2DeskMetric {
    static let manuscriptMeasure: CGFloat = 600
    static let manuscriptMinimum: CGFloat = 480
    static let chapterRail: CGFloat = 104
    static let collapsedRail: CGFloat = 44
    static let contextPanel: CGFloat = 344
    static let titleBarHeight: CGFloat = 38
    static let actionBarHeight: CGFloat = 44
    static let mobileTapTarget: CGFloat = 44
    static let smallCornerRadius: CGFloat = 6
    static let cardCornerRadius: CGFloat = 8
    static let panelCornerRadius: CGFloat = 12
    static let sheetCornerRadius: CGFloat = 20
}

enum V2DeskMotion {
    static func taskBanner(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.18)
    }

    static func manuscriptReplacement(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.30)
    }

    static func sheet(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.26)
    }
}
