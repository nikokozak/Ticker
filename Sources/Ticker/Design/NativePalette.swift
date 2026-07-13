import AppKit

/// Native counterpart to the semantic colors in Web/src/styles/index.css.
enum NativePalette {
    static let background = dynamic(
        light: NSColor(red: 251 / 255, green: 251 / 255, blue: 250 / 255, alpha: 1),
        dark: NSColor(red: 28 / 255, green: 28 / 255, blue: 27 / 255, alpha: 1)
    )
    static let surface = dynamic(
        light: NSColor(red: 244 / 255, green: 244 / 255, blue: 242 / 255, alpha: 1),
        dark: NSColor(red: 36 / 255, green: 36 / 255, blue: 35 / 255, alpha: 1)
    )
    static let surfaceRaised = dynamic(
        light: .white,
        dark: NSColor(red: 43 / 255, green: 43 / 255, blue: 41 / 255, alpha: 1)
    )
    static let text = dynamic(
        light: NSColor(red: 31 / 255, green: 31 / 255, blue: 29 / 255, alpha: 1),
        dark: NSColor(red: 243 / 255, green: 242 / 255, blue: 237 / 255, alpha: 1)
    )
    static let textMuted = dynamic(
        light: NSColor(red: 111 / 255, green: 111 / 255, blue: 104 / 255, alpha: 1),
        dark: NSColor(red: 170 / 255, green: 167 / 255, blue: 157 / 255, alpha: 1)
    )
    static let textSubtle = dynamic(
        light: NSColor(red: 155 / 255, green: 154 / 255, blue: 145 / 255, alpha: 1),
        dark: NSColor(red: 119 / 255, green: 116 / 255, blue: 108 / 255, alpha: 1)
    )
    static let accent = dynamic(
        light: NSColor(red: 164 / 255, green: 80 / 255, blue: 46 / 255, alpha: 1),
        dark: NSColor(red: 217 / 255, green: 138 / 255, blue: 99 / 255, alpha: 1)
    )
    static let success = dynamic(
        light: NSColor(red: 22 / 255, green: 129 / 255, blue: 61 / 255, alpha: 1),
        dark: NSColor(red: 104 / 255, green: 185 / 255, blue: 130 / 255, alpha: 1)
    )
    static let danger = dynamic(
        light: NSColor(red: 199 / 255, green: 58 / 255, blue: 50 / 255, alpha: 1),
        dark: NSColor(red: 238 / 255, green: 127 / 255, blue: 118 / 255, alpha: 1)
    )
    static let separator = dynamic(
        light: NSColor(red: 31 / 255, green: 31 / 255, blue: 29 / 255, alpha: 0.08),
        dark: NSColor(red: 243 / 255, green: 242 / 255, blue: 237 / 255, alpha: 0.08)
    )

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}
