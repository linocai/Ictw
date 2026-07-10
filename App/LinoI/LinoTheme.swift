import SwiftUI

enum LinoTheme {
    static func hex(_ value: UInt32, opacity: Double = 1) -> Color {
        Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0,
            opacity: opacity
        )
    }

    static let background = LinearGradient(
        colors: [hex(0xEEF8FF), hex(0xF8FCFF), .white],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let page = hex(0xEEF8FF)
    static let accent = hex(0x2688E8)
    static let accentDeep = hex(0x1E5FAE)
    static let accentSoft = hex(0xD8EDFF)
    static let cyan = hex(0x1F8FA3)
    static let ink = hex(0x202B3A)
    static let body = hex(0x334155)
    static let muted = hex(0x78889D)
    static let faint = hex(0x9AABC0)
    static let panel = Color.white.opacity(0.66)
    static let stroke = hex(0x2A5D80, opacity: 0.12)
    static let hairline = hex(0x1D3B55, opacity: 0.10)
    static let success = hex(0x2F8F5B)
    static let warning = hex(0xB8731F)
    static let danger = hex(0xC0564F)

    static let accentGradient = LinearGradient(
        colors: [hex(0x52B7FF), hex(0x2688E8)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let successGradient = LinearGradient(
        colors: [success, hex(0x39B270)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let logoGradient = LinearGradient(
        colors: [hex(0x66B9FF), hex(0x8AC7FF)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static func coverGradient(_ seed: String) -> LinearGradient {
        let palettes: [[UInt32]] = [
            [0x3E8EF7, 0x56B6FF, 0x8FD8FF],
            [0x2EA7C7, 0x5BC8DA, 0xA8E9F0],
            [0x5B8DEF, 0x7CAEFF, 0xBED7FF],
            [0x4CA3D9, 0x7DC7F0, 0xD5F1FF],
        ]
        let idx = abs(seed.hashValue) % palettes.count
        return LinearGradient(colors: palettes[idx].map { hex($0) }, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension View {
    func linoGlass(cornerRadius: CGFloat = 24) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background { shape.fill(LinoTheme.panel) }
            .glassEffect(.regular, in: shape)
            .overlay(
                shape.stroke(
                    LinearGradient(colors: [Color.white.opacity(0.74), LinoTheme.stroke], startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.7
                )
            )
    }

    func linoCard(cornerRadius: CGFloat = 18) -> some View {
        self
            .background(Color.white.opacity(0.68), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(LinoTheme.hairline, lineWidth: 0.5))
            .shadow(color: LinoTheme.hex(0x143052, opacity: 0.10), radius: 18, y: 10)
    }
}
