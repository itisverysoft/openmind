import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Rich-text format bar shown below the selected text box. Box selected:
/// actions apply to the whole box. Writing (cursor focused): actions apply
/// to the text selection, or to typing attributes when nothing is selected
/// so subsequently typed text picks the formatting up.
struct TextFormatToolbar: View {
    var state: RichTextState
    var onAction: (RichTextAction) -> Void = { _ in }

    @State private var showSizePicker = false
    @State private var sizeDraft = ""
    @FocusState private var sizeFieldFocused: Bool

    /// Common preset sizes offered in the dropdown. Direct entry accepts any
    /// value; `richSetFontSize` clamps to 8...96.
    private static let sizePresets: [Int] = [8, 10, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 64, 72, 96]

    var body: some View {
        HStack(spacing: 10) {
            traitButton("B", help: "Bold", active: state.bold) { onAction(.bold) }
                .fontWeight(.bold)
            traitButton("I", help: "Italic", active: state.italic) { onAction(.italic) }
                .italic()
            traitButton("U", help: "Underline", active: state.underline) { onAction(.underline) }
                .underline()
            traitButton("S", help: "Strikethrough", active: state.strikethrough) { onAction(.strikethrough) }
                .strikethrough()

            Divider().frame(height: 22)

            Button { onAction(.sizeMinus) } label: {
                Label("Smaller", systemImage: "textformat.size.smaller")
            }
            .help("Smaller")
            Button {
                sizeDraft = state.fontSize.map { "\(Int($0.rounded()))" } ?? ""
                showSizePicker = true
            } label: {
                HStack(spacing: 2) {
                    Text(sizeLabel)
                        .font(.caption)
                        .monospacedDigit()
                        .frame(minWidth: 24)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .opacity(0.6)
                }
                .contentShape(Rectangle())
            }
            .help("Font size — pick a preset or type a value")
            .popover(isPresented: $showSizePicker) {
                sizePicker
            }
            Button { onAction(.sizePlus) } label: {
                Label("Larger", systemImage: "textformat.size.larger")
            }
            .help("Larger")

            Divider().frame(height: 22)

            Color.autoInkDot(selected: state.colorHex ?? "", diameter: 18) { onAction(.color($0)) }

            ForEach(Palette.inkSwatches, id: \.self) { hex in
                Button { onAction(.color(hex)) } label: {
                    Circle()
                        .fill(Color(hex: hex))
                        .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                        .overlay {
                            if state.colorHex?.uppercased() == hex.uppercased() {
                                Circle().stroke(Color.accentColor, lineWidth: 3).padding(-3)
                            }
                        }
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Text color")
            }

            Divider().frame(height: 22)

            alignButton(.left, systemImage: "text.alignleft", help: "Align left")
            alignButton(.center, systemImage: "text.aligncenter", help: "Align center")
            alignButton(.right, systemImage: "text.alignright", help: "Align right")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .contentShape(Capsule())
        .onTapGesture {} // swallow taps so the canvas doesn't deselect below
    }

    private var sizeLabel: String {
        if let size = state.fontSize { return "\(Int(size.rounded()))" }
        return "••"
    }

    /// Dropdown content: direct numeric entry plus preset sizes.
    private var sizePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField(state.fontSize.map { "\(Int($0.rounded()))" } ?? "Size", text: $sizeDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .focused($sizeFieldFocused)
#if os(iOS)
                    .keyboardType(.numberPad)
#endif
                    .onSubmit { applyDraftSize() }
                Button("Set") { applyDraftSize() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(parsedDraftSize == nil)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 6)], spacing: 6) {
                ForEach(Self.sizePresets, id: \.self) { preset in
                    let isCurrent = state.fontSize.map { Int($0.rounded()) == preset } ?? false
                    Button("\(preset)") {
                        onAction(.size(CGFloat(preset)))
                        showSizePicker = false
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                    .fontWeight(isCurrent ? .bold : .regular)
                    .frame(minWidth: 44, minHeight: 28)
                    .background(isCurrent ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(12)
        .frame(width: 220)
        .onAppear { sizeFieldFocused = true }
    }

    private var parsedDraftSize: CGFloat? {
        let trimmed = sizeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite else { return nil }
        return CGFloat(value)
    }

    private func applyDraftSize() {
        guard let value = parsedDraftSize else { return }
        onAction(.size(value))
        showSizePicker = false
    }

    private func traitButton(_ title: String, help: String, active: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .fontWeight(active ? .bold : .regular)
                .frame(minWidth: 22)
        }
        .help(help)
    }

    private func alignButton(_ alignment: NSTextAlignment, systemImage: String,
                             help: String) -> some View {
        let active = state.alignment == alignment
            || (alignment == .left && state.alignment == nil)
        return Button { onAction(.alignment(alignment)) } label: {
            Label(help, systemImage: systemImage)
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .fontWeight(active ? .semibold : .regular)
        }
        .help(help)
    }
}
