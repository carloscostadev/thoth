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

    /// THOTH wordmark on its W1-H grid (219.2 × 40 units, y down), copied from
    /// svg/thoth-wordmark-*.svg: straight strokes as rectangles, the O as two ring arcs,
    /// all cut by the same horizontal gap between y 24.5 and 27.9.
    static let wordmark: CGPath = {
        let path = CGMutablePath()
        for x in [0, 139.2] as [CGFloat] { // T
            path.addRect(CGRect(x: x, y: 0, width: 34, height: 5))
            path.addRect(CGRect(x: x + 14.5, y: 5, width: 5, height: 19.5))
            path.addRect(CGRect(x: x + 14.5, y: 27.9, width: 5, height: 12.1))
        }
        for x in [42, 181.2] as [CGFloat] { // H
            path.addLines(between: [(0, 0), (5, 0), (5, 19.5), (33, 19.5), (33, 0), (38, 0), (38, 24.5), (0, 24.5)]
                .map { CGPoint(x: x + $0.0, y: $0.1) })
            path.closeSubpath()
            path.addRect(CGRect(x: x, y: 27.9, width: 5, height: 12.1))
            path.addRect(CGRect(x: x + 33, y: 27.9, width: 5, height: 12.1))
        }
        // O, upper part: outer arc over the top, then the inner arc back.
        path.move(to: CGPoint(x: 91, y: 24.5))
        addArc(to: path, from: CGPoint(x: 91, y: 24.5), to: CGPoint(x: 131.2, y: 24.5), radius: 20.6, increasing: true)
        path.addLine(to: CGPoint(x: 126.04, y: 24.5))
        addArc(to: path, from: CGPoint(x: 126.04, y: 24.5), to: CGPoint(x: 96.16, y: 24.5), radius: 15.6, increasing: false)
        path.closeSubpath()
        // O, lower part: outer arc under the bottom, then the inner arc back.
        path.move(to: CGPoint(x: 130.12, y: 27.9))
        addArc(to: path, from: CGPoint(x: 130.12, y: 27.9), to: CGPoint(x: 92.08, y: 27.9), radius: 20.6, increasing: true)
        path.addLine(to: CGPoint(x: 97.65, y: 27.9))
        addArc(to: path, from: CGPoint(x: 97.65, y: 27.9), to: CGPoint(x: 124.55, y: 27.9), radius: 15.6, increasing: false)
        path.closeSubpath()
        return path
    }()

    /// Lockup as in svg/thoth-lockup-*.svg: wordmark at 60% scale, origin (61, 20) on the
    /// symbol's grid. Inked area, round caps included.
    static let lockupInkRect = CGRect(x: 19, y: 8.5, width: 173.52, height: 47)
    static let wordmarkOrigin = CGPoint(x: 61, y: 20)
    static let wordmarkScale: CGFloat = 0.6

    /// SVG-style arc between two points on a horizontal chord, centre above the chord
    /// (as in every arc of the O). `increasing` follows the y-down angle direction.
    private static func addArc(to path: CGMutablePath, from a: CGPoint, to b: CGPoint,
                               radius: CGFloat, increasing: Bool) {
        let half = abs(b.x - a.x) / 2
        let center = CGPoint(x: (a.x + b.x) / 2, y: a.y - (radius * radius - half * half).squareRoot())
        path.addArc(center: center, radius: radius,
                    startAngle: atan2(a.y - center.y, a.x - center.x),
                    endAngle: atan2(b.y - center.y, b.x - center.x),
                    clockwise: !increasing)
    }

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

/// The Thoth lockup (symbol + THOTH wordmark); `height` is the symbol's visible height.
struct ThothLockup: View {
    var height: CGFloat

    var body: some View {
        let ink = ThothMark.lockupInkRect
        let scale = height / ink.height
        Canvas { context, _ in
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -ink.minX, y: -ink.minY)
            context.stroke(Path(ThothMark.centerline), with: .foreground,
                           style: StrokeStyle(lineWidth: ThothMark.strokeWidth, lineCap: .round, lineJoin: .round))
            context.translateBy(x: ThothMark.wordmarkOrigin.x, y: ThothMark.wordmarkOrigin.y)
            context.scaleBy(x: ThothMark.wordmarkScale, y: ThothMark.wordmarkScale)
            context.fill(Path(ThothMark.wordmark), with: .foreground)
        }
        .frame(width: ink.width * scale, height: height)
        .accessibilityElement()
        .accessibilityLabel("Thoth")
    }
}
