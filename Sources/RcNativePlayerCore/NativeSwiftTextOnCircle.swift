import Foundation

/// `DrawTextOnCircle`'s `alignment` byte: which end of the string `startAngle` pins. Every value
/// of AndroidX `DrawTextOnCircle.Alignment`; any other byte aligns as START, as in the Kotlin
/// player.
public enum NativeSwiftTextOnCircleAlignment {
  public static let start = 0
  public static let center = 1
  public static let end = 2
}

/// `DrawTextOnCircle`'s `placement` byte. Every value of AndroidX `DrawTextOnCircle.Placement`;
/// any other byte is OUTSIDE, as in the Kotlin player.
public enum NativeSwiftTextOnCirclePlacement {
  /// Clockwise, glyphs upright for a reader at the top of the circle.
  public static let outside = 0
  /// Counter-clockwise (a negative sweep), glyphs upright for a reader at the bottom.
  public static let inside = 1
}

/// One glyph of a string laid on a circle: the centre of its advance on the circle, where its
/// baseline crosses the arc, and the angle its baseline is turned to — the direction of travel.
public struct NativeSwiftCircleGlyph: Sendable, Equatable {
  public let x: Float
  public let y: Float
  /// Clockwise from the x axis in y-down coordinates, in degrees.
  public let rotationDegrees: Float
}

/// The circle of one `DrawTextOnCircle`, resolved, and the arithmetic that lays a string on it.
///
/// This is the Kotlin player's `drawTextOnCircle` and `arcForCircleText` (`RcComposePlayer.kt`),
/// which mirror AndroidX `AndroidPaintContext.drawTextOnCircle`: the text's width becomes a sweep
/// at the effective radius, `alignment` moves the arc's start back along the direction of travel,
/// and INSIDE is a negative sweep. Glyph centres are then walked along that arc, each turned to
/// the arc's tangent, as `drawTextSegmentsOnPath` walks them. Hosts measure the glyphs and draw;
/// every angle is decided here.
public struct NativeSwiftTextOnCircle: Sendable, Equatable {
  public let centerX: Float
  public let centerY: Float
  /// The effective radius: the operation's radius plus its warp offset. Always positive.
  public let radius: Float
  /// Degrees, clockwise from the x axis in y-down coordinates.
  public let startAngle: Float
  public let alignment: Int
  public let placement: Int

  /// Where each field sits in the command's `values`: the wire's order, with the two bytes last.
  enum ValueIndex {
    static let centerX = 0
    static let centerY = 1
    static let radius = 2
    static let startAngle = 3
    static let warpRadiusOffset = 4
    static let alignment = 5
    static let placement = 6
    static let count = 7
  }

  /// The circle a `NativeSwiftDrawKind.textOnCircle` command's resolved `values` describe, or nil
  /// when they describe none: a non-finite centre or start angle (an unresolved variable), or a
  /// radius plus warp that is not positive. The operation then draws nothing, as the reference's
  /// does, rather than dividing the sweep by zero.
  public init?(values: [Float]) {
    guard values.count == ValueIndex.count else { return nil }
    let radius = values[ValueIndex.radius] + values[ValueIndex.warpRadiusOffset]
    let centerX = values[ValueIndex.centerX]
    let centerY = values[ValueIndex.centerY]
    let startAngle = values[ValueIndex.startAngle]
    guard centerX.isFinite, centerY.isFinite, startAngle.isFinite, radius.isFinite, radius > 0
    else { return nil }
    self.centerX = centerX
    self.centerY = centerY
    self.radius = radius
    self.startAngle = startAngle
    alignment = Int(values[ValueIndex.alignment])
    placement = Int(values[ValueIndex.placement])
  }

  /// The circle `command` draws on, when it is a `DrawTextOnCircle` that draws.
  public init?(_ command: NativeSwiftDrawCommandSnapshot) {
    guard command.kind == NativeSwiftDrawKind.textOnCircle else { return nil }
    self.init(values: command.values)
  }

  private var clockwise: Bool { placement != NativeSwiftTextOnCirclePlacement.inside }

  /// The arc a string `textWidth` wide is laid along: `arcForCircleText`. The sweep is the width
  /// over the radius, negative for INSIDE; the start is `startAngle` less the alignment's share of
  /// the sweep, measured along the direction of travel.
  public func arc(textWidth: Float) -> (startDegrees: Float, sweepDegrees: Float) {
    let magnitude = textWidth / radius * 180 / .pi
    let offset: Float =
      switch alignment {
      case NativeSwiftTextOnCircleAlignment.center: magnitude / 2
      case NativeSwiftTextOnCircleAlignment.end: magnitude
      default: 0
      }
    return clockwise
      ? (startAngle - offset, magnitude) : (startAngle + offset, -magnitude)
  }

  /// Each glyph's centre and turn for a string whose glyph advances, in drawing order, are
  /// `advances`. The arc is cut from their sum, so it is exactly as long as the walk; a glyph
  /// whose centre falls past the arc — past a full turn, for a string longer than the circle — is
  /// dropped with every glyph after it, as the path walker drops glyphs that run off its path.
  /// O(n) in the glyph count.
  public func glyphs(advances: [Float]) -> [NativeSwiftCircleGlyph] {
    let textWidth = advances.reduce(0, +)
    guard textWidth > 0, textWidth.isFinite else { return [] }
    let arc = arc(textWidth: textWidth)
    // A sweep of a full turn or more is the whole circle, as `Path.addArc` draws it.
    let length = min(abs(arc.sweepDegrees), 360) * .pi / 180 * radius
    let direction: Float = clockwise ? 1 : -1
    var placed: [NativeSwiftCircleGlyph] = []
    placed.reserveCapacity(advances.count)
    var distance: Float = 0
    for advance in advances {
      let middle = distance + advance / 2
      guard middle <= length else { break }
      let angle = arc.startDegrees * .pi / 180 + direction * middle / radius
      placed.append(
        NativeSwiftCircleGlyph(
          x: centerX + radius * cos(angle), y: centerY + radius * sin(angle),
          // The tangent along the direction of travel: a quarter turn on from the radius.
          rotationDegrees: angle * 180 / .pi + direction * 90))
      distance += advance
    }
    return placed
  }
}
