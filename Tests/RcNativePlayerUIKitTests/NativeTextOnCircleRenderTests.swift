import CoreGraphics
import Foundation
import ImageIO
import RcNativePlayerTestDocuments
import Testing

@testable import RcNativePlayerCore

#if canImport(UIKit)
  import UIKit

  @testable import RcNativePlayerUIKit
#elseif canImport(AppKit)
  import AppKit
  import RcNativePlayerUIKit
#endif

/// `DrawTextOnCircle` (op 57) end to end on the native hosts (AppKit under `swift test`, UIKit on
/// the iOS simulator): one test for each case of the Kotlin player's `RcTextOnCircleRenderTest`,
/// on the same documents, byte for byte.
///
/// As there, the assertions are geometric rather than golden-image: a sweep from the wrong radius,
/// an alignment with the wrong sign or an arc built from the unwarped radius all still draw glyphs,
/// just in the wrong place, and a "did anything draw?" check would pass for every one of them.
@MainActor @Suite struct NativeTextOnCircleRenderTests {
  private typealias Documents = NativeTestDocuments
  private typealias Alignment = NativeSwiftTextOnCircleAlignment
  private typealias Placement = NativeSwiftTextOnCirclePlacement
  private nonisolated static let size = Documents.textOnCircleSize
  private nonisolated static let center = Documents.textOnCircleCenter
  private nonisolated static let radius = Documents.textOnCircleRadius
  /// Ink this far from the ring is nowhere near it: the string is 18 pt, so even a glyph's far edge
  /// sits well inside this band.
  private nonisolated static let farFromRing: Float = 24
  /// The band `Ink.onRing` counts in.
  private nonisolated static let nearRing: Float = 16
  /// `Ink.ringSignature`'s buckets around the ring, as the Kotlin test's.
  private nonisolated static let ringBuckets = 36
  private nonisolated static let degreesPerRadian = 180 / Double.pi
  /// The float ids the variable-geometry documents define.
  private static let centerID = 50
  private static let radiusID = 51
  private static let angleID = 52
  private static let warpID = 53

  @Test func glyphsLandOnTheNamedRingAndNowhereElse() throws {
    let ink = try render(Documents.textOnCircle(alignment: Alignment.center))

    #expect(ink.onRing > 0, "nothing drew on the ring the operation names")
    #expect(
      ink.count { $0 < Self.radius - Self.farFromRing } == 0, "ink landed well inside the ring")
    #expect(
      ink.count { $0 > Self.radius + Self.farFromRing } == 0, "ink landed well outside the ring")
  }

  /// START pins the string's leading edge at the start angle and END its trailing edge, so the
  /// two cannot put ink in the same places: that difference is the whole alignment arithmetic.
  @Test func alignmentMovesTheStringAroundTheRingWithoutLeavingIt() throws {
    let start = try render(Documents.textOnCircle(alignment: Alignment.start))
    let end = try render(Documents.textOnCircle(alignment: Alignment.end))

    #expect(start.onRing > 0 && end.onRing > 0)
    #expect(
      start.ringSignature != end.ringSignature,
      "START and END put the string in the same place; the alignment offset is not applied")
    #expect(start.count { $0 < Self.radius - Self.farFromRing } == 0)
    #expect(end.count { $0 < Self.radius - Self.farFromRing } == 0)
  }

  /// Deliberately not CENTER: a centred string straddles the start angle whichever way it travels,
  /// so this would pass on a renderer that ignored placement. Pinned at its start, the two run
  /// opposite ways.
  @Test func insidePlacementRunsTheOtherWayRoundTheRing() throws {
    let outside = try render(
      Documents.textOnCircle(alignment: Alignment.start, placement: Placement.outside))
    let inside = try render(
      Documents.textOnCircle(alignment: Alignment.start, placement: Placement.inside))

    #expect(outside.onRing > 0 && inside.onRing > 0)
    #expect(
      outside.ringSignature != inside.ringSignature,
      "OUTSIDE and INSIDE drew identically; the sweep is not being negated")
  }

  /// The radius can be a variable a live document animates through zero; dividing the text width by
  /// it would be an infinite sweep, so the renderer declines instead.
  @Test func aNonPositiveRadiusDrawsNothingRatherThanThrowing() throws {
    let ink = try render(Documents.textOnCircle(radius: .literal(0), warp: .literal(0)))

    #expect(ink.pixels.isEmpty)
  }

  /// Every geometry field may be a float variable (`width / 2` in `RemoteTimeText`), not only a
  /// literal; each resolves through the document's floats.
  @Test func variableGeometryDrawsWhatTheSameLiteralsDraw() throws {
    let literal = try render(Documents.textOnCircle())
    let variable = try render(
      Documents.textOnCircle(
        radius: .variable(Self.radiusID), warp: .variable(Self.warpID),
        center: .variable(Self.centerID), startAngle: .variable(Self.angleID),
        definitions: [
          (Self.centerID, Self.center), (Self.radiusID, Self.radius - Documents.textOnCircleWarp),
          (Self.angleID, Documents.textOnCircleStartAngle),
          (Self.warpID, Documents.textOnCircleWarp),
        ]))

    #expect(literal.onRing > 0)
    #expect(literal.ringSignature == variable.ringSignature)
    #expect(literal.pixels.count == variable.pixels.count)
  }

  /// A variable nothing has written yet is not a number, as in the Kotlin player (`resolve` falls
  /// back to the word itself): the draw is skipped rather than made at the origin.
  @Test func anUnresolvedCentreDrawsNothingRatherThanThrowing() throws {
    #expect(try render(Documents.textOnCircle(center: .variable(Self.centerID))).pixels.isEmpty)
  }

  /// An unusable circle keeps its command, so the canvas keeps its view, but with finite values
  /// that describe no circle: neither the hosts' finite-geometry budget nor their draw sees a NaN.
  @Test func anUnusableCircleKeepsItsCommandAndDrawsNothing() throws {
    func commands(_ data: Data) throws -> [NativeSwiftDrawCommandSnapshot] {
      Self.drawCommands(in: try NativeSwiftDocumentSession.open(data: data).snapshot().root)
        .filter { $0.kind == NativeSwiftDrawKind.textOnCircle }
    }
    for unusable in [
      Documents.textOnCircle(center: .variable(Self.centerID)),
      Documents.textOnCircle(radius: .literal(0), warp: .literal(0)),
      // An operator word where a number belongs reads no written value, as in Kotlin. The radius
      // is a variable so the command resolves per frame rather than as literals.
      Documents.textOnCircle(
        radius: .variable(Self.radiusID),
        center: .raw(NativeSwiftFloatExpression.operatorWord(NativeSwiftFloatOperator.add)),
        definitions: [(Self.radiusID, Self.radius - Documents.textOnCircleWarp)]),
    ] {
      let kept = try commands(unusable)
      #expect(kept.count == 1)
      #expect(kept.allSatisfy { NativeSwiftTextOnCircle(drawing: $0) == nil })
      #expect(kept.allSatisfy { $0.values.allSatisfy(\.isFinite) })
    }
    let drawn = try #require(try commands(Documents.textOnCircle(alignment: Alignment.end)).first)
    let circle = try #require(NativeSwiftTextOnCircle(drawing: drawn))
    #expect(circle.radius == Self.radius && circle.alignment == Alignment.end)
    #expect(drawn.text == Documents.textOnCircleText)
    #expect(drawn.textSize == Documents.textOnCircleTextSize)
  }

  /// A live document can move the radius through zero and back: the command stays in the frame
  /// and draws nothing while the circle is empty, then draws at the new radius; nothing about the
  /// empty frame sticks.
  @Test func aRadiusThatPassesThroughZeroStopsTheDrawAndBringsItBack() throws {
    let radiusName = "radius"
    let session = try NativeSwiftDocumentSession.open(
      data: Documents.textOnCircle(
        radius: .variable(Self.radiusID),
        definitions: [(Self.radiusID, Self.radius - Documents.textOnCircleWarp)],
        names: [(Self.radiusID, radiusName)]))
    func commands() throws -> [NativeSwiftDrawCommandSnapshot] {
      try Self.drawCommands(in: session.snapshot().root)
        .filter { $0.kind == NativeSwiftDrawKind.textOnCircle }
    }
    func circles() throws -> [NativeSwiftTextOnCircle] {
      try commands().compactMap(NativeSwiftTextOnCircle.init(drawing:))
    }
    #expect(try circles().map(\.radius) == [Self.radius])
    #expect(session.setFloat(-Documents.textOnCircleWarp, for: radiusName))
    #expect(try circles().isEmpty, "an empty circle still drew")
    #expect(try commands().count == 1, "the canvas lost its command, so its view is rebuilt")
    let newRadius: Float = 50
    #expect(session.setFloat(newRadius, for: radiusName))
    #expect(try circles().map(\.radius) == [newRadius + Documents.textOnCircleWarp])
  }

  /// The player's own ids are not document variables: a circle pinned to the clock still draws
  /// when the host supplies no wall clock, at the 0 the core reads an unloaded clock as, where
  /// the Kotlin player (which always loads its clock) draws it at the time.
  @Test func aCirclePinnedToAnUnloadedClockStillDraws() throws {
    let session = try NativeSwiftDocumentSession.open(
      data: Documents.textOnCircle(
        startAngle: .variable(NativeSwiftSystemVariables.timeInSeconds)))
    let circles = Self.drawCommands(in: try session.snapshot(wallClock: nil).root)
      .compactMap(NativeSwiftTextOnCircle.init(drawing:))
    #expect(circles.map(\.startAngle) == [0])
  }

  #if canImport(UIKit)
    /// A stroked circle string keeps its colour's own alpha (0x80) in the outline as in the fill:
    /// the canvas has already put the paint alpha (0.25) on the context.
    @Test func aStrokedCircleStringAppliesThePaintAlphaOnce() throws {
      let colorAlpha: CGFloat = 0x80 / 255
      let snapshot = NativeSwiftDrawCommandSnapshot(
        kind: NativeSwiftDrawKind.textOnCircle,
        values: [Self.center, Self.center, Self.radius, Documents.textOnCircleStartAngle, 0, 0, 0],
        colorARGB: 0x80ff_0000, alpha: 0.25, strokeWidth: 2, isStroke: true, strokeCap: .butt,
        strokeJoin: .miter, blendMode: .sourceOver, path: [], pathWinding: .nonZero, image: nil,
        textureImageID: nil, textureTileModeX: 0, textureTileModeY: 0, shaderMatrix: nil,
        filterQuality: nil, usesComponentGeometry: false, gradient: nil,
        text: Documents.textOnCircleText, textSize: Documents.textOnCircleTextSize, textFlags: 0,
        unsetValueIndices: [], offscreenTarget: nil)
      let command = NativeDrawCommand(snapshot)
      let attributes = NativeTextAttributes.string(
        for: command, font: .systemFont(ofSize: 18), scale: 1, layoutDirection: .leftToRight,
        keepingColorAlpha: true
      ).attributes(at: 0, effectiveRange: nil)
      let fill = try #require(attributes[.foregroundColor] as? UIColor)
      let stroke = try #require(attributes[.strokeColor] as? UIColor)
      #expect(abs(fill.cgColor.alpha - colorAlpha) < 1e-3)
      #expect(abs(stroke.cgColor.alpha - colorAlpha) < 1e-3)
    }
  #endif

  /// The circle's text size must be finite, as a text component's is: an infinite one refuses
  /// the frame rather than reaching the font.
  @Test func anInfiniteCircleTextSizeRefusesTheFrame() throws {
    let data = Documents.textOnCircle(textSize: .infinity)
    #if canImport(UIKit)
      let session = try NativeSwiftDocumentSession.open(data: data)
      #expect(throws: RemoteComposeNativeLimitError.self) {
        _ = try NativeDocument(
          frame: .init(session: session, snapshot: try session.snapshot(), wallClock: nil),
          timeSeconds: 0, limits: .default)
      }
    #elseif canImport(AppKit)
      #expect(throws: RemoteComposeNativeLimitError.self) { try png(data) }
    #endif
  }

  /// The circle's string is typeset every frame, so it spends the frame's text budget as a text
  /// component's string does; a string over the budget refuses the frame.
  @Test func theCircleStringSpendsTheFrameTextBudget() throws {
    #if canImport(UIKit)
      func frame(_ text: String, budget: Int) throws {
        let session = try NativeSwiftDocumentSession.open(
          data: Documents.textOnCircle(text: text))
        var limits = RemoteComposeNativeExecutionLimits.default
        limits.maximumTextBytes = budget
        _ = try NativeDocument(
          frame: .init(session: session, snapshot: try session.snapshot(), wallClock: nil),
          timeSeconds: 0, limits: limits)
      }
      let text = Documents.textOnCircleText
      try frame(text, budget: text.utf8.count)
      #expect(throws: RemoteComposeNativeLimitError.self) {
        try frame(text, budget: text.utf8.count - 1)
      }
    #elseif canImport(AppKit)
      // The AppKit policy has the default limits and the decoder caps one text below them, so
      // the longest string the decoder takes is drawn until the frame no longer fits.
      let text = String(repeating: "x", count: nativeSwiftMaximumStringBytes)
      let fits = RemoteComposeNativeExecutionLimits.default.maximumTextBytes / text.utf8.count
      _ = try png(Documents.textOnCircle(text: text, draws: fits))
      #expect(throws: RemoteComposeNativeLimitError.self) {
        try png(Documents.textOnCircle(text: text, draws: fits + 1))
      }
    #endif
  }

  /// Opt-in: writes the before/after evidence when `RC_TEXT_ON_CIRCLE_OUT` names a directory, and passes
  /// without writing otherwise — the Kotlin evidence strip's dial without and with its curved
  /// label, rendered by this host, and the labelled dial's document, for rendering on a base
  /// build.
  @Test func writesTheEvidencePair() throws {
    guard let out = ProcessInfo.processInfo.environment["RC_TEXT_ON_CIRCLE_OUT"] else { return }
    let directory = URL(fileURLWithPath: out, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let scenes: [(String, Documents.TextOnCircleScene)] = [
      ("dial", .dial), ("dial-text-on-circle", .labelledDial),
    ]
    for (name, scene) in scenes {
      let document = Documents.textOnCircle(scene)
      try document.write(to: directory.appendingPathComponent("\(name).rc"))
      try png(document)
        .write(to: directory.appendingPathComponent("\(Self.platform)-\(name).png"))
    }
  }

  // MARK: - Rendering and ink

  /// Every draw command of `node` and its descendants, depth first.
  private static func drawCommands(in node: NativeSwiftNodeSnapshot)
    -> [NativeSwiftDrawCommandSnapshot]
  {
    node.commands + node.children.flatMap(drawCommands)
  }

  /// Where the dark pixels of one frame are, relative to the circle's centre.
  struct Ink {
    /// The distance from the centre and the angle in degrees, 0..<360, of each dark pixel.
    let pixels: [(distance: Float, degrees: Double)]

    /// Dark pixels at a distance from the centre that `accept` takes.
    func count(where accept: (Float) -> Bool) -> Int { pixels.count { accept($0.distance) } }

    /// Dark pixels within a few points of the ring's own radius.
    var onRing: Int {
      typealias Tests = NativeTextOnCircleRenderTests
      return count { abs($0 - Tests.radius) <= Tests.nearRing }
    }

    /// Where the ink sits around the ring, as `ringBuckets` equal buckets.
    var ringSignature: [Bool] {
      let buckets = NativeTextOnCircleRenderTests.ringBuckets
      let bucketDegrees = 360 / Double(buckets)
      var signature = [Bool](repeating: false, count: buckets)
      for pixel in pixels {
        signature[min(max(Int(pixel.degrees / bucketDegrees), 0), buckets - 1)] = true
      }
      return signature
    }
  }

  private func render(_ data: Data) throws -> Ink {
    let image = try #require(try frame(data))
    let size = Self.size
    var bytes = [UInt8](repeating: 0, count: size * size * 4)
    // White first, so a transparent host frame and an opaque one read the same.
    try bytes.withUnsafeMutableBytes { buffer in
      let context = try #require(
        CGContext(
          data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8,
          bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: size, height: size))
      context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    }
    var pixels: [(Float, Double)] = []
    for y in 0..<size {
      for x in 0..<size {
        let offset = (y * size + x) * 4
        let luminance =
          Double(bytes[offset]) * 0.299 + Double(bytes[offset + 1]) * 0.587
          + Double(bytes[offset + 2]) * 0.114
        guard luminance < 128 else { continue }
        // The bitmap's rows run top down, as the frame's do.
        let dx = Float(x) - Self.center
        let dy = Float(y) - Self.center
        let degrees = (atan2(Double(dy), Double(dx)) * Self.degreesPerRadian + 360)
          .truncatingRemainder(dividingBy: 360)
        pixels.append(((dx * dx + dy * dy).squareRoot(), degrees))
      }
    }
    return Ink(pixels: pixels)
  }

  #if canImport(UIKit)
    private static let platform = "uikit"

    private func frame(_ data: Data) throws -> CGImage? {
      let snapshot = try NativeSwiftDocumentSession.open(data: data).snapshot()
      let view = NativeComponentView(
        node: NativeNode(swiftSnapshot: snapshot.root, densityBehavior: snapshot.densityBehavior),
        images: [:], fontNames: [:], offscreenTargets: NativeOffscreenTargets(),
        customComponents: RemoteComposeNativeCustomComponentRegistry(),
        onGesture: { _, _, _ in }, onCustomReturn: { _, _, _ in })
      view.frame = CGRect(x: 0, y: 0, width: Self.size, height: Self.size)
      view.layoutIfNeeded()
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      format.opaque = false
      format.preferredRange = .standard
      return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
        view.layer.render(in: context.cgContext)
      }.cgImage
    }

    private func png(_ data: Data) throws -> Data {
      let image = try #require(try frame(data))
      return try #require(UIImage(cgImage: image).pngData())
    }
  #elseif canImport(AppKit)
    private static let platform = "appkit"

    private func frame(_ data: Data) throws -> CGImage? {
      let png = try png(data)
      let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
      return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func png(_ data: Data) throws -> Data {
      try NativeAppKitWindowController.renderPNG(
        data: data, pixelWidth: Self.size, pixelHeight: Self.size, density: 1)
    }
  #endif
}
