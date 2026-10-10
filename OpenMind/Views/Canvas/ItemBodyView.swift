import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ItemBodyView: View {
    @Bindable var item: CanvasItem
    /// Current zoom. Everything that has a size is multiplied by this so it is
    /// drawn at its real on-screen size (sharp at any zoom).
    var scale: CGFloat = 1
    var isEditing: Bool = false
    var isSelected: Bool = false
    /// Set for `.text` items so writing mode uses the rich editor.
    var richController: RichTextController?
    var onCommit: () -> Void = {}
    /// Lifted table cell selection (CanvasView-owned). Only `.table` reads it.
    var tableSelection: Binding<Set<TableCellRef>> = .constant([])
    var tableAnchor: Binding<TableCellRef?> = .constant(nil)
    var tableShiftHeld: Bool = false

    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            background
            label
        }
    }

    // MARK: Background

    @ViewBuilder
    private var background: some View {
        let fill = Color(hex: item.colorHex)
        switch item.kind {
        case .sticky:
            RoundedRectangle(cornerRadius: 6 * scale)
                .fill(fill)
                .shadow(color: .black.opacity(0.2), radius: 3 * scale, y: 2 * scale)
        case .text:
            Color.clear
        case .drawing:
            DrawingStrokeView(points: item.strokePoints,
                              style: item.strokeStyle,
                              colorHex: item.colorHex,
                              lineWidth: CGFloat(item.lineWidth),
                              scale: scale)
        case .shape:
            switch item.shape {
            case .rectangle:        styled(Rectangle(), fill: fill)
            case .roundedRectangle: styled(RoundedRectangle(cornerRadius: 16 * scale), fill: fill)
            case .ellipse:          styled(Ellipse(), fill: fill)
            case .capsule:          styled(Capsule(), fill: fill)
            case .triangle:         styled(TriangleShape(), fill: fill)
            case .rightTriangle:    styled(RightTriangleShape(), fill: fill)
            case .diamond:          styled(DiamondShape(), fill: fill)
            case .pentagon:         styled(PentagonShape(), fill: fill)
            case .hexagon:          styled(HexagonShape(), fill: fill)
            case .circle:           styled(Circle(), fill: fill)
            case .star:             styled(StarShape(), fill: fill)
            case .cloud:            styled(CloudShape(), fill: fill)
            case .line:             shapeEndpoints(kind: .line, fill: fill)
            case .arrow:            shapeEndpoints(kind: .arrow, fill: fill)
            case .doubleArrow:      shapeEndpoints(kind: .doubleArrow, fill: fill)
            }
        case .image:
            imageBackground
        case .audio:
            AudioItemView(item: item, scale: scale)
        case .video:
            VideoItemView(item: item, scale: scale)
        case .youtube:
            YouTubeItemView(item: item, scale: scale, isEditing: isEditing,
                            onCommit: onCommit)
        case .pdf:
            pdfBackground
        case .table:
            TableItemView(item: item, scale: scale, isEditing: isEditing,
                          isSelected: isSelected, shiftHeld: tableShiftHeld,
                          selectedCells: tableSelection, anchorCell: tableAnchor,
                          onCommit: onCommit)
        case .note:
            NoteItemView(item: item, scale: scale, isEditing: isEditing,
                         isSelected: isSelected)
        }
    }

    private var imageBackground: some View {
        let corner = 6 * scale
        return ZStack {
            RoundedRectangle(cornerRadius: corner)
                .fill(Color.gray.opacity(0.15))
            // Cached decode (not `makePlatformImage(from:)`): view bodies
            // must never re-decode every image on each selection change.
            if let platform = ImageResourceCache.platformImage(forItem: item.id, data: item.imageData) {
                platformImageFill(platform)
            } else {
                VStack(spacing: 4 * scale) {
                    Image(systemName: "photo")
                        .font(.system(size: 28 * scale))
                    Text(item.imageData == nil ? "Image" : "Couldn't load image")
                        .font(.system(size: 12 * scale))
                }
                .foregroundStyle(.secondary)
            }
        }
        // Clip the whole tile (not just the image) so nothing can spill
        // past the frame when the frame and photo aspects differ.
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .overlay(
            RoundedRectangle(cornerRadius: corner)
                .stroke(Color.black.opacity(0.15), lineWidth: max(0.5, scale))
        )
        .shadow(color: .black.opacity(0.2), radius: 3 * scale, y: 2 * scale)
    }

    /// Paper tile for `.pdf` items: the displayed page rasterized on demand
    /// (sharp at any zoom via the render cache), with a document glyph while
    /// the bytes are missing or unreadable. Annotations are separate canvas
    /// items drawn above, so the full toolbar works over the page.
    private var pdfBackground: some View {
        let corner = 6 * scale
        return ZStack {
            RoundedRectangle(cornerRadius: corner)
                .fill(Color.white)
            // Cached count (not `pdfPageCount(data)`): view bodies must never
            // re-parse the document on every selection change. Invalid PDFs
            // yield 0 and fall through to the placeholder below.
            if let data = item.pdfData, item.pdfCount > 0 {
                PDFPageImage(cacheKey: item.id.uuidString,
                             data: data,
                             page: item.clampedPDFPage,
                             pointSize: CGSize(width: CGFloat(item.width),
                                               height: CGFloat(item.height)),
                             zoom: scale)
            } else {
                VStack(spacing: 4 * scale) {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 28 * scale))
                    Text(item.pdfData == nil ? "PDF" : "Couldn't load PDF")
                        .font(.system(size: 12 * scale))
                }
                .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .overlay(
            RoundedRectangle(cornerRadius: corner)
                .stroke(Color.black.opacity(0.15), lineWidth: max(0.5, scale))
        )
        .shadow(color: .black.opacity(0.2), radius: 3 * scale, y: 2 * scale)
    }

    /// Fill the tile and crop the overflow. `scaledToFill` scales the
    /// *content* (frame stays tile-sized); `aspectRatio(.fill)` would resize
    /// the *view itself* past the tile and `clipped()` would then clip to
    /// the oversized view — the overflow seen in the screenshot.
    @ViewBuilder
    private func platformImageFill(_ platform: PlatformImage) -> some View {#if os(macOS)
        Image(nsImage: platform)
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
#else
        Image(uiImage: platform)
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
#endif
    }

    private func styled<S: Shape>(_ shape: S, fill: Color) -> some View {
        shape
            .fill(fill)
            .overlay(shape.stroke(Color.black.opacity(0.2), lineWidth: max(0.5, scale)))
    }

    /// Point-to-point line/arrow rendering. New items carry normalized
    /// box-fraction endpoints (`lineEndpoints`) so lines run any direction;
    /// legacy items (empty endpoints) fall back to the fixed diagonal.
    private func shapeEndpoints(kind: ShapeKind, fill: Color) -> some View {
        GeometryReader { geo in
            let ends = lineEnds(points: item.lineEndpoints, in: geo.size)
            let angle = atan2(ends.tip.y - ends.tail.y, ends.tip.x - ends.tail.x)
            let len = hypot(ends.tip.x - ends.tail.x, ends.tip.y - ends.tail.y)
            let headSize = min(max(len * 0.25, 24), 120)
            let showTipHead = (kind == .arrow || kind == .doubleArrow) && len > 0.5
            let showTailHead = kind == .doubleArrow && len > 0.5
            ZStack {
                Path { p in
                    p.move(to: ends.tail)
                    p.addLine(to: ends.tip)
                }
                .stroke(fill, style: StrokeStyle(lineWidth: max(2 * scale, 2), lineCap: .round))
                if showTipHead {
                    ShapeArrow.head(tip: ends.tip, angle: angle, size: headSize).fill(fill)
                }
                if showTailHead {
                    ShapeArrow.head(tip: ends.tail, angle: angle + .pi, size: headSize).fill(fill)
                }
            }
        }
    }

    /// Screen-space endpoints from normalized fractions (or the legacy
    /// fixed diagonal when the item predates endpoint storage).
    private func lineEnds(points: [CGPoint], in size: CGSize) -> (tail: CGPoint, tip: CGPoint) {
        if points.count >= 2 {
            return (CGPoint(x: points[0].x * size.width, y: points[0].y * size.height),
                    CGPoint(x: points[1].x * size.width, y: points[1].y * size.height))
        }
        let rect = CGRect(origin: .zero, size: size)
        return (ShapeArrow.tailBottomLeft(in: rect), ShapeArrow.tipTopRight(in: rect))
    }

    // MARK: Text

    @ViewBuilder
    private var label: some View {
        if item.kind == .table || item.kind == .note || item.kind == .youtube || item.kind == .video {
            EmptyView()
        } else if item.kind.isTextEditable {
            textContent
        }
    }

    private var textContent: some View {
        Group {
            if isEditing && !item.isLocked && item.kind == .text, let controller = richController {
                // Writing mode: native rich editor with cursor + selection.
                RichTextEditorView(item: item, scale: scale, controller: controller)
            } else if item.kind == .text, !isEditing, richDisplayText != nil {
                richUnfocusedView
            } else if isEditing && !item.isLocked {
                TextEditor(text: $item.text)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .onAppear { focused = true }
                    .font(.system(size: CGFloat(item.fontSize) * scale))
                    .multilineTextAlignment(item.kind == .shape ? .center : .leading)
                    .foregroundStyle(item.kind == .text ? Color.primary : Color.black)
            } else {
                Text(item.text.isEmpty ? item.kind.placeholder : item.text)
                    .opacity(item.text.isEmpty ? 0.35 : 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: textAlignment)
                    .font(.system(size: CGFloat(item.fontSize) * scale))
                    .multilineTextAlignment(item.kind == .shape ? .center : .leading)
                    .foregroundStyle(item.kind == .text ? Color.primary : Color.black)
            }
        }
        .padding(10 * scale)
        .clipped()
    }

    /// Zoom-scaled attributed text for display. Nil for empty legacy items
    /// so the placeholder branch renders instead.
    private var richDisplayText: AttributedString? {
        guard item.kind == .text,
              !item.richTextData.isEmpty || !item.text.isEmpty else { return nil }
        let base = RichTextCodec.decode(item.richTextData)
            ?? RichTextCodec.plainFallback(text: item.text, fontSize: CGFloat(item.fontSize))
        let scaled = richTextScaled(base, by: scale)
        return AttributedString(scaled)
    }

    /// Uniform paragraph alignment for the whole box (nil when mixed/empty).
    /// SwiftUI `Text(AttributedString)` ignores the NSParagraphStyle alignment
    /// from the RTF storage, so the unfocused display must re-apply it via
    /// `multilineTextAlignment` — otherwise center/right only show while the
    /// native editor (focused mode) is active.
    private var richUniformAlignment: NSTextAlignment? {
        guard item.kind == .text else { return nil }
        let base = RichTextCodec.decode(item.richTextData)
            ?? RichTextCodec.plainFallback(text: item.text, fontSize: CGFloat(item.fontSize))
        guard base.length > 0 else { return nil }
        return richInspectWhole(base).alignment
    }

    private var richTextAlignment: TextAlignment {
        switch richUniformAlignment {
        case .center: return .center
        case .right: return .trailing
        default: return .leading
        }
    }

    private var richFrameAlignment: Alignment {
        switch richUniformAlignment {
        case .center: return .center
        case .right: return .trailing
        default: return .leading
        }
    }

    // MARK: Unfocused rich display (WYSIWYG without the editor)

    private struct RichPara {
        let text: AttributedString
        let textAlign: TextAlignment
        let frameAlign: Alignment
        let isBlank: Bool
        let fontSize: CGFloat
    }

    @ViewBuilder
    private var richUnfocusedView: some View {
        if richUniformAlignment != nil, let attributed = richDisplayText {
            // Common case: whole box shares one alignment.
            Text(attributed)
                .multilineTextAlignment(richTextAlignment)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: richFrameAlignment)
        } else {
            // Mixed per-paragraph alignments: one row per paragraph so each
            // keeps its own center/left/right outside focused mode.
            let paras = richParagraphs
            VStack(alignment: .leading, spacing: 0) {
                ForEach(paras.indices, id: \.self) { i in
                    if paras[i].isBlank {
                        Text(" ")
                            .font(.system(size: paras[i].fontSize))
                            .frame(maxWidth: .infinity, alignment: paras[i].frameAlign)
                    } else {
                        Text(paras[i].text)
                            .multilineTextAlignment(paras[i].textAlign)
                            .frame(maxWidth: .infinity, alignment: paras[i].frameAlign)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// One entry per paragraph with its own alignment, for mixed-alignment
    /// boxes. Uniform boxes use the single-Text fast path above.
    private var richParagraphs: [RichPara] {
        guard item.kind == .text else { return [] }
        let base = RichTextCodec.decode(item.richTextData)
            ?? RichTextCodec.plainFallback(text: item.text, fontSize: CGFloat(item.fontSize))
        guard base.length > 0 else { return [] }
        var out: [RichPara] = []
        let nsStr = base.string as NSString
        var loc = 0
        while loc < base.length {
            let paraRange = nsStr.paragraphRange(for: NSRange(location: loc, length: 0))
            guard paraRange.length > 0 else { break }
            let sub = base.attributedSubstring(from: paraRange)
            let align = (sub.length > 0
                ? (sub.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.alignment
                : nil) ?? .left
            let rawSize = (sub.length > 0
                ? (sub.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont)?.pointSize
                : nil) ?? CGFloat(item.fontSize)
            // Display without the paragraph's trailing newline; blank lines
            // become a spacersized row so they don't collapse in the VStack.
            let mutable = NSMutableAttributedString(attributedString: sub)
            if mutable.string.hasSuffix("\n") {
                mutable.deleteCharacters(in: NSRange(location: mutable.length - 1, length: 1))
            }
            let isBlank = mutable.length == 0
            let textAlign: TextAlignment = align == .center ? .center : (align == .right ? .trailing : .leading)
            let frameAlign: Alignment = align == .center ? .center : (align == .right ? .trailing : .leading)
            let attrStr: AttributedString
            if isBlank {
                attrStr = AttributedString("")
            } else {
                attrStr = AttributedString(richTextScaled(mutable, by: scale))
            }
            out.append(RichPara(text: attrStr, textAlign: textAlign, frameAlign: frameAlign,
                                isBlank: isBlank, fontSize: rawSize * scale))
            loc = NSMaxRange(paraRange)
        }
        return out
    }

    private var textAlignment: Alignment {
        switch item.kind {
        case .sticky: return .topLeading
        case .text:   return .leading
        case .shape:  return .center
        case .drawing, .image, .table, .note, .pdf, .audio, .youtube, .video: return .center
        }
    }
}
