import Foundation
import Testing

@testable import RcNativePlayerCore

/// `DrawTextOnCircle`'s geometry, against the Kotlin player's `arcForCircleText` and its glyph
/// walker (`RcComposePlayer.kt`), which mirror AndroidX `AndroidPaintContext.drawTextOnCircle`.
@Suite struct NativeSwiftTextOnCircleTests {
  private typealias Alignment = NativeSwiftTextOnCircleAlignment
  private typealias Placement = NativeSwiftTextOnCirclePlacement
  private typealias ValueIndex = NativeSwiftTextOnCircle.ValueIndex

  /// The circle: effective radius 80 round (120, 110), the string pinned at -60°.
  private static let centerX: Float = 120
  private static let centerY: Float = 110
  private static let warp: Float = 10
  private static let effectiveRadius: Float = 80
  private static let startAngle: Float = -60
  private static let degreesPerRadian: Float = 180 / .pi
  /// The arc each of three glyphs covers on that circle, in degrees: uneven, so a walk that
  /// spaced glyphs evenly or measured from the wrong edge lands elsewhere.
  private static let glyphDegrees: [Float] = [20, 30, 10]
  /// Each glyph's advance: its arc's length, `degrees / degreesPerRadian * radius`.
  private static let advances = glyphDegrees.map { $0 / degreesPerRadian * effectiveRadius }
  private static let textWidth = advances.reduce(0, +)
  /// The sweep `textWidth` makes at `effectiveRadius`: 60°.
  private static let sweepDegrees = glyphDegrees.reduce(0, +)

  /// A command's values in `ValueIndex` order; the radius is the operation's own, before warp.
  private static func values(
    centerX: Float = centerX, centerY: Float = centerY, radius: Float = effectiveRadius - warp,
    startAngle: Float = startAngle, warp: Float = warp,
    alignment: Float = Float(Alignment.start), placement: Float = Float(Placement.outside)
  ) -> [Float] {
    var values = [Float](repeating: 0, count: ValueIndex.count)
    values[ValueIndex.centerX] = centerX
    values[ValueIndex.centerY] = centerY
    values[ValueIndex.radius] = radius
    values[ValueIndex.startAngle] = startAngle
    values[ValueIndex.warpRadiusOffset] = warp
    values[ValueIndex.alignment] = alignment
    values[ValueIndex.placement] = placement
    return values
  }

  private func circle(alignment: Int, placement: Int) -> NativeSwiftTextOnCircle? {
    NativeSwiftTextOnCircle(
      values: Self.values(alignment: Float(alignment), placement: Float(placement)))
  }

  /// One alignment and placement, and the angle of each glyph's centre on the circle.
  struct PlacementCase: Sendable, CustomTestStringConvertible {
    let alignment: Int
    let placement: Int
    let centerDegrees: [Float]
    var testDescription: String { "alignment \(alignment), placement \(placement)" }
  }

  /// Derived by hand from `arcForCircleText` and the glyph walk. The arc starts at `startAngle`
  /// (-60°), moved back along the direction of travel by 0, half (30°) or all (60°) of the
  /// sweep for START, CENTER and END. A glyph's centre is the arc start plus the glyphs before it
  /// plus half its own `glyphDegrees`, clockwise (+) OUTSIDE and counter-clockwise (-) INSIDE.
  /// For OUTSIDE START: -60 + 10 = -50, -60 + 20 + 15 = -25, -60 + 50 + 5 = -5.
  static let placementCases: [PlacementCase] = [
    PlacementCase(
      alignment: Alignment.start, placement: Placement.outside, centerDegrees: [-50, -25, -5]),
    PlacementCase(
      alignment: Alignment.center, placement: Placement.outside, centerDegrees: [-80, -55, -35]),
    PlacementCase(
      alignment: Alignment.end, placement: Placement.outside, centerDegrees: [-110, -85, -65]),
    PlacementCase(
      alignment: Alignment.start, placement: Placement.inside, centerDegrees: [-70, -95, -115]),
    PlacementCase(
      alignment: Alignment.center, placement: Placement.inside, centerDegrees: [-40, -65, -85]),
    PlacementCase(
      alignment: Alignment.end, placement: Placement.inside, centerDegrees: [-10, -35, -55]),
  ]

  /// Each glyph sits on the circle at its centre angle, turned to the tangent along the direction
  /// of travel: a quarter turn on from the radius, +90° OUTSIDE and -90° INSIDE.
  @Test(arguments: placementCases)
  func eachGlyphSitsAtItsCentreAngleTurnedToTheTangent(reference: PlacementCase) throws {
    let circle = try #require(
      circle(alignment: reference.alignment, placement: reference.placement))
    let glyphs = circle.glyphs(advances: Self.advances)
    let quarterTurn: Float = reference.placement == Placement.inside ? -90 : 90
    #expect(glyphs.count == reference.centerDegrees.count)
    for (glyph, degrees) in zip(glyphs, reference.centerDegrees) {
      let radians = degrees / Self.degreesPerRadian
      #expect(abs(glyph.x - (Self.centerX + Self.effectiveRadius * cos(radians))) < 1e-3)
      #expect(abs(glyph.y - (Self.centerY + Self.effectiveRadius * sin(radians))) < 1e-3)
      #expect(
        abs(glyph.rotationRadians * Self.degreesPerRadian - (degrees + quarterTurn)) < 1e-3,
        "\(glyph) at \(degrees)°")
    }
  }

  /// The sweep is the text width over the effective radius — the operation's radius plus its warp
  /// offset — in degrees, so the arc is exactly as long as the string.
  @Test func theArcIsAsLongAsTheTextAtTheWarpedRadius() throws {
    let circle = try #require(circle(alignment: Alignment.start, placement: Placement.outside))
    #expect(circle.radius == Self.effectiveRadius)
    let arc = circle.arc(textWidth: Self.textWidth)
    #expect(abs(arc.sweepDegrees - Self.sweepDegrees) < 1e-4)
    #expect(arc.startDegrees == Self.startAngle)
  }

  /// `startAngle` pins the end of the string `alignment` names: CENTER and END walk the start of
  /// the arc back along the direction of travel by half and all of the sweep.
  @Test func alignmentPinsTheNamedEndAtTheStartAngle() throws {
    let expected: [(Int, Float)] = [
      (Alignment.start, Self.startAngle),
      (Alignment.center, Self.startAngle - Self.sweepDegrees / 2),
      (Alignment.end, Self.startAngle - Self.sweepDegrees),
    ]
    for (alignment, start) in expected {
      let circle = try #require(circle(alignment: alignment, placement: Placement.outside))
      #expect(
        abs(circle.arc(textWidth: Self.textWidth).startDegrees - start) < 1e-4, "\(alignment)")
    }
  }

  /// INSIDE is a negative sweep, so the alignment offsets move the start the other way.
  @Test func insidePlacementSweepsBackwards() throws {
    let expected: [(Int, Float)] = [
      (Alignment.start, Self.startAngle),
      (Alignment.center, Self.startAngle + Self.sweepDegrees / 2),
      (Alignment.end, Self.startAngle + Self.sweepDegrees),
    ]
    for (alignment, start) in expected {
      let circle = try #require(circle(alignment: alignment, placement: Placement.inside))
      let arc = circle.arc(textWidth: Self.textWidth)
      #expect(abs(arc.sweepDegrees + Self.sweepDegrees) < 1e-4, "\(alignment)")
      #expect(abs(arc.startDegrees - start) < 1e-4, "\(alignment)")
    }
  }

  /// An alignment or placement outside the wire's values (another byte, or not a whole number)
  /// falls back as the Kotlin player's does: alignment to START, placement to OUTSIDE.
  @Test(arguments: [(7, 9), (.nan, .nan), (.infinity, -.infinity), (1.5, 0.5)] as [(Float, Float)])
  func unknownAlignmentAndPlacementFallBackAsKotlinDoes(alignment: Float, placement: Float) throws {
    let known = try #require(circle(alignment: Alignment.start, placement: Placement.outside))
    let unknown = try #require(
      NativeSwiftTextOnCircle(values: Self.values(alignment: alignment, placement: placement)))
    #expect(unknown.arc(textWidth: Self.textWidth) == known.arc(textWidth: Self.textWidth))
  }

  /// A circle with no area (radius plus warp at or below zero) or a non-finite centre or angle is
  /// not a circle: the operation draws nothing, as AndroidX's and the Kotlin player's do.
  @Test(arguments: [
    values(radius: 0, warp: 0), values(radius: 10, warp: -10), values(radius: -5, warp: 0),
    values(centerX: .nan), values(centerY: .infinity), values(startAngle: .nan),
    values(radius: .nan), Array(values().prefix(ValueIndex.geometryCount)),
  ])
  func anUnusableCircleIsNotOne(values: [Float]) {
    #expect(NativeSwiftTextOnCircle(values: values) == nil)
  }

  /// A trailing zero-advance glyph (a combining mark) sits at the end of the arc and is drawn at
  /// every radius: the arc is the advances' sum itself, so rounding cannot leave it short.
  @Test func aTrailingZeroAdvanceMarkIsNeverDropped() throws {
    let advances: [Float] = [11.3, 9.7, 0]
    for radius in stride(from: Float(40), through: 120, by: 0.25) {
      let circle = try #require(
        NativeSwiftTextOnCircle(values: Self.values(radius: radius, warp: 0)))
      #expect(circle.glyphs(advances: advances).count == advances.count, "radius \(radius)")
    }
  }

  /// A circle too small to give finite angles places nothing rather than NaN positions, even for
  /// a leading negative-advance glyph whose centre falls before the arc's start.
  @Test func aCircleTooSmallForFiniteAnglesPlacesNothing() throws {
    let circle = try #require(
      NativeSwiftTextOnCircle(
        values: Self.values(
          radius: .leastNonzeroMagnitude, warp: 0, alignment: Float(Alignment.end))))
    #expect(circle.glyphs(advances: [-1, 10]).isEmpty)
  }

  /// A string longer than the circle fills one full turn and drops the glyphs whose centre falls
  /// past it, as the path walker drops glyphs that run off its path; an empty or zero-width string
  /// places nothing. This is the one case that does not match the Kotlin player: Compose builds a
  /// sweep over 360° as an arc short of a full turn (3.40 of 6.28 here, placing 2 glyphs), where
  /// Android's `Path.addArc` can draw the whole oval.
  @Test func glyphsPastAFullTurnAreDropped() throws {
    let circle = try #require(NativeSwiftTextOnCircle(values: Self.values(radius: 1, warp: 0)))
    // Circumference 2π ≈ 6.28: centres at 1, 3, 5 fit; 7 and 9 do not.
    #expect(circle.glyphs(advances: [2, 2, 2, 2, 2]).count == 3)
    #expect(circle.glyphs(advances: []).isEmpty)
    #expect(circle.glyphs(advances: [0, 0]).isEmpty)
  }

  /// The alignment and placement bytes are the Kotlin player's `RcDrawTextOnCircle` constants
  /// (which name AndroidX's `Alignment` and `Placement` ordinals); this fails when either side
  /// changes one. `TextOnCircleWireConstantsTests` holds them to the Swift writer.
  @Test func alignmentAndPlacementMatchTheKotlinPlayer() throws {
    let model = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent(
        "rc-player/protocol/src/commonMain/kotlin/ee/schimke/composeai/rcplayer/protocol/RcModel.kt"
      )
    let file = try String(contentsOf: model, encoding: .utf8)
    // Other classes reuse the names (`RcLayoutText.ALIGN_START`), so only this class is read.
    let owner = try #require(file.range(of: "data class RcDrawTextOnCircle("))
    let source = file[owner.upperBound...]
    func kotlin(_ name: String) -> Int? {
      let marker = "const val \(name): Int = "
      return source.range(of: marker).flatMap { range in
        Int(source[range.upperBound...].prefix { $0.isNumber })
      }
    }
    #expect(kotlin("ALIGN_START") == Alignment.start)
    #expect(kotlin("ALIGN_CENTER") == Alignment.center)
    #expect(kotlin("ALIGN_END") == Alignment.end)
    #expect(kotlin("PLACEMENT_OUTSIDE") == Placement.outside)
    #expect(kotlin("PLACEMENT_INSIDE") == Placement.inside)
  }
}
