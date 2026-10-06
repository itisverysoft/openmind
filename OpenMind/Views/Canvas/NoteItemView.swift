import SwiftUI

/// Collapsed pin-note item (`.note`).
///
/// Lifecycle: the note tool drops a pin on the canvas and opens the editor
/// card immediately. Saving (Done / tap-away) collapses it back to this
/// icon; empty notes are trashed like empty text boxes. Tapping the icon
/// selects it and CanvasView shows the details card; double-tap reopens
/// the editor; hovering previews the text; dragging moves the pin (the
/// parent move gesture — notes never resize).
struct NoteItemView: View {
    @Bindable var item: CanvasItem
    var scale: CGFloat = 1
    var isEditing: Bool = false
    var isSelected: Bool = false

    @State private var isHovering = false

    var body: some View {
        // Fixed on-screen metrics: CanvasItemView renders notes at a
        // constant 32pt with scale=1, so nothing here multiplies by zoom.
        ZStack {
            Circle()
                .fill(Color(hex: item.colorHex))
                .overlay(Circle().stroke(Color.black.opacity(0.2), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
            Image(systemName: item.text.isEmpty ? "plus" : "note.text")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.black.opacity(0.75))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            if isHovering && !isEditing && !isSelected && !item.text.isEmpty {
                // Explicit spacer layout (no alignment-guide math): a clear
                // 32pt pin-height + 8pt gap pushes the card fully below the
                // glyph, so it can never cover it regardless of card height.
                VStack(spacing: 0) {
                    Color.clear.frame(width: 32, height: 40)
                    hoverPreview
                }
                .allowsHitTesting(false)
            }
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }

    /// Quick-look card below the pin while hovering (macOS pointer / iPad
    /// trackpad). Fixed screen size — the pin no longer scales with zoom.
    /// Solid note color like a sticky.
    private var hoverPreview: some View {
        Text(item.text)
            .font(.system(size: 12))
            .foregroundStyle(.black)
            .multilineTextAlignment(.leading)
            .lineLimit(6)
            .truncationMode(.tail)
            .padding(8)
            .frame(width: 190, alignment: .leading)
            .background(Color(hex: item.colorHex), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .allowsHitTesting(false)
    }
}

/// Screen-space details card for the selected pin note: full text plus
/// Edit/Delete. Anchored to the pin by CanvasView (zoom-independent).
/// Styled like a sticky note — solid note color, black text — so the popup
/// matches the yellow sticky in the screenshot instead of a translucent
/// gray material card.
struct NoteDetailsCard: View {
    @Bindable var item: CanvasItem
    var onEdit: () -> Void = {}
    var onDelete: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "pin.fill")
                    .foregroundStyle(.black.opacity(0.6))
                Text("Note")
                    .font(.headline)
                    .foregroundStyle(.black)
                Spacer()
            }
            ScrollView {
                Text(item.text.isEmpty ? ItemKind.note.placeholder : item.text)
                    .font(.system(size: 14))
                    .foregroundStyle(item.text.isEmpty ? .black.opacity(0.45) : .black)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            if !item.isLocked {
                HStack {
                    Button { onEdit() } label: {
                        Label("Edit", systemImage: "square.and.pencil")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.white, in: Capsule())
                            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button { onDelete() } label: {
                        Label("Delete", systemImage: "trash.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.white, in: Capsule())
                            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(width: 260)
        .background(Color(hex: item.colorHex), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color.black.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture {} // swallow taps so the canvas doesn't deselect below
    }
}

/// Screen-space writing UI for pin notes. Text binds straight to the item
/// (like sticky notes); Done collapses the card and the parent's
/// finishEditing persists (or trashes, when empty). Solid note-color
/// background like a sticky note.
struct NoteEditorCard: View {
    @Binding var text: String
    var colorHex: String = Palette.swatches[0]
    var focused: FocusState<Bool>.Binding
    var onDone: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "pin.fill")
                    .foregroundStyle(.black.opacity(0.6))
                Text("Note")
                    .font(.headline)
                    .foregroundStyle(.black)
                Spacer()
                Button("Done") { onDone() }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.75), in: Capsule())
                    .buttonStyle(.plain)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(size: 14))
                    .foregroundStyle(.black)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .frame(height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.black.opacity(0.15), lineWidth: 1))
                    .focused(focused)
                if text.isEmpty {
                    Text(ItemKind.note.placeholder)
                        .font(.system(size: 14))
                        .foregroundStyle(.black.opacity(0.45))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            Text("Tap outside the note to save.")
                .font(.caption)
                .foregroundStyle(.black.opacity(0.55))
        }
        .padding(12)
        .frame(width: 260)
        .background(Color(hex: colorHex), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color.black.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture {} // swallow taps so the canvas doesn't deselect below
        .onAppear { focused.wrappedValue = true }
    }
}
