import CoreGraphics
import Foundation
import ImageIO
import RcNativePlayerCore
import RcNativePlayerTestDocuments
import Testing

#if canImport(UIKit)
  import UIKit

  @testable import RcNativePlayerUIKit
#elseif canImport(AppKit)
  import AppKit
  import RcNativePlayerUIKit
#endif

/// `DrawTextOnCircle` (op 57) end to end on the native hosts — AppKit under `swift test`, UIKit on
/// the iOS simulator — one test for each case of the Kotlin player's `RcTextOnCircleRenderTest`,
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

  @Test func glyphsLandOnTheNamedRingAndNowhereElse() throws {
    let ink = try render(Documents.textOnCircle(alignment: Alignment.center))

    #expect(ink.onRing > 0, "nothing drew on the ring the operation names")
    #expect(ink.count { $0 < Self.radius - 24 } == 0, "ink landed well inside the ring")
    #expect(ink.count { $0 > Self.radius + 24 } == 0, "ink landed well outside the ring")
  }

  /// START pins the string's leading edge at the start angle and END its trailing edge, so the two
  /// cannot put ink in the same places — that difference is the whole of the alignment arithmetic.
  @Test func alignmentMovesTheStringAroundTheRingWithoutLeavingIt() throws {
    let start = try render(Documents.textOnCircle(alignment: Alignment.start))
    let end = try render(Documents.textOnCircle(alignment: Alignment.end))

    #expect(start.onRing > 0 && end.onRing > 0)
    #expect(
      start.ringSignature != end.ringSignature,
      "START and END put the string in the same place; the alignment offset is not applied")
    #expect(start.count { $0 < Self.radius - 24 } == 0)
    #expect(end.count { $0 < Self.radius - 24 } == 0)
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

    #expect(ink.count { _ in true } == 0)
  }

  /// Every geometry field may be a float variable (`width / 2` in `RemoteTimeText`), not only a
  /// literal; each resolves through the document's floats.
  @Test func variableGeometryDrawsWhatTheSameLiteralsDraw() throws {
    let literal = try render(Documents.textOnCircle())
    let variable = try render(
      Documents.textOnCircle(
        radius: .variable(51), warp: .variable(53), center: .variable(50),
        startAngle: .variable(52),
        definitions: [
          (50, Self.center), (51, Self.radius - Documents.textOnCircleWarp), (52, -90),
          (53, Documents.textOnCircleWarp),
        ]))

    #expect(literal.onRing > 0)
    #expect(literal.ringSignature == variable.ringSignature)
    #expect(literal.count { _ in true } == variable.count { _ in true })
  }

  /// A variable nothing has written yet is not a number, as in the Kotlin player (`resolve` falls
  /// back to the word itself): the draw is skipped rather than made at the origin.
  @Test func anUnresolvedCentreDrawsNothingRatherThanThrowing() throws {
    #expect(try render(Documents.textOnCircle(center: .variable(50))).count { _ in true } == 0)
  }

  /// The unusable circle never reaches a host: the core drops the command, so neither the hosts'
  /// finite-geometry budget nor their draw sees a NaN.
  @Test func theCoreDropsAnUnusableCircleAndKeepsAUsableOne() throws {
    func commands(_ data: Data) throws -> [NativeSwiftDrawCommandSnapshot] {
      func all(_ node: NativeSwiftNodeSnapshot) -> [NativeSwiftDrawCommandSnapshot] {
        node.commands + node.children.flatMap(all)
      }
      return all(try NativeSwiftDocumentSession.open(data: data).snapshot().root)
        .filter { $0.kind == NativeSwiftDrawKind.textOnCircle }
    }
    #expect(try commands(Documents.textOnCircle(center: .variable(50))).isEmpty)
    #expect(try commands(Documents.textOnCircle(radius: .literal(0), warp: .literal(0))).isEmpty)
    let drawn = try #require(try commands(Documents.textOnCircle(alignment: Alignment.end)).first)
    let circle = try #require(NativeSwiftTextOnCircle(drawn))
    #expect(circle.radius == Self.radius && circle.alignment == Alignment.end)
    #expect(drawn.text == "REMOTE COMPOSE" && drawn.textSize == 18)
  }

  /// A live document can move the radius through zero and back: the command leaves the frame
  /// while the circle is empty and returns, at the new radius, once it is not — nothing about the
  /// empty frame sticks.
  @Test func aRadiusThatPassesThroughZeroDropsTheDrawAndBringsItBack() throws {
    let session = try NativeSwiftDocumentSession.open(
      data: Documents.textOnCircle(
        radius: .variable(51), definitions: [(51, Self.radius - Documents.textOnCircleWarp)],
        names: [(51, "radius")]))
    func circles() throws -> [NativeSwiftTextOnCircle] {
      func all(_ node: NativeSwiftNodeSnapshot) -> [NativeSwiftDrawCommandSnapshot] {
        node.commands + node.children.flatMap(all)
      }
      return try all(session.snapshot().root).compactMap(NativeSwiftTextOnCircle.init)
    }
    #expect(try circles().map(\.radius) == [Self.radius])
    #expect(session.setFloat(-Documents.textOnCircleWarp, for: "radius"))
    #expect(try circles().isEmpty, "an empty circle still drew")
    #expect(session.setFloat(50, for: "radius"))
    #expect(try circles().map(\.radius) == [50 + Documents.textOnCircleWarp])
  }

  /// Opt-in: writes the PR's evidence when `RC_TEXT_ON_CIRCLE_OUT` names a directory, and passes
  /// without writing otherwise — the Kotlin evidence strip's dial without and with its curved
  /// label, rendered by this host, and the labelled dial's document, for rendering on a base
  /// build.
  @Test func writesTheEvidencePair() throws {
    guard let out = ProcessInfo.processInfo.environment["RC_TEXT_ON_CIRCLE_OUT"] else { return }
    let directory = URL(fileURLWithPath: out, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (name, withCurvedText) in [("dial", false), ("dial-text-on-circle", true)] {
      let document = Documents.textOnCircle(dial: withCurvedText)
      try document.write(to: directory.appendingPathComponent("\(name).rc"))
      try png(document)
        .write(to: directory.appendingPathComponent("\(Self.platform)-\(name).png"))
    }
  }

  // MARK: - Rendering and ink

  /// Where the dark pixels of one frame are, relative to the circle's centre.
  struct Ink {
    /// The distance from the centre and the angle in degrees, 0..<360, of each dark pixel.
    let pixels: [(distance: Float, degrees: Double)]

    func count(where accept: (Float) -> Bool) -> Int { pixels.filter { accept($0.distance) }.count }

    /// Dark pixels within a few points of the ring's own radius.
    var onRing: Int {
      count { abs($0 - NativeTextOnCircleRenderTests.radius) <= 16 }
    }

    /// Where the ink sits around the ring, as 36 ten-degree buckets.
    var ringSignature: [Bool] {
      var buckets = [Bool](repeating: false, count: 36)
      for pixel in pixels { buckets[min(max(Int(pixel.degrees / 10), 0), 35)] = true }
      return buckets
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
        let degrees = (atan2(Double(dy), Double(dx)) * 180 / .pi + 360)
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
