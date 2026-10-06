import SwiftUI
import SwiftData

@main
struct OpenMindApp: App {
    var body: some Scene {
        WindowGroup {
            BoardListView()
        }
        .modelContainer(for: [Board.self, CanvasItem.self])
    }
}
