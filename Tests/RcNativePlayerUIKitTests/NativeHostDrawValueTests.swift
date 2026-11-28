import Foundation
import RcNativePlayerTestDocuments
import Testing

@_spi(RemoteComposeController) @testable import RcNativePlayerCore
@testable import RcNativePlayerUIKit

/// Host values in a canvas's draws, from the document through the core snapshot to what the UIKit
/// and AppKit renderers keep (`NativeCanvasCommands.drawable`), as AndroidX's Skia canvas draws
/// them.
@Suite struct NativeHostDrawValueTests {
  typealias Op = NativeSwiftWireOpcode
  static let floatName = "USER:value"
  static let floatID = 70
  static let textID = 80

  /// A canvas whose draws `draw` writes, after a float ``floatName`` at ``floatID`` and a text at
  /// ``textID``.
  static func canvas(_ draw: (NativeTestWire) -> Void) -> Data {
    let wire = NativeTestWire()
    wire.header(width: 100, height: 100)
    wire.u8(Op.dataFloat).int(floatID).float(1)
      .named(floatID, NativeTestWire.NamedType.float, floatName)
    wire.u8(Op.dataText).int(textID).utf8("anchored")
    wire.u8(Op.layoutRoot).int(1).u8(Op.layoutCanvas).int(2).int(-1)
    draw(wire)
    wire.u8(Op.containerEnd).u8(Op.containerEnd)
    return wire.data
  }

  /// The word that reads the float at `id`.
  static func reference(_ id: Int) -> Int { Int(Int32(bitPattern: 0xff80_0000 | UInt32(id))) }

  /// The draws a renderer keeps once the host writes `value` to ``floatName``.
  static func keptDraws(_ document: Data, _ value: Float) throws -> [NativeSwiftDrawCommandSnapshot]
  {
    let session = try NativeSwiftDocumentSession.open(data: document)
    #expect(session.setFloat(value, for: floatName))
    var commands: [NativeSwiftDrawCommandSnapshot] = []
    var pending = [try session.snapshot(timeSeconds: 0).root]
    while let node = pending.popLast() {
      commands += node.commands
      pending += node.children
    }
    return NativeCanvasCommands.drawable(commands)
  }

  /// A `DrawTextAnchored` whose panY a host sets to NaN draws at the anchor's y, as AndroidX's
  /// `DrawTextAnchored.paint` (`Float.isNaN(mOutPanY) ? mOutY : …`, java:252) and the Kotlin
  /// player's `computeAnchoredTextPosition` do; a NaN panX has no such case and draws nothing.
  @Test func aHostNaNPanYDrawsAtTheAnchorAndANaNPanXDrawsNothing() throws {
    let panY = Self.canvas { wire in
      wire.u8(Op.drawTextAnchored).int(Self.textID).float(10).float(20).float(0)
        .int(Self.reference(Self.floatID)).int(0)
    }
    let kept = try Self.keptDraws(panY, .nan)
    let text = try #require(kept.first { $0.kind == NativeSwiftDrawKind.text })
    #expect(text.values[0] == 10 && text.values[1] == 20 && text.values[3].isNaN)
    let panX = Self.canvas { wire in
      wire.u8(Op.drawTextAnchored).int(Self.textID).float(10).float(20)
        .int(Self.reference(Self.floatID)).float(0).int(0)
    }
    #expect(try Self.keptDraws(panX, .nan).allSatisfy { $0.kind != NativeSwiftDrawKind.text })
  }

  /// A host's stroke width as Skia takes it (`SkPaint::setStrokeWidth` keeps the width it had for
  /// one not `>= 0`, SkPaint.cpp:159, and Android's `Paint.setStrokeWidth` calls it): NaN or a
  /// negative width is the reset paint's 0, a hairline; an infinite one strokes nothing, as Skia
  /// rejects its infinite bounds. A fill never reads the width, so it always draws.
  @Test func aHostStrokeWidthStopsOnlyTheStrokesSkiaStops() throws {
    typealias Paint = NativeSwiftPaintCommand
    let document = Self.canvas { wire in
      wire.u8(Op.paintValues).int(3).int(Paint.strokeWidth).int(Self.reference(Self.floatID))
        .int(Paint.style | NativeSwiftPaintStyle.stroke << 16)
      wire.u8(Op.drawRect).float(0).float(0).float(10).float(10)
      wire.u8(Op.paintValues).int(1).int(Paint.style | NativeSwiftPaintStyle.fill << 16)
      wire.u8(Op.drawRect).float(20).float(0).float(30).float(10)
    }
    let cases: [(width: Float, strokes: [Float])] = [
      (.nan, [0]), (-1, [0]), (-.infinity, [0]), (.infinity, []), (2, [2]),
    ]
    for (width, strokes) in cases {
      let rects = try Self.keptDraws(document, width).filter { $0.kind == NativeSwiftDrawKind.rect }
      #expect(rects.filter(\.isStroke).map(\.strokeWidth) == strokes, "\(width)")
      #expect(rects.filter { !$0.isStroke }.count == 1, "\(width): the fill")
    }
  }

  /// `Canvas.drawLine` strokes whatever the paint's style, so a fill paint's infinite width
  /// draws no line, as Skia rejects its bounds and the Kotlin player's `drawLine` takes the width.
  @Test func aLineReadsTheStrokeWidthOfAFillPaint() throws {
    typealias Paint = NativeSwiftPaintCommand
    let document = Self.canvas { wire in
      wire.u8(Op.paintValues).int(3).int(Paint.strokeWidth).int(Self.reference(Self.floatID))
        .int(Paint.style | NativeSwiftPaintStyle.fill << 16)
      wire.u8(Op.drawLine).float(0).float(0).float(10).float(10)
    }
    func lines(_ width: Float) throws -> Int {
      let draws = try Self.keptDraws(document, width)
      return draws.filter { $0.kind == NativeSwiftDrawKind.line }.count
    }
    #expect(try lines(.infinity) == 0)
    #expect(try lines(2) == 1)
  }
}
