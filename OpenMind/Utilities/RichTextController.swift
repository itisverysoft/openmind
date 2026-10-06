import Combine
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Format actions the text toolbar can request.
enum RichTextAction {
    case bold
    case italic
    case underline
    case strikethrough
    case sizePlus
    case sizeMinus
    case size(CGFloat)
    case color(String)
    case alignment(NSTextAlignment)
}

/// Implemented by the live text editor (writing mode). Selection-aware:
/// formatting applies to the selection, or to typing attributes when the
/// selection is empty so subsequently typed text picks it up.
protocol RichTextEditing: AnyObject {
    func richPerform(_ action: RichTextAction)
}

/// Bridges the native editor and the SwiftUI format toolbar: the editor
/// publishes selection/typing state here, and the toolbar reaches the
/// editor through here while writing.
final class RichTextController: ObservableObject {
    @Published var state = RichTextState()
    weak var editor: (any RichTextEditing)?
}
