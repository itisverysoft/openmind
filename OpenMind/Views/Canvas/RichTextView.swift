import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Shared content plumbing (model <-> display-sized attributed string)

/// Display-sized content for the editor (storage stays in world points).
/// Auto ink (missing foreground in storage) is injected with the dynamic
/// label color here so the focused editor renders white-on-dark /
/// black-on-light, matching the unfocused SwiftUI Text. Stripped back to
/// missing on save (see `richStrippedForStorage`).
func richDisplayContent(for item: CanvasItem, scale: CGFloat) -> NSAttributedString {
    let base = RichTextCodec.decode(item.richTextData)
        ?? RichTextCodec.plainFallback(text: item.text, fontSize: CGFloat(item.fontSize))
    return richAdaptiveDisplay(richTextScaled(base, by: scale))
}

/// Applies a toolbar action to storage at `range`, or derives new typing
/// attributes from a proxy character when the selection is empty (so
/// subsequently typed text picks the formatting up).
func richApplyToStorage(_ storage: NSTextStorage, range: NSRange,
                        typing: inout [NSAttributedString.Key: Any],
                        action: RichTextAction) {
    if range.length > 0 {
        let clamped = NSRange(location: min(range.location, storage.length),
                              length: min(range.length, storage.length - min(range.location, storage.length)))
        guard clamped.length > 0 else { return }
        storage.beginEditing()
        richApplyAction(action, to: storage, range: clamped)
        storage.endEditing()
    } else {
        let proxy = NSMutableAttributedString(string: "x", attributes: typing)
        richApplyAction(action, to: proxy, range: NSRange(location: 0, length: 1))
        typing = proxy.attributes(at: 0, effectiveRange: nil)
    }
}

func richApplyAction(_ action: RichTextAction, to attr: NSMutableAttributedString, range: NSRange) {
    switch action {
    case .bold: richToggleTrait(attr, in: range, trait: .bold)
    case .italic: richToggleTrait(attr, in: range, trait: .italic)
    case .underline: richToggleUnderline(attr, in: range)
    case .strikethrough: richToggleStrikethrough(attr, in: range)
    case .sizePlus: richNudgeFontSize(attr, in: range, delta: 1)
    case .sizeMinus: richNudgeFontSize(attr, in: range, delta: -1)
    case .size(let pointSize): richSetFontSize(attr, in: range, size: pointSize)
    case .color(let hex): richSetColor(attr, in: range, hex: hex)
    case .alignment(let alignment): richSetAlignment(attr, in: range, alignment: alignment)
    }
}

#if os(macOS)

// MARK: - macOS editor (NSTextView)

struct RichTextEditorView: NSViewRepresentable {
    var item: CanvasItem
    var scale: CGFloat
    var controller: RichTextController

    func makeCoordinator() -> MacRichCoordinator {
        MacRichCoordinator(item: item, scale: scale, controller: controller)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeView()
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.update(scale: scale)
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: MacRichCoordinator) {
        coordinator.teardown()
    }
}

final class MacRichCoordinator: NSObject, NSTextViewDelegate, RichTextEditing {
    let item: CanvasItem
    var scale: CGFloat
    let controller: RichTextController
    weak var textView: NSTextView?
    var loadedHash: Int?
    var loadedScale: CGFloat = 1

    init(item: CanvasItem, scale: CGFloat, controller: RichTextController) {
        self.item = item
        self.scale = scale
        self.controller = controller
    }

    func makeView() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true

        let tv = NSTextView()
        tv.isRichText = true
        tv.importsGraphics = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        tv.textColor = .labelColor
        tv.insertionPointColor = .labelColor
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.delegate = self
        if let storage = tv.textStorage {
            storage.setAttributedString(richDisplayContent(for: item, scale: scale))
        }
        tv.setSelectedRange(NSRange(location: tv.string.count, length: 0))
        scroll.documentView = tv

        textView = tv
        loadedHash = item.richTextData.hashValue
        loadedScale = scale
        controller.editor = self
        refreshState()
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func update(scale newScale: CGFloat) {
        scale = newScale
        guard let tv = textView else { return }
        controller.editor = self
        guard loadedHash != item.richTextData.hashValue || loadedScale != newScale else { return }
        // Flush keystrokes first (e.g. zoom changed mid-edit), then reload.
        syncModelFromView()
        let display = richDisplayContent(for: item, scale: newScale)
        let sel = tv.selectedRange
        tv.textStorage?.setAttributedString(display)
        let loc = min(sel.location, display.length)
        tv.setSelectedRange(NSRange(location: loc, length: min(sel.length, display.length - loc)))
        loadedHash = item.richTextData.hashValue
        loadedScale = newScale
        refreshState()
    }

    func teardown() {
        if controller.editor === self { controller.editor = nil }
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        syncModelFromView()
        refreshState()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        refreshState()
    }

    // MARK: RichTextEditing

    func richPerform(_ action: RichTextAction) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        var typing = tv.typingAttributes
        richApplyToStorage(storage, range: tv.selectedRange, typing: &typing, action: action)
        if tv.selectedRange.length == 0 {
            tv.typingAttributes = typing
        }
        syncModelFromView()
        refreshState()
    }

    // MARK: Model sync

    func syncModelFromView() {
        guard let storage = textView?.textStorage else { return }
        let stripped = richStrippedForStorage(NSAttributedString(attributedString: storage))
        let world = richTextUnscaled(stripped, by: scale)
        guard let data = RichTextCodec.encode(world) else { return }
        if data != item.richTextData {
            item.richTextData = data
            if item.text != world.string { item.text = world.string }
        }
        loadedHash = item.richTextData.hashValue
    }

    func refreshState() {
        guard let tv = textView else { return }
        let range = tv.selectedRange
        var state: RichTextState
        if range.length > 0, let storage = tv.textStorage {
            let loc = min(range.location, storage.length)
            let clamped = NSRange(location: loc, length: min(range.length, storage.length - loc))
            state = clamped.length > 0
                ? richInspect(storage, in: clamped)
                : richInspectAttributes(tv.typingAttributes)
        } else {
            state = richInspectAttributes(tv.typingAttributes)
        }
        state.hasSelection = range.length > 0
        if controller.state != state { controller.state = state }
    }
}

#else

// MARK: - iOS editor (UITextView)

struct RichTextEditorView: UIViewRepresentable {
    var item: CanvasItem
    var scale: CGFloat
    var controller: RichTextController

    func makeCoordinator() -> IOSRichCoordinator {
        IOSRichCoordinator(item: item, scale: scale, controller: controller)
    }

    func makeUIView(context: Context) -> UITextView {
        context.coordinator.makeView()
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.update(scale: scale)
    }

    static func dismantleUIView(_ view: UITextView, coordinator: IOSRichCoordinator) {
        coordinator.teardown()
    }
}

final class IOSRichCoordinator: NSObject, UITextViewDelegate, RichTextEditing {
    let item: CanvasItem
    var scale: CGFloat
    let controller: RichTextController
    weak var textView: UITextView?
    var loadedHash: Int?
    var loadedScale: CGFloat = 1

    init(item: CanvasItem, scale: CGFloat, controller: RichTextController) {
        self.item = item
        self.scale = scale
        self.controller = controller
    }

    func makeView() -> UITextView {
        let tv = UITextView()
        tv.backgroundColor = .clear
        tv.textColor = .label
        tv.tintColor = .label
        tv.allowsEditingTextAttributes = true
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .sentences
        tv.delegate = self
        tv.attributedText = richDisplayContent(for: item, scale: scale)
        tv.selectedRange = NSRange(location: tv.text.count, length: 0)
        textView = tv
        loadedHash = item.richTextData.hashValue
        loadedScale = scale
        controller.editor = self
        refreshState()
        DispatchQueue.main.async { tv.becomeFirstResponder() }
        return tv
    }

    func update(scale newScale: CGFloat) {
        scale = newScale
        guard let tv = textView else { return }
        controller.editor = self
        guard loadedHash != item.richTextData.hashValue || loadedScale != newScale else { return }
        syncModelFromView()
        let typing = tv.typingAttributes
        let display = richDisplayContent(for: item, scale: newScale)
        let sel = tv.selectedRange
        tv.attributedText = display
        let loc = min(sel.location, display.length)
        tv.selectedRange = NSRange(location: loc, length: min(sel.length, display.length - loc))
        tv.typingAttributes = typing
        loadedHash = item.richTextData.hashValue
        loadedScale = newScale
        refreshState()
    }

    func teardown() {
        if controller.editor === self { controller.editor = nil }
    }

    // MARK: UITextViewDelegate

    func textViewDidChange(_ textView: UITextView) {
        syncModelFromView()
        refreshState()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        refreshState()
    }

    // MARK: RichTextEditing

    func richPerform(_ action: RichTextAction) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        var typing = tv.typingAttributes
        richApplyToStorage(storage, range: tv.selectedRange, typing: &typing, action: action)
        if tv.selectedRange.length == 0 {
            tv.typingAttributes = typing
        }
        syncModelFromView()
        refreshState()
    }

    // MARK: Model sync

    func syncModelFromView() {
        guard let storage = textView?.textStorage else { return }
        let stripped = richStrippedForStorage(NSAttributedString(attributedString: storage))
        let world = richTextUnscaled(stripped, by: scale)
        guard let data = RichTextCodec.encode(world) else { return }
        if data != item.richTextData {
            item.richTextData = data
            if item.text != world.string { item.text = world.string }
        }
        loadedHash = item.richTextData.hashValue
    }

    func refreshState() {
        guard let tv = textView else { return }
        let range = tv.selectedRange
        var state: RichTextState
        if range.length > 0, let storage = tv.textStorage {
            let loc = min(range.location, storage.length)
            let clamped = NSRange(location: loc, length: min(range.length, storage.length - loc))
            state = clamped.length > 0
                ? richInspect(storage, in: clamped)
                : richInspectAttributes(tv.typingAttributes)
        } else {
            state = richInspectAttributes(tv.typingAttributes)
        }
        state.hasSelection = range.length > 0
        if controller.state != state { controller.state = state }
    }
}

#endif
