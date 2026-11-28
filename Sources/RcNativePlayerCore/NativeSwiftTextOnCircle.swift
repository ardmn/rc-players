import Foundation

/// Which point of the string `DrawTextOnCircle` pins at its `startAngle`.
///
/// The ordinals of AndroidX `DrawTextOnCircle.Alignment`
/// ([`DrawTextOnCircle.java`](https://github.com/androidx/androidx/blob/androidx-main/compose/remote/remote-core/src/main/java/androidx/compose/remote/core/operations/DrawTextOnCircle.java)). Any other byte aligns as ``start``, as `Alignment.fromInt`
/// maps it.
public enum NativeSwiftTextOnCircleAlignment {
  /// The string begins at `startAngle` and runs away from it.
  public static let start = 0
  /// The middle of the string sits at `startAngle`.
  public static let center = 1
  /// The string ends at `startAngle`.
  public static let end = 2
}

/// Which side of the circle `DrawTextOnCircle`'s string reads from.
///
/// The ordinals of AndroidX `DrawTextOnCircle.Placement`. Any other byte is ``outside``, as
/// `Placement.fromInt` maps it.
public enum NativeSwiftTextOnCirclePlacement {
  /// Clockwise, glyph tops pointing away from the centre: upright at the top of the circle.
  public static let outside = 0
  /// Counter-clockwise, glyph tops pointing at the centre: upright at the bottom of the circle.
  public static let inside = 1
}

/// One glyph placed on the circle.
public struct NativeSwiftCircleGlyph: Sendable, Equatable {
  /// The x of the glyph's centre, on the circle.
  public let x: Float
  /// The y of the glyph's centre, on the circle.
  public let y: Float
  /// The baseline's direction, the circle's tangent: radians clockwise from the x axis in y-down
  /// coordinates, as `CGContext.rotate(by:)` takes it.
  public let rotationRadians: Float
}

/// The resolved circle of one `DrawTextOnCircle`, and the layout of a string along it.
///
/// Mirrors the Kotlin player's `arcForCircleText` and glyph walk (`RcComposePlayer.kt`), which
/// follow AndroidX `AndroidPaintContext.drawTextOnCircle`. Hosts measure and draw the glyphs;
/// every angle is decided here.
public struct NativeSwiftTextOnCircle: Sendable, Equatable {
  /// The x of the circle's centre.
  public let centerX: Float
  /// The y of the circle's centre.
  public let centerY: Float
  /// The effective radius: the operation's radius plus its warp offset. Always positive.
  public let radius: Float
  /// Degrees, clockwise from the x axis in y-down coordinates.
  public let startAngle: Float
  /// A `NativeSwiftTextOnCircleAlignment` value, or any other byte the wire carried.
  public let alignment: Int
  /// A `NativeSwiftTextOnCirclePlacement` value, or any other byte the wire carried.
  public let placement: Int

  /// Positions in the command's `values`: the wire's geometry words, then its two bytes.
  enum ValueIndex {
    static let centerX = 0
    static let centerY = 1
    static let radius = 2
    static let startAngle = 3
    static let warpRadiusOffset = 4
    /// The geometry words on the wire.
    static let geometryCount = 5
    static let alignment = geometryCount
    static let placement = geometryCount + 1
    static let count = geometryCount + 2
  }

  private static let radiansPerDegree: Float = .pi / 180

  /// Creates the circle a `textOnCircle` command's resolved values describe.
  ///
  /// Fails for a non-finite centre or start angle (an unresolved variable) or a radius plus warp
  /// that is not positive: the operation then draws nothing, as in AndroidX. An alignment or
  /// placement that is not a whole number falls back to START or OUTSIDE.
  ///
  /// - Parameter values: The command's values, in ``ValueIndex`` order.
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
    alignment = Int(exactly: values[ValueIndex.alignment]) ?? NativeSwiftTextOnCircleAlignment.start
    placement =
      Int(exactly: values[ValueIndex.placement]) ?? NativeSwiftTextOnCirclePlacement.outside
  }

  /// Creates the circle `command` draws on; fails for any other kind of command.
  public init?(drawing command: NativeSwiftDrawCommandSnapshot) {
    guard command.kind == NativeSwiftDrawKind.textOnCircle else { return nil }
    self.init(values: command.values)
  }

  private var clockwise: Bool { placement != NativeSwiftTextOnCirclePlacement.inside }

  /// The arc a string is laid along: Kotlin `arcForCircleText`.
  ///
  /// The sweep is the width over the radius, negative for INSIDE. CENTER and END move the start
  /// back along the direction of travel by half and all of the sweep.
  ///
  /// - Parameter textWidth: The string's width, in points.
  /// - Returns: The arc's start and sweep in degrees, as `Path.addArc` takes them.
  public func arc(textWidth: Float) -> (startDegrees: Float, sweepDegrees: Float) {
    let magnitude = textWidth / radius / Self.radiansPerDegree
    let offset: Float =
      switch alignment {
      case NativeSwiftTextOnCircleAlignment.center: magnitude / 2
      case NativeSwiftTextOnCircleAlignment.end: magnitude
      default: 0
      }
    return clockwise
      ? (startAngle - offset, magnitude) : (startAngle + offset, -magnitude)
  }

  /// The position and rotation of each glyph laid along ``arc(textWidth:)``.
  ///
  /// The arc is cut from the advances' sum, so it is as long as the walk. A glyph whose centre
  /// falls past the arc, or past one full turn, is dropped with every glyph after it, as the
  /// path walker drops glyphs that run off its path. O(n) in the glyphs, once per draw.
  ///
  /// - Parameter advances: The glyph advances in drawing order, in points.
  /// - Returns: One placement per glyph that fits, in the same order.
  public func glyphs(advances: [Float]) -> [NativeSwiftCircleGlyph] {
    let textWidth = advances.reduce(0, +)
    guard textWidth > 0, textWidth.isFinite else { return [] }
    let textArc = arc(textWidth: textWidth)
    // A string longer than the circle covers it once and does not lap itself.
    let arcLength = min(abs(textArc.sweepDegrees), 360) * Self.radiansPerDegree * radius
    let startRadians = textArc.startDegrees * Self.radiansPerDegree
    let direction: Float = clockwise ? 1 : -1
    var placed: [NativeSwiftCircleGlyph] = []
    placed.reserveCapacity(advances.count)
    var walked: Float = 0
    for advance in advances {
      let glyphCentreDistance = walked + advance / 2
      guard glyphCentreDistance <= arcLength else { break }
      let angle = startRadians + direction * glyphCentreDistance / radius
      placed.append(
        NativeSwiftCircleGlyph(
          x: centerX + radius * cos(angle), y: centerY + radius * sin(angle),
          // The tangent: a quarter turn on from the radius, along the direction of travel.
          rotationRadians: angle + direction * .pi / 2))
      walked += advance
    }
    return placed
  }
}
