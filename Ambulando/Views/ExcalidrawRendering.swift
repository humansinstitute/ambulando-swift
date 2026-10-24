import AmbulandoCore
import ImageIO
import SwiftUI

// Native drawing of the supported Excalidraw subset (`ExcalidrawScene`) and of Canvas drawing elements. Scenes are parsed
// and their images decoded off the main actor (`PreparedBoard.prepare`); the main actor only draws prepared values.

/// Decoded, downsampled board images by file id. CGImage is immutable, so sharing it across actors is safe.
struct BoardImages: @unchecked Sendable, Equatable {
    var images: [String: CGImage] = [:]
    static func == (a: BoardImages, b: BoardImages) -> Bool { Set(a.images.keys) == Set(b.images.keys) }

    static let maxPixel = 1024

    static func decode(_ scene: ExcalidrawScene) throws -> BoardImages {
        var out = BoardImages()
        for (id, image) in scene.images {
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithData(image.data as CFData, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                           kCGImageSourceCreateThumbnailWithTransform: true,
                                                                           kCGImageSourceThumbnailMaxPixelSize: maxPixel] as CFDictionary) else { continue }
            out.images[id] = cg
        }
        return out
    }
}

/// A board ready to draw: the parsed scene (or why it cannot be shown) and its decoded images.
struct PreparedBoard: Sendable, Equatable {
    enum State: Sendable, Equatable { case ready, notStored, failed(String) }
    var state: State = .notStored
    var scene = ExcalidrawScene()
    var images = BoardImages()
    var versionId: String?

    /// Runs on the caller's (background) executor; cancellation stops parsing and decoding.
    static func prepare(_ record: BoardSceneRecord?, expected: BoardReference) throws -> PreparedBoard {
        guard let record else { return PreparedBoard() }
        do {
            let scene = try ExcalidrawScene.parse(record.bytes)
            return PreparedBoard(state: .ready, scene: scene, images: try BoardImages.decode(scene),
                                 versionId: record.versionId == expected.versionId ? record.versionId : nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch ExcalidrawScene.ParseError.tooLarge {
            return PreparedBoard(state: .failed("This board is larger than the 24 MB / 20,000 element limit."))
        } catch ExcalidrawScene.ParseError.invalid(let reason) {
            return PreparedBoard(state: .failed(reason))
        }
    }
}

enum BoardColor {
    /// `#rgb`, `#rrggbb`, `#rrggbbaa`; "transparent" and anything unknown are nil.
    static func parse(_ text: String) -> Color? {
        var hex = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
        let (r, g, b, a): (UInt64, UInt64, UInt64, UInt64) = hex.count == 8
            ? (value >> 24 & 0xff, value >> 16 & 0xff, value >> 8 & 0xff, value & 0xff) : (value >> 16 & 0xff, value >> 8 & 0xff, value & 0xff, 0xff)
        return Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}

/// Draws a prepared scene into a rectangle, fitted (with margin) unless a transform is given.
struct ExcalidrawCanvas: View {
    let board: PreparedBoard
    /// World → view transform; nil fits the whole scene.
    var transform: CGAffineTransform?

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let scene = board.scene
            if let background = scene.viewBackgroundColor.flatMap(BoardColor.parse) {
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(background))
            }
            let t = transform ?? Self.fit(scene, in: size)
            for element in scene.elements { draw(element, in: &context, transform: t) }
        }
    }

    static func fit(_ scene: ExcalidrawScene, in size: CGSize, margin: CGFloat = 12) -> CGAffineTransform {
        let w = CGFloat(max(1, scene.maxX - scene.minX)), h = CGFloat(max(1, scene.maxY - scene.minY))
        let minX = CGFloat(scene.minX), minY = CGFloat(scene.minY)
        let s = min((size.width - 2 * margin) / w, (size.height - 2 * margin) / h, 4)
        let ox = (size.width - w * s) / 2 - minX * s, oy = (size.height - h * s) / 2 - minY * s
        return CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: ox, ty: oy)
    }

    private func draw(_ e: ExcalidrawScene.Element, in context: inout GraphicsContext, transform t: CGAffineTransform) {
        var ctx = context
        ctx.opacity = e.opacity
        ctx.concatenate(t)
        let rect = CGRect(x: e.x, y: e.y, width: e.width, height: e.height)
        if e.angle != 0 {
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.rotate(by: .radians(e.angle))
            ctx.translateBy(x: -rect.midX, y: -rect.midY)
        }
        let stroke = BoardColor.parse(e.strokeColor) ?? .black
        let dash: [CGFloat] = e.strokeStyle == "dashed" ? [8, 6] : e.strokeStyle == "dotted" ? [1.5, 5] : []
        let style = StrokeStyle(lineWidth: e.strokeWidth, lineCap: .round, lineJoin: .round, dash: dash)
        let fill = BoardColor.parse(e.backgroundColor).map { e.fillStyle == "solid" ? $0 : $0.opacity(0.35) }
        func shape(_ path: Path) {
            if let fill { ctx.fill(path, with: .color(fill)) }
            ctx.stroke(path, with: .color(stroke), style: style)
        }
        switch e.kind {
        case .rectangle:
            shape(e.rounded ? Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * 0.12) : Path(rect))
        case .ellipse:
            shape(Path(ellipseIn: rect))
        case .diamond:
            var p = Path()
            p.move(to: CGPoint(x: rect.midX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.midY)); p.closeSubpath()
            shape(p)
        case .line, .arrow, .freedraw:
            let points = e.points.map { CGPoint(x: e.x + $0[0], y: e.y + $0[1]) }
            guard points.count >= 2 else { return }
            var p = Path()
            p.addLines(points)
            if e.kind == .line, points.first == points.last, let fill { ctx.fill(p, with: .color(fill)) }
            ctx.stroke(p, with: .color(stroke), style: style)
            if e.kind == .arrow {
                if let head = e.endArrowhead { arrowhead(head, at: points[points.count - 1], from: points[points.count - 2], ctx: &ctx, color: stroke, width: e.strokeWidth) }
                if let head = e.startArrowhead { arrowhead(head, at: points[0], from: points[1], ctx: &ctx, color: stroke, width: e.strokeWidth) }
            }
        case .text:
            let text = Text(e.text ?? "").font(.system(size: e.fontSize)).foregroundStyle(stroke)
            // Centred and right-aligned text is anchored at the box's centre or right edge (Excalidraw stores the box).
            switch e.textAlign {
            case "center": ctx.draw(text, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
            case "right": ctx.draw(text, at: CGPoint(x: rect.maxX, y: rect.midY), anchor: .trailing)
            default: ctx.draw(text, in: rect.insetBy(dx: -2, dy: -2))
            }
        case .image:
            if let id = e.fileId, let image = board.images.images[id] {
                ctx.draw(Image(decorative: image, scale: 1), in: rect)
            } else {
                ctx.stroke(Path(rect), with: .color(.gray), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        case .frame:
            ctx.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(.gray), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
            if let name = e.name, !name.isEmpty {
                ctx.draw(Text(name).font(.system(size: 12)).foregroundStyle(.gray), at: CGPoint(x: rect.minX, y: rect.minY - 4), anchor: .bottomLeading)
            }
        }
    }

    private func arrowhead(_ kind: String, at tip: CGPoint, from previous: CGPoint, ctx: inout GraphicsContext, color: Color, width: Double) {
        let angle = atan2(tip.y - previous.y, tip.x - previous.x)
        let length = max(10, width * 5)
        let left = CGPoint(x: tip.x - length * cos(angle - .pi / 7), y: tip.y - length * sin(angle - .pi / 7))
        let right = CGPoint(x: tip.x - length * cos(angle + .pi / 7), y: tip.y - length * sin(angle + .pi / 7))
        var p = Path()
        switch kind {
        case "triangle", "triangle_outline":
            p.move(to: tip); p.addLine(to: left); p.addLine(to: right); p.closeSubpath()
            if kind == "triangle" { ctx.fill(p, with: .color(color)) } else { ctx.stroke(p, with: .color(color), lineWidth: width) }
        case "dot", "circle", "circle_outline":
            let r = length / 3
            p = Path(ellipseIn: CGRect(x: tip.x - r, y: tip.y - r, width: 2 * r, height: 2 * r))
            if kind == "circle_outline" { ctx.stroke(p, with: .color(color), lineWidth: width) } else { ctx.fill(p, with: .color(color)) }
        case "bar":
            p.move(to: left); p.addLine(to: right)
            ctx.stroke(p, with: .color(color), lineWidth: width)
        default:   // "arrow" and unknown kinds: an open chevron
            p.move(to: left); p.addLine(to: tip); p.addLine(to: right)
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
    }
}

/// Draws Canvas drawing elements (text, shapes, arrows, lines, freehand, frames) at their saved world positions.
struct CanvasElementsLayer: View {
    let elements: [CanvasElement]
    let transform: CGAffineTransform

    var body: some View {
        Canvas { context, _ in
            var ctx = context
            ctx.concatenate(transform)
            for e in elements { draw(e, &ctx) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(_ e: CanvasElement, _ ctx: inout GraphicsContext) {
        let l = e.layout
        let rect = CGRect(x: l.x, y: l.y, width: l.width, height: l.height)
        let ink = Amb.foreground
        let dash: [CGFloat] = e.lineStyle == "dashed" ? [10, 7] : e.lineStyle == "dotted" ? [1, 7] : []
        switch e.kind {
        case .rectangle?: ctx.stroke(Path(roundedRect: rect, cornerRadius: 6), with: .color(ink), lineWidth: 2)
        case .ellipse?: ctx.stroke(Path(ellipseIn: rect), with: .color(ink), lineWidth: 2)
        case .diamond?:
            var p = Path()
            p.move(to: CGPoint(x: rect.midX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.midY)); p.closeSubpath()
            ctx.stroke(p, with: .color(ink), lineWidth: 2)
        case .arrow?, .line?:
            let start = CGPoint(x: l.x + e.start[0], y: l.y + e.start[1]), end = CGPoint(x: l.x + e.end[0], y: l.y + e.end[1])
            var p = Path()
            p.move(to: start)
            if let c = e.curve { p.addQuadCurve(to: end, control: CGPoint(x: l.x + c[0], y: l.y + c[1])) } else { p.addLine(to: end) }
            ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dash))
            let towardsEnd = e.curve.map { CGPoint(x: l.x + $0[0], y: l.y + $0[1]) } ?? start
            let towardsStart = e.curve.map { CGPoint(x: l.x + $0[0], y: l.y + $0[1]) } ?? end
            if e.endArrowhead != "none" { head(at: end, from: towardsEnd, &ctx, ink) }
            if e.startArrowhead != "none" { head(at: start, from: towardsStart, &ctx, ink) }
        case .draw?:
            let points = e.points.map { CGPoint(x: l.x + $0[0], y: l.y + $0[1]) }
            guard points.count >= 2 else { return }
            var p = Path(); p.addLines(points)
            ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        case .text?:
            ctx.draw(Text(e.text ?? "").font(.system(size: e.fontSize)).foregroundStyle(ink), in: rect)
        case .frame?:
            if !e.isGroup { ctx.stroke(Path(roundedRect: rect, cornerRadius: 8), with: .color(Amb.mutedForeground), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])) }
        case nil:
            break
        }
    }

    private func head(at tip: CGPoint, from previous: CGPoint, _ ctx: inout GraphicsContext, _ ink: Color) {
        let angle = atan2(tip.y - previous.y, tip.x - previous.x)
        var p = Path()
        p.move(to: tip)
        p.addLine(to: CGPoint(x: tip.x - 12 * cos(angle - .pi / 7), y: tip.y - 12 * sin(angle - .pi / 7)))
        p.addLine(to: CGPoint(x: tip.x - 12 * cos(angle + .pi / 7), y: tip.y - 12 * sin(angle + .pi / 7)))
        p.closeSubpath()
        ctx.fill(p, with: .color(ink))
    }
}
