import Foundation
import Testing

@testable import RcNativePlayerCore

/// `DrawTextOnCircle`'s geometry, against the Kotlin player's `arcForCircleText` and its glyph
/// walker (`RcComposePlayer.kt`), which mirror AndroidX `AndroidPaintContext.drawTextOnCircle`.
@Suite struct NativeSwiftTextOnCircleTests {
  private typealias Alignment = NativeSwiftTextOnCircleAlignment
  private typealias Placement = NativeSwiftTextOnCirclePlacement
  private typealias ValueIndex = NativeSwiftTextOnCircle.ValueIndex

  /// Five glyph advances laid on a circle of effective radius 80 round (120, 110), pinned at -60°.
  private static let advances: [Float] = [10, 12, 8, 14, 9]
  private static let textWidth = advances.reduce(0, +)
  private static let centerX: Float = 120
  private static let centerY: Float = 110
  private static let warp: Float = 10
  private static let effectiveRadius: Float = 80
  private static let startAngle: Float = -60
  private static let degreesPerRadian: Float = 180 / .pi
  /// The sweep `textWidth` makes at `effectiveRadius`, in degrees.
  private static let sweepDegrees = textWidth / effectiveRadius * degreesPerRadian

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

  /// One Kotlin case: an alignment, a placement and the glyphs the Kotlin player placed.
  struct KotlinCase: Sendable, CustomTestStringConvertible {
    let alignment: Int
    let placement: Int
    let glyphs: [(x: Float, y: Float, degrees: Float)]
    var testDescription: String { "alignment \(alignment), placement \(placement)" }
  }

  /// Glyph centres and rotations the Kotlin player computes for the same circle and advances:
  /// `arcForCircleText` measured by `RcPathMeasure`, read at each glyph's centre as
  /// `drawTextSegmentsOnPath` reads it (a temporary jvmTest printed them). Compose builds the arc
  /// from cubics, which `RcPathMeasure` finds 0.1% short of the true arc (52.94 for 53 here), so
  /// its later glyphs run up to 0.08 pt and 0.06° ahead of the true circle the Swift player walks;
  /// 0.15 pt and 0.1° is that approximation, not slack in the arithmetic.
  static let kotlinCases: [KotlinCase] = [
    KotlinCase(
      alignment: Alignment.start, placement: Placement.outside,
      glyphs: [
        (164.22662, 43.336617, 33.561558), (172.97351, 50.051617, 41.46548),
        (180.04732, 57.13868, 48.64165), (186.73883, 65.88732, 56.53631),
        (192.38486, 75.93489, 64.79781),
      ]),
    KotlinCase(
      alignment: Alignment.center, placement: Placement.outside,
      glyphs: [
        (140.1417, 32.577053, 14.582335), (150.59695, 36.08229, 22.48625),
        (159.5911, 40.483494, 29.662413), (168.76413, 46.580284, 37.557087),
        (177.37094, 54.245396, 45.818584),
      ]),
    KotlinCase(
      alignment: Alignment.end, placement: Placement.outside,
      glyphs: [
        (113.86682, 30.235445, -4.3968964), (124.89369, 30.149813, 3.5070307),
        (134.83028, 31.386618, 10.683196), (145.48743, 34.168667, 18.577862),
        (156.11923, 38.61793, 26.839375),
      ]),
    KotlinCase(
      alignment: Alignment.start, placement: Placement.inside,
      glyphs: [
        (155.61887, 38.366932, -153.56158), (145.43007, 34.149414, -161.4655),
        (135.75557, 31.566833, -168.64166), (124.833275, 30.14614, -176.5363),
        (113.308815, 30.280313, 175.2022),
      ]),
    KotlinCase(
      alignment: Alignment.center, placement: Placement.inside,
      glyphs: [
        (176.97939, 53.845314, -134.58234), (168.71613, 46.54341, -142.48625),
        (160.4075, 40.95485, -149.6624), (150.54102, 36.059177, -157.55707),
        (139.59943, 32.438015, -165.81857),
      ]),
    KotlinCase(
      alignment: Alignment.end, placement: Placement.inside,
      glyphs: [
        (192.14471, 75.429214, -115.60311), (186.70544, 65.836845, -123.50703),
        (180.66603, 57.849926, -130.6832), (172.92813, 50.011566, -138.57787),
        (163.75906, 43.028778, -146.83937),
      ]),
  ]

  @Test(arguments: kotlinCases)
  func glyphPlacementsMatchTheKotlinPlayer(reference: KotlinCase) throws {
    let circle = try #require(
      circle(alignment: reference.alignment, placement: reference.placement))
    let glyphs = circle.glyphs(advances: Self.advances)
    #expect(glyphs.count == reference.glyphs.count)
    for (glyph, expected) in zip(glyphs, reference.glyphs) {
      let turn = (glyph.rotationRadians * Self.degreesPerRadian - expected.degrees)
        .truncatingRemainder(dividingBy: 360)
      #expect(abs(glyph.x - expected.x) < 0.15, "\(glyph) vs \(expected)")
      #expect(abs(glyph.y - expected.y) < 0.15, "\(glyph) vs \(expected)")
      #expect(min(abs(turn), 360 - abs(turn)) < 0.1, "\(glyph) vs \(expected)")
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

  /// An alignment or placement outside the wire's values — another byte, or a value that is not a
  /// whole number at all — falls back as the Kotlin player's does: alignment to START, placement to
  /// OUTSIDE.
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
    let source = try String(contentsOf: model, encoding: .utf8)
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
