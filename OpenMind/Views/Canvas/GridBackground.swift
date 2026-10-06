import SwiftUI

/// Canvas background: the active `CanvasPattern`, either across the whole
/// view (`.infinite`) or clipped to the sheet rect. Spacings are in world
/// points so patterns stay put while panning and scale with zoom.
struct GridBackground: View {
    let viewport: Viewport
    var pattern: CanvasPattern = .dots
    /// Sheet in canvas-local screen points. Nil = infinite (full view).
    var sheetScreenRect: CGRect? = nil
    /// Sheet fill luminance (0...1) for legible pattern ink on dark sheets.
    /// Ignored when `sheetScreenRect` is nil.
    var sheetLuminance: Double = 1

    private var ink: Color {
        // Dots keep their historical look on the infinite canvas; on a dark
        // sheet they flip to a light ink so they stay visible.
        if sheetScreenRect == nil { return Color.secondary.opacity(0.35) }
        return sheetLuminance < 0.5 ? Color.white.opacity(0.35) : Color.black.opacity(0.18)
    }

    private var lineInk: Color {
        if sheetScreenRect == nil { return Color.secondary.opacity(0.3) }
        return sheetLuminance < 0.5 ? Color.white.opacity(0.22) : Color.black.opacity(0.12)
    }

    private var strongInk: Color {
        if sheetScreenRect == nil { return Color.secondary.opacity(0.45) }
        return sheetLuminance < 0.5 ? Color.white.opacity(0.35) : Color.black.opacity(0.22)
    }

    var body: some View {
        Canvas { context, size in
            switch pattern {
            case .plain:
                break
            case .dots:
                drawDots(in: &context, viewSize: size)
            case .grid:
                drawGrid(in: &context, viewSize: size, step: 40)
            case .lines:
                drawHorizontalLines(in: &context, viewSize: size, step: 32)
            case .columns:
                drawVerticalLines(in: &context, viewSize: size, step: 120)
            case .graph:
                drawGrid(in: &context, viewSize: size, step: 20)
                drawGrid(in: &context, viewSize: size, step: 100, strong: true)
            }
        }
        .contentShape(Rectangle())   // makes the empty grid area receive gestures
    }

    // MARK: Dots (historical look)

    private func drawDots(in context: inout GraphicsContext, viewSize: CGSize) {
        let baseSpacing: CGFloat = 40
        var spacing = baseSpacing * viewport.scale
        guard spacing >= 10 else { return }   // too dense when zoomed far out
        // Subdivide when zoomed far in so dots don't get too sparse (e.g. at 800%).
        while spacing > 80 { spacing /= 2 }

        let clip = sheetScreenRect
        let startX = viewport.offset.width.truncatingRemainder(dividingBy: spacing) - spacing
        let startY = viewport.offset.height.truncatingRemainder(dividingBy: spacing) - spacing

        var path = Path()
        var x = startX
        while x < viewSize.width + spacing {
            var y = startY
            while y < viewSize.height + spacing {
                if clip == nil || clip!.contains(CGPoint(x: x, y: y)) {
                    path.addEllipse(in: CGRect(x: x - 1.25, y: y - 1.25, width: 2.5, height: 2.5))
                }
                y += spacing
            }
            x += spacing
        }
        context.fill(path, with: .color(ink))
    }

    // MARK: Line patterns (world-aligned)

    /// Screen x positions of world grid lines at `step` intervals.
    private func screenLines(offset: CGFloat, stepWorld: CGFloat, max: CGFloat) -> [CGFloat] {
        let step = stepWorld * viewport.scale
        guard step >= 8 else { return [] }
        // First world multiple visible on screen.
        let firstWorld = floor(viewport.worldPoint(for: .zero).x / stepWorld) * stepWorld
        var out: [CGFloat] = []
        var w = firstWorld
        // Cap iterations so far-zoomed-out views can't loop forever.
        for _ in 0..<2000 {
            let s = w * viewport.scale + offset
            if s > max + step { break }
            if s >= -step { out.append(s) }
            w += stepWorld
            if out.count > 2000 { break }
        }
        return out
    }

    private func drawGrid(in context: inout GraphicsContext, viewSize: CGSize, step: CGFloat, strong: Bool = false) {
        if let clip = sheetScreenRect {
            context.clip(to: Path(clip))
        }
        var path = Path()
        for x in screenLines(offset: viewport.offset.width, stepWorld: step, max: viewSize.width) {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: viewSize.height))
        }
        // Reuse the helper on the vertical axis by swapping roles: worldPoint
        // works per-axis identically, so feed the height offset through.
        let stepPx = step * viewport.scale
        guard stepPx >= 8 else {
            context.stroke(path, with: .color(strong ? strongInk : lineInk), lineWidth: 1)
            return
        }
        let firstWorldY = floor(viewport.worldPoint(for: .zero).y / step) * step
        var wy = firstWorldY
        for _ in 0..<2000 {
            let s = wy * viewport.scale + viewport.offset.height
            if s > viewSize.height + stepPx { break }
            if s >= -stepPx {
                path.move(to: CGPoint(x: 0, y: s))
                path.addLine(to: CGPoint(x: viewSize.width, y: s))
            }
            wy += step
        }
        context.stroke(path, with: .color(strong ? strongInk : lineInk), lineWidth: 1)
    }

    private func drawHorizontalLines(in context: inout GraphicsContext, viewSize: CGSize, step: CGFloat) {
        let stepPx = step * viewport.scale
        guard stepPx >= 8 else { return }
        let firstWorldY = floor(viewport.worldPoint(for: .zero).y / step) * step
        var path = Path()
        var wy = firstWorldY
        for _ in 0..<2000 {
            let s = wy * viewport.scale + viewport.offset.height
            if s > viewSize.height + stepPx { break }
            if s >= -stepPx {
                path.move(to: CGPoint(x: 0, y: s))
                path.addLine(to: CGPoint(x: viewSize.width, y: s))
            }
            wy += step
        }
        // Clip ruled lines to the sheet when one is present.
        if let clip = sheetScreenRect {
            context.clip(to: Path(clip))
        }
        context.stroke(path, with: .color(lineInk), lineWidth: 1)
    }

    private func drawVerticalLines(in context: inout GraphicsContext, viewSize: CGSize, step: CGFloat) {
        var path = Path()
        for x in screenLines(offset: viewport.offset.width, stepWorld: step, max: viewSize.width) {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: viewSize.height))
        }
        if let clip = sheetScreenRect {
            context.clip(to: Path(clip))
        }
        context.stroke(path, with: .color(lineInk), lineWidth: 1)
    }
}
