import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct BoardListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Board.modifiedAt, order: .reverse) private var boards: [Board]

    @State private var path: [Board] = []
    /// Board under inline rename (its card shows a text field). Nil normally.
    @State private var renameID: UUID?
    @State private var draftTitle = ""
    @FocusState private var renameFocused: UUID?
    @State private var showPDFImporter = false
    @State private var pdfImportFailed = false
    @State private var showVSOMImporter = false
    @State private var vsomImportFailed = false
    /// Document staged for the save panel. Built up front when Export is
    /// tapped (export is an in-memory JSON encode), so the panel never
    /// fails late.
    @State private var exportDoc = VSOMFileDocument()
    @State private var exportTitle = ""
    @State private var showExporter = false
    /// Finder-style selection: click selects, Shift-click selects the range
    /// from the anchor, Cmd-click (macOS) toggles one board. Double-click
    /// opens. Always live — no separate select mode.
    @State private var selection: Set<UUID> = []
    @State private var anchorIndex: Int?
    @State private var showDeleteConfirm = false
    /// In-app About sheet (VerySoft links, maintainer site).
    @State private var showAbout = false    /// Keyboard focus inside the delete-confirmation dialog. Cancel starts
    /// focused; ←/→ moves between the buttons, Enter confirms.
    @FocusState private var deleteDialogFocused: Bool
    /// Highlighted button. Plain state (not AppKit focus) so the ring is
    /// always accurate: buttons alone don't reliably take focus (e.g. with
    /// Full Keyboard Access off), which is what left the sheet with no key
    /// delivery before — the focusable container below fixes that.
    @State private var deleteChoice: DeleteChoice = .cancel
    private static var didPurgeTrash = false

    private var selectedBoards: [Board] {
        boards.filter { selection.contains($0.id) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(boards, id: \.id) { board in
                    Group {
                        if renameID == board.id {
                            // Inline rename: the card becomes a text field
                            // with the current name focused (selected on
                            // macOS). Return commits, Esc cancels.
                            TextField("Title", text: $draftTitle)
                                .focused($renameFocused, equals: board.id)
                                .onSubmit { commitRename() }
                                .onKeyPress(.escape) {
                                    cancelRename()
                                    return .handled
                                }
                                .onAppear {
                                    renameFocused = board.id
                                    selectAllRenameText()
                                }
                                .onChange(of: renameFocused) { old, new in
                                    // Clicking away commits, Finder-style.
                                    if renameID == board.id,
                                       old == board.id, new != board.id {
                                        commitRename()
                                    }
                                }
                                .padding(.vertical, 2)
                        } else {
                            BoardRow(board: board)
                                // Full-row hit target: the frame stretches the
                                // row to the card width so empty space taps
                                // select too, not just the text itself.
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .gesture(
                                    TapGesture(count: 2).onEnded {
                                        openBoard(board)
                                    }
                                    .exclusively(before: TapGesture(count: 1).onEnded {
                                        singleClick(board)
                                    })
                                )
                        }
                    }
                    .listRowBackground(selection.contains(board.id)
                                       ? Color.accentColor.opacity(0.18)
                                       : Color.clear)
                    .contextMenu {
                        Button("Open", systemImage: "arrow.up.right.square") {
                            openBoard(board)
                        }
                        Button("Export…", systemImage: "square.and.arrow.up") {
                            beginExport(board)
                        }
                        Button("Duplicate", systemImage: "plus.square.on.square") {
                            let copy = duplicateBoard(board, in: context)
                            selection = [copy.id]
                            anchorIndex = nil
                        }
                        Button("Rename", systemImage: "pencil") {
                            beginRename(board)
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            context.delete(board)
                        }
                    }
                }
                .onDelete(perform: deleteBoards)
            }
            .overlay {
                if boards.isEmpty {
                    ContentUnavailableView(
                        "No Boards Yet",
                        systemImage: "square.and.pencil",
                        description: Text("Tap + to create your first board.")
                    )
                }
            }
            .navigationTitle(selection.isEmpty ? "OpenMind" : "\(selection.count) Selected")
            .toolbar {
                ToolbarItem {
                    Button("New Board", systemImage: "plus", action: addBoard)
                }
                ToolbarItem {
                    Button("Open PDF", systemImage: "doc.badge.plus") {
                        showPDFImporter = true
                    }
                    .help("Open PDF — every page becomes its own canvas")
                }
                ToolbarItem {
                    Button("Import Board", systemImage: "square.and.arrow.down") {
                        showVSOMImporter = true
                    }
                    .help("Import an OpenMind (.vsom) board file")
                }
                ToolbarItem {
                    Button("About OpenMind", systemImage: "info.circle") {
                        showAbout = true
                    }
                    .help("About OpenMind and VerySoft")
                }
                if !selection.isEmpty {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("Duplicate", systemImage: "plus.square.on.square") {
                            duplicateSelectedBoards()
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            showDeleteConfirm = true
                        }
                    }
                }
            }
            .onKeyPress(keys: ["a"]) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                selection = Set(boards.map(\.id))
                anchorIndex = nil
                return .handled
            }
            .onKeyPress(keys: ["o"]) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                showVSOMImporter = true
                return .handled
            }
            .onKeyPress(.escape) {
                guard !selection.isEmpty else { return .ignored }
                selection = []
                anchorIndex = nil
                return .handled
            }
            .onKeyPress(.delete) { deleteSelectionKeyPress() }
            .onKeyPress(.deleteForward) { deleteSelectionKeyPress() }
            .fileImporter(isPresented: $showPDFImporter,
                          allowedContentTypes: [.pdf],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first,
                          let data = pdfDataFromFileURL(url)
                    else {
                        pdfImportFailed = true
                        return
                    }
                    guard let board = createPDFBoard(data: data,
                                                       fileName: url.lastPathComponent,
                                                       context: context) else {
                        pdfImportFailed = true
                        return
                    }
                    path.append(board)   // open the new page-canvas board
                case .failure:
                    pdfImportFailed = true
                }
            }
            .alert("Couldn't Open PDF", isPresented: $pdfImportFailed) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("That file couldn't be read as a PDF. It may be corrupt, encrypted, or over 100 MB.")
            }
            .fileImporter(isPresented: $showVSOMImporter,
                          allowedContentTypes: [.vsomBoard],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    importBoardFile(at: url)
                case .failure:
                    vsomImportFailed = true
                }
            }
            .onOpenURL { url in
                // Double-clicked / dropped `.vsom` files land here thanks to
                // the document type declaration in Info.plist.
                importBoardFile(at: url)
            }
            .fileExporter(isPresented: $showExporter,
                          document: exportDoc,
                          contentType: .vsomBoard,
                          defaultFilename: vsomDefaultFilename(title: exportTitle)) { _ in }
            .alert("Couldn't Open Board File", isPresented: $vsomImportFailed) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("That file couldn't be read as an OpenMind board. It may be corrupt or from a newer version.")
            }
            .sheet(isPresented: $showDeleteConfirm) {
                deleteConfirmDialog()
            }
            .sheet(isPresented: $showAbout) {
                AboutView()
            }
            .navigationDestination(for: Board.self) { board in
                CanvasView(board: board) {
                    // "Open a board file…" from the canvas Export menu:
                    // back to the list, then show its importer.
                    path = []
                    showVSOMImporter = true
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 700, minHeight: 500)
        #endif
        .withModelUndo()
        .task {
            // Trash from previous launches can never be undone (the undo
            // stack is in-memory), so hard-delete it exactly once. Later
            // appearances (e.g. back-navigation) must NOT purge: this
            // session's undo stack may still reference trashed items.
            if !Self.didPurgeTrash {
                Self.didPurgeTrash = true
                purgeTrash(in: context)
            }
        }
    }

    // MARK: Actions

    private func addBoard() {
        let board = Board(title: "Untitled Board")
        board.applyCanvasDefaults()
        context.insert(board)
        path.append(board)          // open it right away
    }

    // MARK: Board files (.vsom)

    /// Stages `board` for the save panel and presents it.
    private func beginExport(_ board: Board) {
        guard let data = try? exportBoard(board) else { return }
        exportDoc = VSOMFileDocument(data: data)
        exportTitle = board.title
        showExporter = true
    }

    /// Imports a `.vsom` file as a new board, then selects and opens it.
    /// Shared by the Import button and double-click/drop open-URL.
    private func importBoardFile(at url: URL) {
        guard let data = vsomDataFromFileURL(url),
              let board = importBoard(from: data,
                                      fileName: url.lastPathComponent,
                                      context: context)
        else {
            vsomImportFailed = true
            return
        }
        selection = [board.id]
        anchorIndex = nil
        path.append(board)   // open the imported board
    }

    private func deleteBoards(at offsets: IndexSet) {
        for index in offsets {
            context.delete(boards[index])
        }
    }

    // MARK: Selection (click / Shift-click / double-click)

    /// Single click: exclusive select, or range/toggle with modifiers.
    /// Shift extends from the anchor; Cmd (macOS) toggles one board.
    private func singleClick(_ board: Board) {
        guard let index = boards.firstIndex(where: { $0.id == board.id }) else { return }
#if os(macOS)
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), let anchor = anchorIndex, boards.indices.contains(anchor) {
            selection = Set(boards[selectedRange(from: anchor, to: index, count: boards.count)].map(\.id))
            return
        }
        if flags.contains(.command) {
            if selection.contains(board.id) {
                selection.remove(board.id)
            } else {
                selection.insert(board.id)
            }
            anchorIndex = index
            return
        }
#endif
        selection = [board.id]
        anchorIndex = index
    }

    /// Double-click opens the board.
    private func openBoard(_ board: Board) {
        selection = [board.id]
        if let index = boards.firstIndex(where: { $0.id == board.id }) {
            anchorIndex = index
        }
        path.append(board)
    }

    /// Deletes every selected board at once (after the confirmation dialog).
    private func deleteSelectedBoards() {
        for board in selectedBoards {
            context.delete(board)
        }
        selection = []
        anchorIndex = nil
    }

    /// Deletes the selection on Backspace / Forward Delete via the
    /// confirmation dialog below. While renaming, the key belongs to the
    /// title field (it handles the press first, so it never bubbles here);
    /// the guard covers focus being elsewhere.
    private func deleteSelectionKeyPress() -> KeyPress.Result {
        guard renameID == nil, !selection.isEmpty else { return .ignored }
        showDeleteConfirm = true
        return .handled
    }

    /// Delete-confirmation dialog with explicit keyboard control: Cancel
    /// starts highlighted, ←/→ moves between the buttons, Enter confirms.
    private enum DeleteChoice { case cancel, delete }

    private func deleteConfirmDialog() -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text("Delete \(selection.count) \(selection.count == 1 ? "board" : "boards")?")
                    .font(.headline)
                Text("This moves every selected board to the trash.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button("Cancel") {
                    showDeleteConfirm = false
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor,
                                lineWidth: deleteChoice == .cancel ? 2 : 0)
                }
                Button("Delete", role: .destructive) {
                    deleteSelectedBoards()
                    showDeleteConfirm = false
                }
                .buttonStyle(.bordered)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor,
                                lineWidth: deleteChoice == .delete ? 2 : 0)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 300)
        .focusableWithoutRing()
        .focused($deleteDialogFocused)
        .onAppear {
            deleteChoice = .cancel
            deleteDialogFocused = true
        }
        .onKeyPress(.leftArrow) {
            deleteChoice = .cancel
            return .handled
        }
        .onKeyPress(.rightArrow) {
            deleteChoice = .delete
            return .handled
        }
        .onKeyPress(.return) {
            if deleteChoice == .delete {
                deleteSelectedBoards()
            }
            showDeleteConfirm = false
            return .handled
        }
    }

    /// Duplicates every selected board (deep copy with " copy" titles) and
    /// selects the copies on top of the list.
    private func duplicateSelectedBoards() {
        var newIDs = Set<UUID>()
        for board in selectedBoards {
            newIDs.insert(duplicateBoard(board, in: context).id)
        }
        selection = newIDs
        anchorIndex = nil
    }

    // MARK: Inline rename

    /// Starts inline rename: the card becomes a text field holding the
    /// current title. Commits any rename already in flight first.
    private func beginRename(_ board: Board) {
        if renameID != nil { commitRename() }
        draftTitle = board.title
        renameID = board.id
    }

    /// Saves the draft (blank drafts are ignored, like before) and closes
    /// the field. Runs on Return and on focus loss.
    private func commitRename() {
        defer {
            renameID = nil
            renameFocused = nil
        }
        guard let id = renameID,
              let title = validatedBoardTitle(draftTitle),
              let board = boards.first(where: { $0.id == id })
        else { return }
        board.title = title
        board.modifiedAt = .now
    }

    /// Closes the field without saving (Esc).
    private func cancelRename() {
        renameID = nil
        renameFocused = nil
    }

#if os(macOS)
    /// Selects the whole draft so typing replaces the current name.
    private func selectAllRenameText() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
        }
    }
#else
    private func selectAllRenameText() {}
#endif
}

/// Trims a rename draft. Nil when blank — blank renames are ignored.
func validatedBoardTitle(_ draft: String) -> String? {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// Row-index range for Shift-click selection from the anchor to the tapped
/// row. Direction-independent and clamped, so stale anchors can never escape
/// the list.
func selectedRange(from anchor: Int, to tapped: Int, count: Int) -> Range<Int> {
    guard count > 0 else { return 0..<0 }
    let a = min(max(anchor, 0), count - 1)
    let t = min(max(tapped, 0), count - 1)
    return min(a, t)..<max(a, t) + 1
}

private struct BoardRow: View {
    let board: Board

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(board.title)
                .font(.headline)
            Text("\(board.items.filter { !$0.isTrashed }.count) items · \(board.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    BoardListView()
        .modelContainer(PreviewData.container)
}
