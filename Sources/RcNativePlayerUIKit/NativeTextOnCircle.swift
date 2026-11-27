import CoreGraphics
import CoreText

#if canImport(RcNativePlayerCore)
  import RcNativePlayerCore
#endif

/// Draws a typeset line along a `DrawTextOnCircle`'s circle, for both the UIKit and the AppKit
/// canvas. Each host typesets the string with its own text pipeline (font, colour, fallback);
/// this walks the line's glyphs and the core (`NativeSwiftTextOnCircle.glyphs(advances:)`) decides
/// where each one goes.
enum NativeTextOnCircle {
  /// Draws `line`'s glyphs, in its visual order, each centred on its place on `circle` with its
  /// baseline on the arc and turned to the arc's tangent. `context` is y-down. O(n) in the glyphs.
  static func draw(_ line: CTLine, along circle: NativeSwiftTextOnCircle, in context: CGContext) {
    // One entry per glyph: its run, its index there, where the line set it, and its advance. The
    // arc is cut from the sum of these advances, so it is exactly as long as the walk (kerning and
    // shaping included, as `Paint.measureText` includes them on Android).
    var glyphs: [(run: CTRun, index: CFIndex, x: CGFloat, advance: CGFloat)] = []
    for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
      let count = CTRunGetGlyphCount(run)
      guard count > 0 else { continue }
      var positions = [CGPoint](repeating: .zero, count: count)
      var advances = [CGSize](repeating: .zero, count: count)
      CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
      CTRunGetAdvances(run, CFRange(location: 0, length: count), &advances)
      for index in 0..<count {
        glyphs.append((run, index, positions[index].x, advances[index].width))
      }
    }
    let placements = circle.glyphs(advances: glyphs.map { Float($0.advance) })
    for (glyph, placement) in zip(glyphs, placements) {
      context.saveGState()
      context.translateBy(x: CGFloat(placement.x), y: CGFloat(placement.y))
      context.rotate(by: CGFloat(placement.rotationDegrees) * .pi / 180)
      // CoreText draws y-up: flip so the glyph stands on the arc rather than hanging from it.
      context.scaleBy(x: 1, y: -1)
      context.textMatrix = .identity
      // The run draws the glyph at its line position from here, so this puts its centre on the
      // origin and its baseline on the arc.
      context.textPosition = CGPoint(x: -(glyph.x + glyph.advance / 2), y: 0)
      CTRunDraw(glyph.run, context, CFRange(location: glyph.index, length: 1))
      context.restoreGState()
    }
  }
}
