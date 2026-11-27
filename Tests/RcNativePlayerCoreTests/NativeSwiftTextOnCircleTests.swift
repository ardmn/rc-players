import Foundation
import Testing

@testable import RcNativePlayerCore

/// `DrawTextOnCircle`'s geometry, against the Kotlin player's `arcForCircleText` and its glyph
/// walker (`RcComposePlayer.kt`), which mirror AndroidX `AndroidPaintContext.drawTextOnCircle`.
@Suite struct NativeSwiftTextOnCircleTests {
  private typealias Alignment = NativeSwiftTextOnCircleAlignment
  private typealias Placement = NativeSwiftTextOnCirclePlacement

  /// Five glyph advances, 53 in all, laid on a circle of effective radius 80 round (120, 110),
  /// pinned at -60°.
  private static let advances: [Float] = [10, 12, 8, 14, 9]

  private func circle(
    alignment: Int, placement: Int, radius: Float = 70, warp: Float = 10
  ) -> NativeSwiftTextOnCircle? {
    NativeSwiftTextOnCircle(
      values: [120, 110, radius, -60, warp, Float(alignment), Float(placement)])
  }

  /// Glyph centres and rotations the Kotlin player computes for the same circle and advances:
  /// `arcForCircleText` measured by `RcPathMeasure`, read at each glyph's centre as
  /// `drawTextSegmentsOnPath` reads it (a temporary jvmTest printed them). Compose builds the arc
  /// from cubics, which `RcPathMeasure` finds 0.1% short of the true arc (52.94 for 53 here), so
  /// its later glyphs run up to 0.08 pt and 0.06° ahead of the true circle the Swift player walks;
  /// 0.15 pt and 0.1° is that approximation, not slack in the arithmetic.
  private static let kotlinGlyphs: [(alignment: Int, placement: Int, glyphs: [[Float]])] = [
    (
      Alignment.start, Placement.outside,
      [
        [164.22662, 43.336617, 33.561558], [172.97351, 50.051617, 41.46548],
        [180.04732, 57.13868, 48.64165], [186.73883, 65.88732, 56.53631],
        [192.38486, 75.93489, 64.79781],
      ]
    ),
    (
      Alignment.center, Placement.outside,
      [
        [140.1417, 32.577053, 14.582335], [150.59695, 36.08229, 22.48625],
        [159.5911, 40.483494, 29.662413], [168.76413, 46.580284, 37.557087],
        [177.37094, 54.245396, 45.818584],
      ]
    ),
    (
      Alignment.end, Placement.outside,
      [
        [113.86682, 30.235445, -4.3968964], [124.89369, 30.149813, 3.5070307],
        [134.83028, 31.386618, 10.683196], [145.48743, 34.168667, 18.577862],
        [156.11923, 38.61793, 26.839375],
      ]
    ),
    (
      Alignment.start, Placement.inside,
      [
        [155.61887, 38.366932, -153.56158], [145.43007, 34.149414, -161.4655],
        [135.75557, 31.566833, -168.64166], [124.833275, 30.14614, -176.5363],
        [113.308815, 30.280313, 175.2022],
      ]
    ),
    (
      Alignment.center, Placement.inside,
      [
        [176.97939, 53.845314, -134.58234], [168.71613, 46.54341, -142.48625],
        [160.4075, 40.95485, -149.6624], [150.54102, 36.059177, -157.55707],
        [139.59943, 32.438015, -165.81857],
      ]
    ),
    (
      Alignment.end, Placement.inside,
      [
        [192.14471, 75.429214, -115.60311], [186.70544, 65.836845, -123.50703],
        [180.66603, 57.849926, -130.6832], [172.92813, 50.011566, -138.57787],
        [163.75906, 43.028778, -146.83937],
      ]
    ),
  ]

  @Test(arguments: 0..<6)
  func glyphPlacementsMatchTheKotlinPlayer(index: Int) throws {
    let reference = Self.kotlinGlyphs[index]
    let circle = try #require(
      circle(alignment: reference.alignment, placement: reference.placement))
    let glyphs = circle.glyphs(advances: Self.advances)
    #expect(glyphs.count == reference.glyphs.count)
    for (glyph, expected) in zip(glyphs, reference.glyphs) {
      let turn = (glyph.rotationDegrees - expected[2]).truncatingRemainder(dividingBy: 360)
      #expect(abs(glyph.x - expected[0]) < 0.15, "\(glyph) vs \(expected)")
      #expect(abs(glyph.y - expected[1]) < 0.15, "\(glyph) vs \(expected)")
      #expect(min(abs(turn), 360 - abs(turn)) < 0.1, "\(glyph) vs \(expected)")
    }
  }

  /// The sweep is the text width over the effective radius — the operation's radius plus its warp
  /// offset — in degrees, so the arc is exactly as long as the string.
  @Test func theArcIsAsLongAsTheTextAtTheWarpedRadius() throws {
    let circle = try #require(circle(alignment: Alignment.start, placement: Placement.outside))
    #expect(circle.radius == 80)
    let arc = circle.arc(textWidth: 53)
    #expect(abs(arc.sweepDegrees - 53 / 80 * 180 / .pi) < 1e-4)
    #expect(arc.startDegrees == -60)
  }

  /// `startAngle` pins the end of the string `alignment` names: CENTER and END walk the start of
  /// the arc back along the direction of travel by half and all of the sweep.
  @Test func alignmentPinsTheNamedEndAtTheStartAngle() throws {
    let sweep: Float = 53 / 80 * 180 / .pi
    let expected: [(Int, Float)] = [
      (Alignment.start, -60), (Alignment.center, -60 - sweep / 2), (Alignment.end, -60 - sweep),
    ]
    for (alignment, start) in expected {
      let circle = try #require(circle(alignment: alignment, placement: Placement.outside))
      #expect(abs(circle.arc(textWidth: 53).startDegrees - start) < 1e-4, "\(alignment)")
    }
  }

  /// INSIDE is a negative sweep, so the alignment offsets move the start the other way.
  @Test func insidePlacementSweepsBackwards() throws {
    let sweep: Float = 53 / 80 * 180 / .pi
    let expected: [(Int, Float)] = [
      (Alignment.start, -60), (Alignment.center, -60 + sweep / 2), (Alignment.end, -60 + sweep),
    ]
    for (alignment, start) in expected {
      let circle = try #require(circle(alignment: alignment, placement: Placement.inside))
      let arc = circle.arc(textWidth: 53)
      #expect(abs(arc.sweepDegrees + sweep) < 1e-4, "\(alignment)")
      #expect(abs(arc.startDegrees - start) < 1e-4, "\(alignment)")
    }
  }

  /// An alignment or placement outside the wire's values falls back as the Kotlin player's does:
  /// alignment to START, placement to OUTSIDE.
  @Test func unknownAlignmentAndPlacementFallBackAsKotlinDoes() throws {
    let known = try #require(circle(alignment: Alignment.start, placement: Placement.outside))
    let unknown = try #require(circle(alignment: 7, placement: 9))
    #expect(unknown.arc(textWidth: 53) == known.arc(textWidth: 53))
  }

  /// A circle with no area (radius plus warp at or below zero) or a non-finite centre or angle is
  /// not a circle: the operation draws nothing, as AndroidX's and the Kotlin player's do.
  @Test(
    arguments: [
      [120, 110, 0, -60, 0, 0, 0], [120, 110, 10, -60, -10, 0, 0], [120, 110, -5, -60, 0, 0, 0],
      [.nan, 110, 70, -60, 10, 0, 0], [120, .infinity, 70, -60, 10, 0, 0],
      [120, 110, 70, .nan, 10, 0, 0], [120, 110, .nan, -60, 10, 0, 0], [120, 110, 70, -60],
    ] as [[Float]])
  func anUnusableCircleIsNotOne(values: [Float]) {
    #expect(NativeSwiftTextOnCircle(values: values) == nil)
  }

  /// Glyphs whose centre falls past the end of a full turn are dropped, as the path walker drops
  /// glyphs that run off its path; an empty or zero-width string places nothing.
  @Test func glyphsPastAFullTurnAreDropped() throws {
    let circle = try #require(
      circle(alignment: Alignment.start, placement: Placement.outside, radius: 1, warp: 0))
    // Circumference 2π ≈ 6.28: centres at 1, 3, 5 fit; 7 and 9 do not.
    #expect(circle.glyphs(advances: [2, 2, 2, 2, 2]).count == 3)
    #expect(circle.glyphs(advances: []).isEmpty)
    #expect(circle.glyphs(advances: [0, 0]).isEmpty)
  }
}
