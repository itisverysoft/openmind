import Combine
import SwiftData
import SwiftUI

/// Shares the view/window undo manager with the SwiftData context so every
/// committed model change becomes undoable, and refreshes the Undo/Redo
/// buttons whenever the undo stack changes.
///
/// Apply once per screen that mutates the model: `.withModelUndo()`
struct ModelUndoModifier: ViewModifier {
    @Environment(\.modelContext) private var context
    @Environment(\.undoManager) private var viewUndoManager
    @State private var revision = 0

    func body(content: Content) -> some View {
        content
            .onAppear(perform: attach)
            .onReceive(undoDidChange) { _ in revision += 1 }
    }

    private func attach() {
        // Prefer the window's manager so the system Edit menu and Cmd+Z
        // target the same stack; fall back to a private one (previews,
        // windows without an undo manager).
        if let viewUndoManager {
            context.undoManager = viewUndoManager
        } else if context.undoManager == nil {
            context.undoManager = UndoManager()
        }
        revision += 1
    }

    /// Fires when groups open/close or an undo/redo lands — i.e. whenever
    /// `canUndo`/`canRedo` may have changed. Views that render undo state
    /// outside this modifier's content (e.g. toolbars) should observe
    /// `ModelUndoModifier.undoChangePublisher` into their own state, since
    /// this modifier's internal refresh cannot rebuild its parent's views.
    static var undoChangePublisher: AnyPublisher<Void, Never> {
        let center = NotificationCenter.default
        return Publishers.MergeMany(
            center.publisher(for: .NSUndoManagerCheckpoint),
            center.publisher(for: .NSUndoManagerDidCloseUndoGroup),
            center.publisher(for: .NSUndoManagerDidUndoChange),
            center.publisher(for: .NSUndoManagerDidRedoChange)
        )
        .map { _ in () }
        .eraseToAnyPublisher()
    }

    /// Fires when groups open/close or an undo/redo lands — i.e. whenever
    /// `canUndo`/`canRedo` may have changed.
    private var undoDidChange: AnyPublisher<Void, Never> {
        Self.undoChangePublisher
    }
}

extension View {
    func withModelUndo() -> some View {
        modifier(ModelUndoModifier())
    }
}

/// Hard-deletes every soft-deleted (`CanvasItem.isTrashed`) object. Only
/// safe when no undo stack can still reference them — i.e. once at app
/// launch. Registration is disabled so the purge itself is never undoable.
func purgeTrash(in context: ModelContext) {
    let manager = context.undoManager
    manager?.disableUndoRegistration()
    defer { manager?.enableUndoRegistration() }
    let trashed = (try? context.fetch(FetchDescriptor<CanvasItem>(
        predicate: #Predicate { $0.isTrashed }
    ))) ?? []
    for item in trashed {
        context.delete(item)
    }
    if !trashed.isEmpty {
        try? context.save()
    }
}
