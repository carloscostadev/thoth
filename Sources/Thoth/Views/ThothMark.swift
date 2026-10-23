import SwiftUI
import AppKit

/// Thoth mark 1.1 (brand/thoth-marca-v2 in the landing repo): symbol T2 on a
/// 64 × 64 grid, 5-unit stroke, round caps and joins. Drawn in code so the app
/// bundle needs no resources. Path copied from svg/thoth-symbol-*.svg:
/// `M42.5 11V38.1M42.5 46.5V53M27 18L42.5 32M21.5 32H42.5M27 46L42.5 32`.
enum ThothMark {
    /// Inked area on the 64-unit grid, round caps included (y down).
    static let inkRect = CGRect(x: 19, y: 8.5, width: 26, height: 47)
    static let strokeWidth: CGFloat = 5

    /// Width of the mark for a given visible (ink) height.
    static func width(forHeight height: CGFloat) -> CGFloat {
        height * inkRect.width / inkRect.height
    }

    /// Centre line of the symbol in grid units (y down).
    static let centerline: CGPath = {
        let segments: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 42.5, y: 11), CGPoint(x: 42.5, y: 38.1)),
            (CGPoint(x: 42.5, y: 46.5), CGPoint(x: 42.5, y: 53)),
            (CGPoint(x: 27, y: 18), CGPoint(x: 42.5, y: 32)),
            (CGPoint(x: 21.5, y: 32), CGPoint(x: 42.5, y: 32)),
            (CGPoint(x: 27, y: 46), CGPoint(x: 42.5, y: 32)),
        ]
        let path = CGMutablePath()
        for (start, end) in segments {
            path.move(to: start)
            path.addLine(to: end)
        }
        return path
    }()

    /// Menu bar icon while Claude Code is working.
    static let menuBarImage = makeMenuBarImage(opacity: 1)
    /// Menu bar icon while Claude Code is asleep: the same mark, dimmed.
    static let menuBarImageDimmed = makeMenuBarImage(opacity: 0.45)

    /// Template image (follows light/dark and the highlight; a template's alpha is kept, so
    /// `opacity` dims it), 16 pt of ink in an 11 × 18 pt canvas. Drawn by a handler at the
    /// backing scale, so it is sharp at 1x and 2x. The main stem's left edge and the
    /// crossbar's top edge sit on whole points.
    private static func makeMenuBarImage(opacity: CGFloat) -> NSImage {
        let inkHeight: CGFloat = 16
        let scale = inkHeight / inkRect.height
        // Stem left edge and crossbar top edge are both 21 units into the ink.
        let snap = (21 * scale).rounded(.up) - 21 * scale
        let image = NSImage(size: NSSize(width: 11, height: 18), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.translateBy(x: snap, y: snap)
            draw(in: ctx, scale: scale, color: CGColor(gray: 0, alpha: opacity))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Thoth"
        return image
    }

    /// Strokes the mark with its ink box at the context origin (context must be y-down).
    static func draw(in ctx: CGContext, scale: CGFloat, color: CGColor) {
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -inkRect.minX, y: -inkRect.minY)
        ctx.addPath(centerline)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(strokeWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()
    }
}

/// The symbol's centre line mapped onto `rect` (the ink box); stroke it with `ThothGlyph`.
struct ThothMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = rect.height / ThothMark.inkRect.height
        let transform = CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -ThothMark.inkRect.minX, y: -ThothMark.inkRect.minY)
        return Path(ThothMark.centerline).applying(transform)
    }
}

/// The Thoth symbol at a given visible height, in the current foreground style.
struct ThothGlyph: View {
    var height: CGFloat

    var body: some View {
        let scale = height / ThothMark.inkRect.height
        ThothMarkShape()
            .stroke(style: StrokeStyle(lineWidth: ThothMark.strokeWidth * scale,
                                       lineCap: .round, lineJoin: .round))
            .frame(width: ThothMark.width(forHeight: height), height: height)
            .accessibilityLabel("Thoth")
    }
}
