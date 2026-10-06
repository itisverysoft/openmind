import SwiftUI

extension Color {
    /// Creates a color from a 6-digit hex string such as "FFF1A8" (with or without "#").
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }

    /// Auto ink swatch: half black / half white, follows the background.
    /// Used by the pen row and the text format bar.
    struct AutoInkDot: View {
        var selectedHex: String
        var diameter: CGFloat = 24
        var onPick: (String) -> Void = { _ in }

        var body: some View {
            Button { onPick(Palette.autoInk) } label: {
                Circle()
                    .fill(LinearGradient(colors: [.black, .white],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                    .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                    .overlay {
                        if selectedHex.uppercased() == Palette.autoInk {
                            Circle().stroke(Color.accentColor, lineWidth: 3).padding(-3)
                        }
                    }
                    .frame(width: diameter, height: diameter)
            }
            .buttonStyle(.plain)
            .help("Auto (black on light, white on dark)")
        }
    }

    /// Convenience in `Color.` namespace for call sites.
    static func autoInkDot(selected: String, diameter: CGFloat = 24,
                           onPick: @escaping (String) -> Void) -> AutoInkDot {
        AutoInkDot(selectedHex: selected, diameter: diameter, onPick: onPick)
    }
    /// Platform-appropriate canvas background.
    static var canvasBackground: Color {
        #if os(macOS)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color(uiColor: .systemBackground)
        #endif
    }

    /// Resolves an ink color for the given scheme. `Palette.autoInk`
    /// renders black on light backgrounds and white on dark ones.
    static func ink(hex: String, for scheme: ColorScheme) -> Color {
        if hex.uppercased() == Palette.autoInk {
            return scheme == .dark ? .white : .black
        }
        return Color(hex: hex)
    }
}

/// Colors offered in the toolbar. Stored on items as hex strings.
enum Palette {
    static let swatches = [
        "FFF1A8", // yellow
        "FFC9D6", // pink
        "C8F0C8", // green
        "C6E0FF", // blue
        "E3D4FF", // purple
        "FFD9A8", // orange
        "FFFFFF", // white
        "D9D9D9"  // gray
    ]

    /// Dark inks that stay legible for freehand drawing on a light canvas.
    /// White is included for dark backgrounds; `autoInk` follows the canvas.
    static let inkSwatches = [
        "1F1F1F", // near black
        "D43D2A", // red
        "2563EB", // blue
        "1A8C4A", // green
        "7C3AED", // purple
        "B26A00", // brown-orange
        "FFFFFF"  // white
    ]

    /// Sentinel stored as `colorHex` for ink that follows the background:
    /// black on light, white on dark. Not a real hex — resolve with
    /// `Color.ink(hex:for:)`; rich text uses a missing foreground instead.
    static let autoInk = "AUTO"
}
