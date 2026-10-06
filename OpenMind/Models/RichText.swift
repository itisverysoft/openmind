import Foundation
#if os(macOS)
import AppKit
/// Cross-platform aliases so the canvas uses one rich-text implementation.
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
#endif

/// Bold / italic traits addressable from the format toolbar.
enum RichTrait {
    case bold, italic
}

/// Toolbar-observable formatting state for a range (or typing attributes).
/// `fontSize` / `colorHex` / `alignment` are nil when mixed across the range.
struct RichTextState: Equatable {
    var hasSelection = false
    var bold = false
    var italic = false
    var underline = false
    var strikethrough = false
    var fontSize: CGFloat?
    var colorHex: String?
    var alignment: NSTextAlignment?
}

// MARK: - Platform color hex

extension PlatformColor {
    /// Dynamic label color used for Auto ink in the native editors:
    /// black on light, white on dark. Storage keeps "no foreground" for
    /// Auto; the editor display injects this (see `richAdaptiveDisplay`)
    /// so focused text matches the SwiftUI `Color.primary` rendering.
    static var adaptiveLabel: PlatformColor {
        #if os(macOS)
        return .labelColor
        #else
        return .label
        #endif
    }

    /// True only for the dynamic label color above — not for a user-picked
    /// static white/black. Compared by dynamic identity (`isEqual` on the
    /// dynamic object), not by resolved RGB, so explicit FFFFFF stays explicit.
    var isAdaptiveLabel: Bool {
        isEqual(Self.adaptiveLabel)
    }

    static func fromRichHex(_ hex: String) -> PlatformColor? {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        guard Scanner(string: cleaned).scanHexInt64(&value) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        #if os(macOS)
        return PlatformColor(srgbRed: r, green: g, blue: b, alpha: 1)
        #else
        return PlatformColor(red: r, green: g, blue: b, alpha: 1)
        #endif
    }

    func richHexString() -> String? {
        #if os(macOS)
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        #endif
        return String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

// MARK: - RTF codec (persistent storage)

enum RichTextCodec {
    static func encode(_ attr: NSAttributedString) -> Data? {
        let range = NSRange(location: 0, length: attr.length)
        return try? attr.data(from: range, documentAttributes: [
            .documentType: NSAttributedString.DocumentType.rtf
        ])
    }

    static func decode(_ data: Data) -> NSAttributedString? {
        guard !data.isEmpty else { return nil }
        return try? NSAttributedString(data: data, options: [
            .documentType: NSAttributedString.DocumentType.rtf
        ], documentAttributes: nil)
    }

    /// Legacy plain-text items become attributed text on first rich edit.
    /// No foreground color is set: missing color means Auto (adaptive
    /// label color) at render time, in editors and SwiftUI Text alike.
    static func plainFallback(text: String, fontSize: CGFloat) -> NSAttributedString {
        let font = PlatformFont.systemFont(ofSize: fontSize)
        return NSAttributedString(string: text, attributes: [.font: font])
    }
}

// MARK: - Zoom scaling (display-sized copies; storage stays in world points)

/// Returns a copy with every font size multiplied by `scale`.
func richTextScaled(_ attr: NSAttributedString, by scale: CGFloat) -> NSAttributedString {
    guard scale != 1 else { return attr }
    let out = NSMutableAttributedString(attributedString: attr)
    richTransformFonts(out, in: NSRange(location: 0, length: out.length)) { font in
        richFontSized(font, size: font.pointSize * scale)
    }
    return out
}

/// Inverse of `richTextScaled`: divides every font size by `scale`.
func richTextUnscaled(_ attr: NSAttributedString, by scale: CGFloat) -> NSAttributedString {
    guard scale != 1 else { return attr }
    return richTextScaled(attr, by: 1 / scale)
}

// MARK: - Auto ink display (dynamic color fix)

/// Editor display copy: runs with no foreground (Auto) get the dynamic label
/// color so NSTextView/UITextView render white-on-dark / black-on-light,
/// matching the SwiftUI `Color.primary` rendering of the unfocused text.
/// Storage keeps "missing foreground" for Auto; strip with
/// `richStrippedForStorage` before encoding so RTF never bakes a static RGB.
func richAdaptiveDisplay(_ attr: NSAttributedString) -> NSAttributedString {
    let out = NSMutableAttributedString(attributedString: attr)
    guard out.length > 0 else { return out }
    out.enumerateAttribute(.foregroundColor,
                           in: NSRange(location: 0, length: out.length),
                           options: []) { value, range, _ in
        if value == nil {
            out.addAttribute(.foregroundColor, value: PlatformColor.adaptiveLabel, range: range)
        }
    }
    return out
}

/// Strips the injected dynamic label color back to "missing" (Auto) before
/// persisting. Explicit user colors (static RGB) are left untouched — the
/// check uses dynamic identity, not resolved RGB, so static white in dark
/// mode is not mistaken for Auto.
func richStrippedForStorage(_ attr: NSAttributedString) -> NSAttributedString {
    let out = NSMutableAttributedString(attributedString: attr)
    guard out.length > 0 else { return out }
    out.enumerateAttribute(.foregroundColor,
                           in: NSRange(location: 0, length: out.length),
                           options: []) { value, range, _ in
        if let color = value as? PlatformColor, color.isAdaptiveLabel {
            out.removeAttribute(.foregroundColor, range: range)
        }
    }
    return out
}

/// Maps a foreground attribute to its toolbar hex: missing or dynamic label
/// both mean Auto; anything else is an explicit static color.
private func richHexForToolbar(_ value: Any?) -> String {
    guard let color = value as? PlatformColor else { return Palette.autoInk }
    if color.isAdaptiveLabel { return Palette.autoInk }
    return color.richHexString() ?? Palette.autoInk
}

private func richFontSized(_ font: PlatformFont, size: CGFloat) -> PlatformFont {
    #if os(macOS)
    return NSFontManager.shared.convert(font, toSize: size)
    #else
    return UIFont(descriptor: font.fontDescriptor, size: size)
    #endif
}

private func richDefaultFont(size: CGFloat) -> PlatformFont {
    PlatformFont.systemFont(ofSize: size)
}

private func richTransformFonts(_ attr: NSMutableAttributedString, in range: NSRange,
                               _ transform: (PlatformFont) -> PlatformFont) {
    guard range.length > 0, NSMaxRange(range) <= attr.length else { return }
    attr.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
        let font = (value as? PlatformFont) ?? richDefaultFont(size: 17)
        attr.addAttribute(.font, value: transform(font), range: subrange)
    }
}

// MARK: - Trait helpers

private func richHasTrait(_ font: PlatformFont, _ trait: RichTrait) -> Bool {
    #if os(macOS)
    let traits = NSFontManager.shared.traits(of: font)
    switch trait {
    case .bold: return traits.contains(.boldFontMask)
    case .italic: return traits.contains(.italicFontMask)
    }
    #else
    let traits = font.fontDescriptor.symbolicTraits
    switch trait {
    case .bold: return traits.contains(.traitBold)
    case .italic: return traits.contains(.traitItalic)
    }
    #endif
}

private func richWithTrait(_ font: PlatformFont, _ trait: RichTrait, enabled: Bool) -> PlatformFont {
    #if os(macOS)
    let manager = NSFontManager.shared
    switch trait {
    case .bold:
        return enabled ? manager.convert(font, toHaveTrait: .boldFontMask)
                       : manager.convert(font, toNotHaveTrait: .boldFontMask)
    case .italic:
        return enabled ? manager.convert(font, toHaveTrait: .italicFontMask)
                       : manager.convert(font, toNotHaveTrait: .italicFontMask)
    }
    #else
    var traits = font.fontDescriptor.symbolicTraits
    switch trait {
    case .bold:
        if enabled { traits.insert(.traitBold) } else { traits.remove(.traitBold) }
    case .italic:
        if enabled { traits.insert(.traitItalic) } else { traits.remove(.traitItalic) }
    }
    guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
    return UIFont(descriptor: descriptor, size: font.pointSize)
    #endif
}

/// All-or-clear toggle: removes the trait when every character has it,
/// otherwise applies it to the whole range.
func richToggleTrait(_ attr: NSMutableAttributedString, in range: NSRange, trait: RichTrait) {
    guard range.length > 0, NSMaxRange(range) <= attr.length else { return }
    var allHave = true
    attr.enumerateAttribute(.font, in: range, options: []) { value, _, stop in
        let font = (value as? PlatformFont) ?? richDefaultFont(size: 17)
        if !richHasTrait(font, trait) { allHave = false; stop.pointee = true }
    }
    // Runs without any font attribute count as not having the trait.
    richTransformFonts(attr, in: range) { richWithTrait($0, trait, enabled: !allHave) }
}

private func richToggleFlagAttribute(_ attr: NSMutableAttributedString, in range: NSRange,
                                     key: NSAttributedString.Key) {
    guard range.length > 0, NSMaxRange(range) <= attr.length else { return }
    var allHave = true
    attr.enumerateAttribute(key, in: range, options: []) { value, _, stop in
        if (value as? NSNumber)?.intValue ?? 0 == 0 { allHave = false; stop.pointee = true }
    }
    if allHave {
        attr.removeAttribute(key, range: range)
    } else {
        attr.addAttribute(key, value: NSUnderlineStyle.single.rawValue, range: range)
    }
}

func richToggleUnderline(_ attr: NSMutableAttributedString, in range: NSRange) {
    richToggleFlagAttribute(attr, in: range, key: .underlineStyle)
}

func richToggleStrikethrough(_ attr: NSMutableAttributedString, in range: NSRange) {
    richToggleFlagAttribute(attr, in: range, key: .strikethroughStyle)
}

func richSetFontSize(_ attr: NSMutableAttributedString, in range: NSRange, size: CGFloat) {
    let clamped = min(96, max(8, size))
    richTransformFonts(attr, in: range) { richFontSized($0, size: clamped) }
}

func richNudgeFontSize(_ attr: NSMutableAttributedString, in range: NSRange, delta: CGFloat) {
    richTransformFonts(attr, in: range) { font in
        richFontSized(font, size: min(96, max(8, font.pointSize + delta)))
    }
}

func richSetColor(_ attr: NSMutableAttributedString, in range: NSRange, hex: String) {
    guard range.length > 0, NSMaxRange(range) <= attr.length else { return }
    // Auto = no foreground attribute: renders as adaptive label color and
    // round-trips through RTF, unlike any baked RGB.
    if hex.uppercased() == Palette.autoInk {
        attr.removeAttribute(.foregroundColor, range: range)
        return
    }
    guard let color = PlatformColor.fromRichHex(hex) else { return }
    attr.addAttribute(.foregroundColor, value: color, range: range)
}

func richSetAlignment(_ attr: NSMutableAttributedString, in range: NSRange,
                      alignment: NSTextAlignment) {
    guard range.length > 0, NSMaxRange(range) <= attr.length else { return }
    let paraRange = (attr.string as NSString).paragraphRange(for: range)
    attr.enumerateAttribute(.paragraphStyle, in: paraRange, options: []) { value, subrange, _ in
        let style = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle)
            ?? NSMutableParagraphStyle()
        style.alignment = alignment
        attr.addAttribute(.paragraphStyle, value: style, range: subrange)
    }
}

// MARK: - Inspection (toolbar active states)

private func richFont(of attrs: [NSAttributedString.Key: Any]) -> PlatformFont? {
    attrs[.font] as? PlatformFont
}

/// State for a single attribute dictionary (typing attributes / caret).
func richInspectAttributes(_ attrs: [NSAttributedString.Key: Any]) -> RichTextState {
    var state = RichTextState()
    if let font = richFont(of: attrs) {
        state.bold = richHasTrait(font, .bold)
        state.italic = richHasTrait(font, .italic)
        state.fontSize = font.pointSize
    }
    state.underline = (attrs[.underlineStyle] as? NSNumber)?.intValue ?? 0 != 0
    state.strikethrough = (attrs[.strikethroughStyle] as? NSNumber)?.intValue ?? 0 != 0
    // Missing foreground or dynamic label both mean Auto (adaptive).
    state.colorHex = richHexForToolbar(attrs[.foregroundColor])
    if let para = attrs[.paragraphStyle] as? NSParagraphStyle {
        state.alignment = para.alignment
    }
    return state
}

/// State for a range: a trait is on only when the whole range has it;
/// size/color/alignment are set only when uniform, else nil (mixed).
func richInspect(_ attr: NSAttributedString, in range: NSRange) -> RichTextState {
    var state = RichTextState()
    guard range.length > 0, NSMaxRange(range) <= attr.length else { return state }
    var allBold = true, allItalic = true, allUnderline = true, allStrike = true
    var sizes = Set<CGFloat>(), colors = Set<String>(), aligns = Set<NSTextAlignment>()
    attr.enumerateAttributes(in: range, options: []) { attrs, _, _ in
        let font = richFont(of: attrs) ?? richDefaultFont(size: 17)
        if !richHasTrait(font, .bold) { allBold = false }
        if !richHasTrait(font, .italic) { allItalic = false }
        if (attrs[.underlineStyle] as? NSNumber)?.intValue ?? 0 == 0 { allUnderline = false }
        if (attrs[.strikethroughStyle] as? NSNumber)?.intValue ?? 0 == 0 { allStrike = false }
        sizes.insert(font.pointSize)
        // Missing foreground or dynamic label = Auto (adaptive); participates in uniformity.
        colors.insert(richHexForToolbar(attrs[.foregroundColor]))
        aligns.insert((attrs[.paragraphStyle] as? NSParagraphStyle)?.alignment ?? .left)
    }
    state.bold = allBold
    state.italic = allItalic
    state.underline = allUnderline
    state.strikethrough = allStrike
    if sizes.count == 1 { state.fontSize = sizes.first }
    if colors.count == 1 { state.colorHex = colors.first }
    if aligns.count == 1 { state.alignment = aligns.first }
    return state
}

func richInspectWhole(_ attr: NSAttributedString) -> RichTextState {
    richInspect(attr, in: NSRange(location: 0, length: attr.length))
}
