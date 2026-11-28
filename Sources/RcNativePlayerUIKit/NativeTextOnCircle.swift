import CoreGraphics
import CoreText

#if canImport(RcNativePlayerCore)
  import RcNativePlayerCore
#endif

/// Draws a typeset line along a `DrawTextOnCircle`'s circle, on the UIKit and AppKit canvases.
///
/// Each host typesets the string itself; `NativeSwiftTextOnCircle.glyphs(advances:)` places it.
enum NativeTextOnCircle {
  /// One glyph of a typeset line: its run, its index in the run, its x on the line, its advance.
  private struct LineGlyph {
    let run: CTRun
    let index: CFIndex
    let lineX: CGFloat
    let advance: CGFloat
  }

  /// Draws a line's glyphs along a circle, each centred on its place with its baseline on the arc.
  ///
  /// O(n) in the glyphs.
  ///
  /// - Parameters:
  ///   - line: The typeset string, drawn in its visual order.
  ///   - circle: The circle the core resolved.
  ///   - context: A y-down context.
  static func draw(_ line: CTLine, along circle: NativeSwiftTextOnCircle, in context: CGContext) {
    // Shaped advances, kerning included, as Android's `Paint.measureText` measures them.
    var glyphs: [LineGlyph] = []
    for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
      let count = CTRunGetGlyphCount(run)
      guard count > 0 else { continue }
      var positions = [CGPoint](repeating: .zero, count: count)
      var advances = [CGSize](repeating: .zero, count: count)
      CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
      CTRunGetAdvances(run, CFRange(location: 0, length: count), &advances)
      for index in 0..<count {
        glyphs.append(
          LineGlyph(
            run: run, index: index, lineX: positions[index].x, advance: advances[index].width))
      }
    }
    let placements = circle.glyphs(advances: glyphs.map { Float($0.advance) })
    for (glyph, placement) in zip(glyphs, placements) {
      context.saveGState()
      context.translateBy(x: CGFloat(placement.x), y: CGFloat(placement.y))
      context.rotate(by: CGFloat(placement.rotationRadians))
      // CoreText draws y-up: flip so the glyph stands on the arc.
      context.scaleBy(x: 1, y: -1)
      context.textMatrix = .identity
      // The run draws at its line x: shift so the glyph's centre is on the origin.
      context.textPosition = CGPoint(x: -(glyph.lineX + glyph.advance / 2), y: 0)
      CTRunDraw(glyph.run, context, CFRange(location: glyph.index, length: 1))
      context.restoreGState()
    }
  }
}

extension NativeSwiftDrawCommandSnapshot {
  /// The strings a host typesets for this command every frame, which spend the frame's text
  /// budget as a text component's string does: a `DrawTextOnCircle`'s string, none otherwise.
  var typesetStrings: [String?] { kind == NativeSwiftDrawKind.textOnCircle ? [text] : [] }
}
