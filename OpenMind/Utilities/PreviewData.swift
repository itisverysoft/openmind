import SwiftUI
import SwiftData

@MainActor
enum PreviewData {
    static let container: ModelContainer = {
        let container = try! ModelContainer(
            for: Board.self, CanvasItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let board = Board(title: "Sample Board")
        container.mainContext.insert(board)

        let sticky = CanvasItem(kind: .sticky, x: 4900, y: 4900, text: "Hello OpenMind")
        container.mainContext.insert(sticky)
        sticky.board = board

        let shape = CanvasItem(kind: .shape, shape: .ellipse, x: 5120, y: 4960, text: "Idea")
        container.mainContext.insert(shape)
        shape.board = board

        return container
    }()

    static var board: Board {
        try! container.mainContext.fetch(FetchDescriptor<Board>()).first!
    }
}
