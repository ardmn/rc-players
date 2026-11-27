import CoreGraphics
#if canImport(RcNativePlayerCore)
  import RcNativePlayerCore
#endif

/// Float equality for deciding whether a canvas must redraw: `==`, except that NaN equals NaN.
///
/// A draw value can legitimately be NaN — `DrawTextAnchored`'s `panY` sentinel, see
/// `NativeSwiftDrawCommandSnapshot.unsetValueIndices` — and IEEE `==` never holds for NaN, so a
/// synthesised `==` would call an unchanged command different and redraw it every frame.
enum NativeRedrawEquality {
  static func same<T: FloatingPoint>(_ lhs: T, _ rhs: T) -> Bool {
    lhs == rhs || (lhs.isNaN && rhs.isNaN)
  }

  static func same<T: FloatingPoint>(_ lhs: [T], _ rhs: [T]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).allSatisfy { same($0, $1) }
  }

  static func same<T: FloatingPoint>(_ lhs: [T]?, _ rhs: [T]?) -> Bool {
    guard let lhs, let rhs else { return lhs == nil && rhs == nil }
    return same(lhs, rhs)
  }
}

/// `==` is written out only so `stops` and `values` compare NaN-stably (`NativeRedrawEquality`);
/// every other member uses its own `==`, `CGColor`'s being `CFEqual`.
struct NativeGradient: Equatable {
  let kind: Int
  let colors: [CGColor]
  let stops: [CGFloat]
  let values: [CGFloat]
  let tileMode: Int

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.kind == rhs.kind && lhs.colors == rhs.colors
      && NativeRedrawEquality.same(lhs.stops, rhs.stops)
      && NativeRedrawEquality.same(lhs.values, rhs.values) && lhs.tileMode == rhs.tileMode
  }
}

enum NativeGraphicsState {
  static func apply(
    to context: CGContext,
    strokeWidth: CGFloat,
    strokeCap: NativeSwiftStrokeCap,
    strokeJoin: NativeSwiftStrokeJoin,
    blendMode: NativeSwiftPaintBlendMode
  ) {
    context.setLineWidth(max(strokeWidth, 0.5))
    context.setLineCap(lineCap(strokeCap))
    context.setLineJoin(lineJoin(strokeJoin))
    context.setBlendMode(self.blendMode(blendMode))
  }

  static func lineCap(_ value: NativeSwiftStrokeCap) -> CGLineCap {
    switch value {
    case .butt: .butt
    case .round: .round
    case .square: .square
    }
  }

  static func lineJoin(_ value: NativeSwiftStrokeJoin) -> CGLineJoin {
    switch value {
    case .miter: .miter
    case .round: .round
    case .bevel: .bevel
    }
  }

  /// Narrows `context`'s clip by `path` under `CLIP_PATH`'s region operation, as the reference
  /// does: `difference` clips the path *out*, and every other value intersects with it.
  ///
  /// Core Graphics has no clip-out, so a difference clips to the current clip's bounds with the
  /// path cut from it by the even-odd rule. The path is first reduced to the area its own fill rule
  /// covers, without overlaps, so a non-zero path whose contours overlap or nest in the same
  /// direction is cut out whole rather than by parity. Before iOS 16 and macOS 13 there is no such
  /// reduction and the path is cut as written, which is the same for any path that does not
  /// overlap itself.
  static func clip(
    _ context: CGContext, to path: CGPath, winding: NativeSwiftPathWinding, regionOp: Int
  ) {
    guard regionOp == NativeSwiftClipRegionOp.difference else {
      context.addPath(path)
      context.clip(using: fillRule(winding))
      return
    }
    var covered = path
    if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
      covered = path.normalized(using: fillRule(winding))
    }
    let outside = CGMutablePath()
    outside.addRect(context.boundingBoxOfClipPath.insetBy(dx: -1, dy: -1))
    outside.addPath(covered)
    context.addPath(outside)
    context.clip(using: .evenOdd)
  }

  /// The Core Graphics fill rule a path's winding fills with.
  static func fillRule(_ winding: NativeSwiftPathWinding) -> CGPathFillRule {
    switch winding {
    case .nonZero: .winding
    case .evenOdd: .evenOdd
    }
  }

  static func blendMode(_ value: NativeSwiftPaintBlendMode) -> CGBlendMode {
    switch value {
    case .clear: .clear
    case .source: .copy
    case .destination: .normal
    case .sourceOver: .normal
    case .destinationOver: .destinationOver
    case .sourceIn: .sourceIn
    case .destinationIn: .destinationIn
    case .sourceOut: .sourceOut
    case .destinationOut: .destinationOut
    case .sourceAtop: .sourceAtop
    case .destinationAtop: .destinationAtop
    case .xor: .xor
    case .plus: .plusLighter
    case .modulate, .multiply: .multiply
    case .screen: .screen
    case .overlay: .overlay
    case .darken: .darken
    case .lighten: .lighten
    case .colorDodge: .colorDodge
    case .colorBurn: .colorBurn
    case .hardLight: .hardLight
    case .softLight: .softLight
    case .difference: .difference
    case .exclusion: .exclusion
    case .hue: .hue
    case .saturation: .saturation
    case .color: .color
    case .luminosity: .luminosity
    }
  }

  /// Corner radii Core Graphics accepts for `rect`. `CGPath(roundedRect:cornerWidth:cornerHeight:)`
  /// asserts unless each radius is non-negative and at most half the matching side, and document
  /// radii are unvalidated; a non-finite radius becomes 0.
  static func clampedCornerRadii(
    in rect: CGRect, cornerWidth: CGFloat, cornerHeight: CGFloat
  ) -> (width: CGFloat, height: CGFloat) {
    func clamp(_ radius: CGFloat, _ side: CGFloat) -> CGFloat {
      guard radius.isFinite, side.isFinite else { return 0 }
      return min(max(radius, 0), side / 2)
    }
    return (clamp(cornerWidth, rect.width), clamp(cornerHeight, rect.height))
  }

  /// A rounded-rectangle path whose radii are clamped with `clampedCornerRadii`.
  static func roundedRectPath(
    _ rect: CGRect, cornerWidth: CGFloat, cornerHeight: CGFloat
  ) -> CGPath {
    let radii = clampedCornerRadii(in: rect, cornerWidth: cornerWidth, cornerHeight: cornerHeight)
    return CGPath(
      roundedRect: rect, cornerWidth: radii.width, cornerHeight: radii.height, transform: nil)
  }
}

enum NativeGradientRenderer {
  static func draw(_ value: NativeGradient, in context: CGContext) {
    let normalizedColors = value.colors.count == 1 ? [value.colors[0], value.colors[0]] : value.colors
    guard normalizedColors.count >= 2 else { return }
    let normalizedStops: [CGFloat]?
    if value.stops.count == normalizedColors.count {
      normalizedStops = value.stops
    } else {
      normalizedStops = (0..<normalizedColors.count).map {
        CGFloat($0) / CGFloat(normalizedColors.count - 1)
      }
    }
    // Converted into the gradient's own space first. CGGradient returns nil when a colour is not
    // already in the space it is handed, and `UIColor.cgColor` is sRGB rather than device RGB — so
    // building against CGColorSpaceCreateDeviceRGB() failed for every real colour and painted
    // nothing at all. sRGB is also what the reference players interpolate in.
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let spaceColors = normalizedColors.map {
      $0.converted(to: space, intent: .defaultIntent, options: nil) ?? $0
    }
    guard
      let gradient = CGGradient(
        colorsSpace: space,
        colors: spaceColors as CFArray,
        locations: normalizedStops)
    else { return }

    // Clamp extends the end colours; decal stops at them. Repeat and mirror draw the gradient once
    // per period the clip reaches, each in its own band.
    let extend: CGGradientDrawingOptions =
      value.tileMode == NativeGradientTiling.decal
      ? [] : [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    let tiles =
      value.tileMode == NativeGradientTiling.repeated
      || value.tileMode == NativeGradientTiling.mirror
    switch value.kind {
    case 0:
      let start = CGPoint(x: value.values[0], y: value.values[1])
      let end = CGPoint(x: value.values[2], y: value.values[3])
      if tiles,
        drawTiledLinear(
          gradient, start: start, end: end,
          mirror: value.tileMode == NativeGradientTiling.mirror,
          average: averageColor(spaceColors, stops: normalizedStops ?? []), in: context)
      {
        return
      }
      context.drawLinearGradient(gradient, start: start, end: end, options: extend)
    case 1:
      let center = CGPoint(x: value.values[0], y: value.values[1])
      let radius = value.values[2]
      if tiles,
        drawTiledRadial(
          gradient, center: center, radius: radius,
          mirror: value.tileMode == NativeGradientTiling.mirror,
          average: averageColor(spaceColors, stops: normalizedStops ?? []), in: context)
      {
        return
      }
      context.drawRadialGradient(
        gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
        options: extend)
    case 2:
      drawSweep(
        colors: normalizedColors,
        stops: normalizedStops ?? [],
        center: CGPoint(x: value.values[0], y: value.values[1]),
        in: context)
    default: break
    }
  }

  /// Draws a repeated or mirrored linear gradient: the one-period gradient once per period the
  /// clip reaches, each clipped to the strip between its two ends, reversed in a mirror's odd
  /// periods. False leaves the draw to the clamped path.
  ///
  /// A period under a device pixel cannot show its pattern, so the clip is filled with the
  /// gradient's average colour instead; otherwise the band count is bounded by the canvas. Bands
  /// are clipped aliased, so neighbours share their edge pixels rather than both half-covering them.
  private static func drawTiledLinear(
    _ gradient: CGGradient, start: CGPoint, end: CGPoint, mirror: Bool, average: CGColor,
    in context: CGContext
  ) -> Bool {
    let axis = CGPoint(x: end.x - start.x, y: end.y - start.y)
    let length = hypot(axis.x, axis.y)
    let clip = context.boundingBoxOfClipPath
    guard length > 0, !clip.isNull, !clip.isInfinite else { return false }
    // The gradient parameter at each corner of the clip: its projection onto the axis.
    let parameters = corners(of: clip).map {
      Double((($0.x - start.x) * axis.x + ($0.y - start.y) * axis.y) / (length * length))
    }
    guard let lower = parameters.min(), let upper = parameters.max(),
      let span = NativeGradientTiling.periods(lower: lower, upper: upper)
    else { return false }
    let devicePeriod = context.convertToDeviceSpace(CGSize(width: axis.x, height: axis.y))
    guard hypot(devicePeriod.width, devicePeriod.height) >= 1 else {
      context.setFillColor(average)
      context.fill(clip)
      return true
    }
    // Half-width of each band across the axis: enough to cover the clip from any point on it.
    let reach = hypot(clip.width, clip.height) + length
    let across = CGPoint(x: -axis.y / length * reach, y: axis.x / length * reach)
    context.saveGState()
    defer { context.restoreGState() }
    context.setShouldAntialias(false)
    for period in span.first..<span.last {
      let from = CGPoint(
        x: start.x + axis.x * CGFloat(period), y: start.y + axis.y * CGFloat(period))
      let to = CGPoint(x: from.x + axis.x, y: from.y + axis.y)
      let band = CGMutablePath()
      band.addLines(between: [
        CGPoint(x: from.x + across.x, y: from.y + across.y),
        CGPoint(x: to.x + across.x, y: to.y + across.y),
        CGPoint(x: to.x - across.x, y: to.y - across.y),
        CGPoint(x: from.x - across.x, y: from.y - across.y),
      ])
      band.closeSubpath()
      let flipped = mirror && period % 2 != 0
      context.saveGState()
      context.addPath(band)
      context.clip()
      context.drawLinearGradient(
        gradient, start: flipped ? to : from, end: flipped ? from : to,
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
      context.restoreGState()
    }
    return true
  }

  /// Draws a repeated or mirrored radial gradient: the one-period gradient once per ring the clip
  /// reaches, each clipped to its ring, running outward-in in a mirror's odd periods. The same
  /// sub-pixel and aliasing rules as `drawTiledLinear` apply.
  private static func drawTiledRadial(
    _ gradient: CGGradient, center: CGPoint, radius: CGFloat, mirror: Bool, average: CGColor,
    in context: CGContext
  ) -> Bool {
    let clip = context.boundingBoxOfClipPath
    guard radius > 0, !clip.isNull, !clip.isInfinite else { return false }
    let farthest = corners(of: clip).map { hypot($0.x - center.x, $0.y - center.y) }.max() ?? 0
    let nearest = hypot(
      max(clip.minX - center.x, 0, center.x - clip.maxX),
      max(clip.minY - center.y, 0, center.y - clip.maxY))
    guard
      let span = NativeGradientTiling.periods(
        lower: Double(nearest / radius), upper: Double(farthest / radius))
    else { return false }
    // The radius's device length in the direction the transform stretches most — its largest
    // singular value, which a rotation keeps and a shear can raise above either column. The rings
    // stay visible while any direction spans a pixel, so only a period sub-pixel every way falls
    // back. So does a ring count the device cannot resolve (`ringBudget`), which only a strongly
    // anisotropic or sheared transform reaches.
    let device = context.userSpaceToDeviceSpaceTransform
    let deviceRadius =
      radius
      * CGFloat(
        NativeGradientTiling.largestStretch(
          a: Double(device.a), b: Double(device.b), c: Double(device.c), d: Double(device.d)))
    let deviceClip = clip.applying(device)
    let budget = NativeGradientTiling.ringBudget(
      deviceWidth: Double(deviceClip.width), deviceHeight: Double(deviceClip.height))
    guard deviceRadius >= 1, span.last - max(span.first, 0) <= budget else {
      context.setFillColor(average)
      context.fill(clip)
      return true
    }
    context.saveGState()
    defer { context.restoreGState() }
    context.setShouldAntialias(false)
    for period in max(span.first, 0)..<span.last {
      let inner = radius * CGFloat(period)
      let outer = inner + radius
      let ring = CGMutablePath()
      ring.addEllipse(
        in: CGRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2))
      if inner > 0 {
        ring.addEllipse(
          in: CGRect(
            x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))
      }
      let flipped = mirror && period % 2 != 0
      context.saveGState()
      context.addPath(ring)
      context.clip(using: .evenOdd)
      context.drawRadialGradient(
        gradient, startCenter: center, startRadius: flipped ? outer : inner, endCenter: center,
        endRadius: flipped ? inner : outer,
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
      context.restoreGState()
    }
    return true
  }

  /// The colour a period too small to see averages to, in sRGB.
  private static func averageColor(_ colors: [CGColor], stops: [CGFloat]) -> CGColor {
    let components = NativeGradientTiling.averageColor(
      colors: colors.map { rgbaComponents($0).map(Double.init) }, stops: stops.map(Double.init))
    return CGColor(colorSpace: rgbColorSpace, components: components.map { CGFloat($0) })
      ?? colors[0]
  }

  private static func corners(of rect: CGRect) -> [CGPoint] {
    [
      CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
      CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
    ]
  }

  private static func drawSweep(
    colors: [CGColor], stops: [CGFloat], center: CGPoint, in context: CGContext
  ) {
    let clip = context.boundingBoxOfClipPath
    let radius = [
      CGPoint(x: clip.minX, y: clip.minY), CGPoint(x: clip.maxX, y: clip.minY),
      CGPoint(x: clip.maxX, y: clip.maxY), CGPoint(x: clip.minX, y: clip.maxY),
    ].map { hypot($0.x - center.x, $0.y - center.y) }.max() ?? 0
    guard radius > 0 else { return }
    // The wedges are drawn aliased. Each is about a pixel wide at the rim, and two antialiased
    // neighbours only cover a shared edge pixel a·(1−a) of the way between them, so the backdrop
    // showed through almost every seam. The clip set before this call keeps the shape's own edge
    // antialiased.
    context.saveGState()
    defer { context.restoreGState() }
    context.setShouldAntialias(false)
    let rgbaStops = colors.map { rgbaComponents($0) }
    let steps = 360
    for index in 0..<steps {
      let start = CGFloat(index) / CGFloat(steps)
      let end = CGFloat(index + 1) / CGFloat(steps)
      let rgba = interpolatedRGBA(at: (start + end) / 2, colors: rgbaStops, stops: stops)
      context.setFillColor(red: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
      context.move(to: center)
      context.addArc(
        center: center,
        radius: radius,
        startAngle: start * 2 * .pi,
        endAngle: end * 2 * .pi,
        clockwise: false)
      context.closePath()
      context.fillPath()
    }
  }

  private static func interpolatedRGBA(
    at location: CGFloat, colors: [[CGFloat]], stops: [CGFloat]
  ) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
    let upper = stops.firstIndex(where: { $0 >= location }) ?? stops.index(before: stops.endIndex)
    guard upper > stops.startIndex else {
      let first = colors[0]
      return (first[0], first[1], first[2], first[3])
    }
    let lower = stops.index(before: upper)
    let distance = stops[upper] - stops[lower]
    let fraction = distance > 0 ? (location - stops[lower]) / distance : 0
    let left = colors[lower]
    let right = colors[upper]
    return (
      r: left[0] + (right[0] - left[0]) * fraction,
      g: left[1] + (right[1] - left[1]) * fraction,
      b: left[2] + (right[2] - left[2]) * fraction,
      a: left[3] + (right[3] - left[3]) * fraction
    )
  }

  private static let rgbColorSpace =
    CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

  /// Exactly four sRGB components (red, green, blue, alpha) for any colour. `CGColor.components`
  /// has as many entries as the colour's space has channels plus alpha, so a grayscale colour has
  /// two and indexing it as RGBA read out of bounds.
  static func rgbaComponents(_ color: CGColor) -> [CGFloat] {
    let converted = color.converted(to: rgbColorSpace, intent: .defaultIntent, options: nil)
    let components = (converted ?? color).components ?? []
    switch components.count {
    case 4...: return Array(components[0..<4])
    case 3: return [components[0], components[1], components[2], 1]
    case 2: return [components[0], components[0], components[0], components[1]]
    case 1: return [components[0], components[0], components[0], 1]
    default: return [0, 0, 0, 1]
    }
  }
}

/// A node's draw commands as AndroidX's `Canvas` treats a non-finite value, so a host's NaN or
/// infinity changes only what Skia would change and never how saves and restores pair up. AndroidX
/// hands the floats to `Canvas` unchecked (`AndroidPaintContext.matrixTranslate`: `mCanvas.translate
/// (translateX, translateY)`; `clipRect`: `mCanvas.clipRect(left, top, right, bottom)`), and so
/// does hwui (`SkiaCanvas::translate`, `SkiaCanvas::clipRect`), so Skia decides:
///
/// - A matrix command with a non-finite operand makes the matrix non-finite (`SkCanvas::translate`,
///   `scale`, `rotate`, `skew` and `concat` do not check), and Skia then rejects every draw under it
///   (`SkCanvas::quickReject`: `!devRect.isFinite()`) until the restore that pops it. The command
///   and every draw up to that restore are left out. A NaN pivot is the reference's "no pivot"
///   (`AndroidPaintContext.matrixScale` and `matrixRotate`: `Float.isNaN(centerX)`), not an operand.
/// - A clip rectangle with a non-finite edge is ignored (`SkCanvas::clipRect`: `if
///   (!rect.isFinite()) return;`).
/// - An intersecting clip path with a non-finite point clips everything away until its restore
///   (`SkRegion::setPath` reads a non-finite path as empty); a difference clip of one is ignored.
/// - Any other command with non-finite geometry or paint draws nothing (`isDrawable`).
///
/// Saves and restores are always kept. A `DrawToBitmap` redirect draws into another canvas, whose
/// matrix the commands before it did not touch (`AndroidPaintContext.drawToBitmap` swaps
/// `mCanvas`), so it ends what they suppressed.
enum NativeCanvasCommands {
  static func drawable(
    _ commands: [NativeSwiftDrawCommandSnapshot],
    limits: RemoteComposeNativeExecutionLimits = .default
  ) -> [NativeSwiftDrawCommandSnapshot] {
    // Whether each open save scope draws nothing, its own node's scope at the bottom.
    var suppressed = [false]
    var kept: [NativeSwiftDrawCommandSnapshot] = []
    kept.reserveCapacity(commands.count)
    for command in commands {
      switch command.kind {
      case NativeSwiftDrawKind.matrixSave:
        suppressed.append(suppressed[suppressed.count - 1])
        kept.append(command)
      case NativeSwiftDrawKind.matrixRestore:
        if suppressed.count > 1 { suppressed.removeLast() }
        kept.append(command)
      case NativeSwiftDrawKind.drawToBitmap:
        suppressed = [false]
        kept.append(command)
      default:
        guard !suppressed[suppressed.count - 1] else { continue }
        switch effect(of: command, limits: limits) {
        case .draws: kept.append(command)
        case .ignored: break
        case .suppressesScope: suppressed[suppressed.count - 1] = true
        }
      }
    }
    return kept
  }

  private enum Effect {
    case draws
    case ignored
    case suppressesScope
  }

  private static func effect(
    of command: NativeSwiftDrawCommandSnapshot, limits: RemoteComposeNativeExecutionLimits
  ) -> Effect {
    let values = command.values
    switch command.kind {
    case NativeSwiftDrawKind.matrixTranslate, NativeSwiftDrawKind.matrixSkew,
      NativeSwiftDrawKind.matrixFromPath:
      return values.allSatisfy(\.isFinite) ? .draws : .suppressesScope
    case NativeSwiftDrawKind.matrixScale:
      return operands(values, pivotAt: scalePivotIndex).allSatisfy(\.isFinite)
        ? .draws : .suppressesScope
    case NativeSwiftDrawKind.matrixRotate:
      return operands(values, pivotAt: rotatePivotIndex).allSatisfy(\.isFinite)
        ? .draws : .suppressesScope
    case NativeSwiftDrawKind.clipRect:
      return values.allSatisfy(\.isFinite) ? .draws : .ignored
    case NativeSwiftDrawKind.clipPath:
      // The renderers read the region operation as an integer.
      guard let regionOp = values.first.flatMap({ Int(exactly: $0) }) else { return .ignored }
      guard command.path.allSatisfy({ $0.values.allSatisfy(\.isFinite) }) else {
        return regionOp == NativeSwiftClipRegionOp.difference ? .ignored : .suppressesScope
      }
      return .draws
    default:
      return limits.isDrawable(command) ? .draws : .ignored
    }
  }

  /// `MatrixScale`'s `[scaleX, scaleY, centerX, centerY]` and `MatrixRotate`'s
  /// `[angle, pivotX, pivotY]`: where the pivot starts.
  private static let scalePivotIndex = 2
  private static let rotatePivotIndex = 1

  /// The values the matrix depends on: all of them, or those before the pivot when its x is NaN,
  /// which AndroidX reads as no pivot and ignores the pivot's y with it.
  private static func operands(_ values: [Float], pivotAt index: Int) -> ArraySlice<Float> {
    index < values.count && values[index].isNaN ? values.prefix(index) : values[...]
  }
}
