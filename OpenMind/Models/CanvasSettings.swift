import Foundation
import CoreGraphics
import SwiftUI

/// Paper size for the canvas sheet. `.infinite` keeps the current freeform
/// canvas; every other case centers a fixed sheet (in world points) on
/// `CanvasMetrics.center`. Items outside the sheet keep working — they sit
/// off the page, and exports use the sheet.
enum CanvasSizePreset: String, CaseIterable, Identifiable {
    case infinite
    case A4
    case letter
    case A3
    case legal
    case A5
    /// Exact document size (e.g. an imported PDF page). Set programmatically;
    /// the panel shows a "Custom W×H" indicator instead of a chip.
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .infinite: return "Infinite"
        case .A4:       return "A4"
        case .letter:   return "Letter"
        case .A3:       return "A3"
        case .legal:    return "Legal"
        case .A5:       return "A5"
        case .custom:   return "Custom"
        }
    }

    /// Chips offered in the panel. `.custom` never shows as a chip — it is
    /// only indicated when active.
    static var chips: [CanvasSizePreset] {
        [.infinite, .A4, .letter, .A3, .legal, .A5]
    }

    /// Portrait base size in world points (72dpi print points). Nil for
    /// `.infinite` (no sheet) and `.custom` (dimensions live on the board).
    var portraitSize: CGSize? {
        switch self {
        case .infinite: return nil
        case .custom:   return nil
        case .A4:       return CGSize(width: 595, height: 842)
        case .letter:   return CGSize(width: 612, height: 792)
        case .A3:       return CGSize(width: 842, height: 1191)
        case .legal:    return CGSize(width: 612, height: 1008)
        case .A5:       return CGSize(width: 420, height: 595)
        }
    }
}

enum CanvasOrientation: String, CaseIterable, Identifiable {
    case portrait
    case landscape

    var id: String { rawValue }

    var title: String {
        switch self {
        case .portrait:  return "Portrait"
        case .landscape: return "Landscape"
        }
    }
}

/// Background pattern drawn on the canvas (full view when infinite,
/// clipped to the sheet otherwise).
enum CanvasPattern: String, CaseIterable, Identifiable {
    case plain
    case grid
    case dots
    case lines
    case columns
    case graph

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plain:   return "Plain"
        case .grid:    return "Grid"
        case .dots:    return "Dots"
        case .lines:   return "Lines"
        case .columns: return "Columns"
        case .graph:   return "Graph"
        }
    }
}

/// Sheet swatches from the design (7 light + 1 dark).
enum CanvasPalette {
    static let sheetSwatches = [
        "FFFFFF", // white
        "F8F6F1", // off-white
        "FFF6D9", // cream
        "EAF1FF", // light blue
        "EAF6EC", // mint
        "FDE9EF", // pink
        "EFEAFF", // lavender
        "232328", // dark
    ]
}

/// Pure geometry for the sheet: world-space rect centered on `center`,
/// or nil for `.infinite`. Tested in CanvasSettingsTests.
enum CanvasSheet {
    static func worldRect(preset: CanvasSizePreset,
                          orientation: CanvasOrientation,
                          center: CGPoint) -> CGRect? {
        guard let base = preset.portraitSize else { return nil }
        let size: CGSize
        switch orientation {
        case .portrait:  size = base
        case .landscape: size = CGSize(width: base.height, height: base.width)
        }
        return CGRect(x: center.x - size.width / 2,
                      y: center.y - size.height / 2,
                      width: size.width, height: size.height)
    }
}

/// New-board defaults (the panel's "Use this canvas for new boards").
enum CanvasDefaults {
    private enum Keys {
        static let enabled = "openmind.canvasDefaults.enabled"
        static let size = "openmind.canvasDefaults.size"
        static let orientation = "openmind.canvasDefaults.orientation"
        static let colorHex = "openmind.canvasDefaults.colorHex"
        static let pattern = "openmind.canvasDefaults.pattern"
        static let customWidth = "openmind.canvasDefaults.customWidth"
        static let customHeight = "openmind.canvasDefaults.customHeight"
    }

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.enabled) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.enabled) }
    }

    static var size: CanvasSizePreset {
        get { CanvasSizePreset(rawValue: UserDefaults.standard.string(forKey: Keys.size) ?? "") ?? .infinite }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Keys.size) }
    }

    static var orientation: CanvasOrientation {
        get { CanvasOrientation(rawValue: UserDefaults.standard.string(forKey: Keys.orientation) ?? "") ?? .portrait }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Keys.orientation) }
    }

    static var colorHex: String {
        get {
            let stored = UserDefaults.standard.string(forKey: Keys.colorHex) ?? ""
            return stored.isEmpty ? "FFFFFF" : stored
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.colorHex) }
    }

    static var pattern: CanvasPattern {
        get { CanvasPattern(rawValue: UserDefaults.standard.string(forKey: Keys.pattern) ?? "") ?? .dots }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Keys.pattern) }
    }

    /// Portrait-base custom dimensions for `.custom` defaults.
    static var customSize: CGSize {
        get {
            let w = UserDefaults.standard.double(forKey: Keys.customWidth)
            let h = UserDefaults.standard.double(forKey: Keys.customHeight)
            guard w > 0, h > 0 else { return CGSize(width: 595, height: 842) }
            return CGSize(width: w, height: h)
        }
        set {
            UserDefaults.standard.set(newValue.width, forKey: Keys.customWidth)
            UserDefaults.standard.set(newValue.height, forKey: Keys.customHeight)
        }
    }
}

/// Relative luminance of a 6-digit hex color (0 = black, 1 = white).
/// Picks pattern ink that stays legible on light and dark sheets.
func canvasLuminance(hex: String) -> Double {
    let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    var value: UInt64 = 0
    Scanner(string: cleaned).scanHexInt64(&value)
    let r = Double((value >> 16) & 0xFF) / 255
    let g = Double((value >> 8) & 0xFF) / 255
    let b = Double(value & 0xFF) / 255
    return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Best-effort hex string (e.g. "A1B2C3") for a SwiftUI Color picked via
/// ColorPicker. Returns nil when the color can't be resolved to sRGB.
func canvasHexString(from color: Color) -> String? {
#if os(macOS)
    guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return nil }
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    ns.getRed(&r, green: &g, blue: &b, alpha: &a)
#else
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
#endif
    return String(format: "%02X%02X%02X",
                  Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
}
