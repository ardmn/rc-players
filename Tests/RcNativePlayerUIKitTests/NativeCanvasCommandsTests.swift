import CoreGraphics
import Foundation
import Testing

@testable import RcNativePlayerCore
@testable import RcNativePlayerUIKit

/// What a non-finite value stops drawing, as AndroidX's Skia canvas stops it
/// (`NativeCanvasCommands.drawable`), and how the players hold the rest: shared by the UIKit and
/// AppKit renderers, so it runs on both.
@Suite struct NativeCanvasCommandsTests {
  typealias Kind = NativeSwiftDrawKind

  static func command(
    _ kind: Int, _ values: [Float] = [], alpha: Float = 1, path: [Float]? = nil
  ) -> NativeSwiftDrawCommandSnapshot {
    NativeSwiftDrawCommandSnapshot(
      kind: kind, values: values, colorARGB: 0xff00_00ff, alpha: alpha, strokeWidth: 1,
      isStroke: false, strokeCap: .butt, strokeJoin: .miter, blendMode: .sourceOver,
      path: path.map {
        [NativeSwiftPathElementSnapshot(kind: NativeSwiftPathCommand.move, values: $0)]
      } ?? [],
      pathWinding: .nonZero, image: nil, textureImageID: nil, textureTileModeX: 0,
      textureTileModeY: 0, shaderMatrix: nil, filterQuality: nil, usesComponentGeometry: false,
      gradient: nil, text: nil, textSize: 14, textFlags: 0, unsetValueIndices: [],
      offscreenTarget: nil)
  }

  static let save = command(Kind.matrixSave)
  static let restore = command(Kind.matrixRestore)
  /// A rect at `x`, so the kept draws can be told apart.
  static func rect(_ x: Float) -> NativeSwiftDrawCommandSnapshot {
    command(Kind.rect, [x, 0, x + 5, 5])
  }

  /// The kept commands as kinds, a rect as its x.
  static func kept(_ commands: [NativeSwiftDrawCommandSnapshot]) -> [String] {
    NativeCanvasCommands.drawable(commands).map {
      $0.kind == Kind.rect ? "rect \(Int($0.values[0]))" : "kind \($0.kind)"
    }
  }

  static let badTransforms: [NativeSwiftDrawCommandSnapshot] = [
    command(Kind.matrixTranslate, [.nan, 0]), command(Kind.matrixTranslate, [0, .infinity]),
    command(Kind.matrixScale, [.nan, 1, .nan, .nan]), command(Kind.matrixScale, [1, 1, 5, .nan]),
    command(Kind.matrixRotate, [.infinity, .nan, .nan]),
    command(Kind.matrixRotate, [45, -.infinity, 0]), command(Kind.matrixSkew, [.nan, 0]),
    command(Kind.matrixFromPath, [1, 0, 0, 1, .nan, 0]),
  ]

  /// Skia rejects every draw under a non-finite matrix (`SkCanvas::quickReject`) until the restore
  /// that pops it; a nested scope inherits it, and the scope outside it draws again.
  @Test(arguments: badTransforms)
  func aNonFiniteTransformDrawsNothingUntilItsRestore(_ transform: NativeSwiftDrawCommandSnapshot) {
    let commands = [
      Self.save, transform, Self.rect(1), Self.save, Self.rect(2), Self.restore, Self.rect(3),
      Self.restore, Self.rect(4),
    ]
    #expect(
      Self.kept(commands) == ["kind 0", "kind 0", "kind 1", "kind 1", "rect 4"],
      "\(transform.kind) \(transform.values)")
  }

  /// Without a save, the node's own scope draws nothing more; a stray restore does not end it.
  @Test func aNonFiniteTransformOutsideASaveSuppressesTheRestOfTheNode() {
    let commands = [
      Self.rect(1), Self.command(Kind.matrixTranslate, [.nan, .nan]), Self.restore, Self.rect(2),
    ]
    #expect(Self.kept(commands) == ["rect 1", "kind 1"])
  }

  /// A NaN pivot x is AndroidX's "no pivot" (`AndroidPaintContext.matrixRotate`,
  /// `matrixScale`): the transform applies, its pivot y ignored with it.
  @Test func aNaNPivotIsNoPivot() {
    let rotate = Self.command(Kind.matrixRotate, [45, .nan, .infinity])
    let scale = Self.command(Kind.matrixScale, [2, 3, .nan, .nan])
    #expect(Self.kept([rotate, scale, Self.rect(1)]) == ["kind 4", "kind 3", "rect 1"])
  }

  /// `SkCanvas::clipRect` returns without clipping for a non-finite rectangle.
  @Test func aNonFiniteClipRectIsIgnored() {
    let clip = Self.command(Kind.clipRect, [0, .nan, 10, 10])
    #expect(
      Self.kept([Self.save, clip, Self.rect(1), Self.restore]) == ["kind 0", "rect 1", "kind 1"])
  }

  /// `SkRegion::setPath` reads a non-finite path as empty: intersecting with it clips everything
  /// away until the restore; cutting it out changes nothing.
  @Test func aNonFiniteClipPathClipsAwayOnlyWhenItIntersects() {
    let intersect = Self.command(
      Kind.clipPath, [Float(NativeSwiftClipRegionOp.intersect)], path: [0, .nan])
    let difference = Self.command(
      Kind.clipPath, [Float(NativeSwiftClipRegionOp.difference)], path: [.infinity, 0])
    #expect(
      Self.kept([Self.save, intersect, Self.rect(1), Self.restore, Self.rect(2)])
        == ["kind 0", "kind 1", "rect 2"])
    #expect(Self.kept([difference, Self.rect(1)]) == ["rect 1"])
    // A region operation the renderers cannot read as an integer is no clip at all.
    let unreadable = Self.command(Kind.clipPath, [.nan], path: [0, 0])
    #expect(Self.kept([unreadable, Self.rect(1)]) == ["rect 1"])
  }

  /// Saves and restores pair up whatever their paint, and every other draw is judged on its own.
  @Test func savesAreKeptAndOtherDrawsDroppedOnTheirOwn() {
    let commands = [
      Self.command(Kind.matrixSave, alpha: .nan), Self.command(Kind.rect, [0, .nan, 5, 5]),
      Self.rect(1), Self.command(Kind.matrixRestore, alpha: .infinity),
    ]
    #expect(Self.kept(commands) == ["kind 0", "rect 1", "kind 1"])
  }

  /// A `DrawToBitmap` draws into another canvas (`AndroidPaintContext.drawToBitmap` swaps
  /// `mCanvas`), whose matrix the earlier transform did not touch.
  @Test func aDrawToBitmapEndsTheSuppression() {
    let commands = [
      Self.command(Kind.matrixTranslate, [.nan, 0]), Self.rect(1),
      Self.command(Kind.drawToBitmap), Self.rect(2),
    ]
    #expect(Self.kept(commands) == ["kind \(Kind.drawToBitmap)", "rect 2"])
  }

  // MARK: - Values the UIKit player draws

  /// A transform's operands and an arc's angles are not coordinates: a spinner's angle grows past
  /// the coordinate limit in 46 minutes at 360°/s, and clamping it froze the spinner.
  @Test func anglesScalesAndMatricesAreNotClampedAsCoordinates() {
    let limits = RemoteComposeNativeExecutionLimits(maximumCoordinateMagnitude: 10)
    let rotate = Self.command(Kind.matrixRotate, [1_000_090, 50, .nan])
    #expect(limits.drawValues(of: rotate).prefix(2) == [1_000_090, 50])
    #expect(limits.drawValues(of: rotate)[2].isNaN)
    let scale = Self.command(Kind.matrixScale, [1e7, -1e7, 20, 20])
    #expect(limits.drawValues(of: scale) == [1e7, -1e7, 20, 20])
    let matrix = Self.command(Kind.matrixFromPath, [100, 0, 0, 100, 1e8, 0])
    #expect(limits.drawValues(of: matrix) == [100, 0, 0, 100, 1e8, 0])
    let translate = Self.command(Kind.matrixTranslate, [1e8, -1e8])
    #expect(limits.drawValues(of: translate) == [1e8, -1e8])
    let arc = Self.command(Kind.arc, [-100, 0, 100, 5, 1_000_090, 1e7])
    #expect(limits.drawValues(of: arc) == [-10, 0, 10, 5, 1_000_090, 1e7])
    #expect(limits.drawValues(of: Self.command(Kind.rect, [-100, 0, 100, 5])) == [-10, 0, 10, 5])
  }

  // MARK: - The text budget

  /// A string counts at most the longest text a document can make by itself, a `TextMerge`
  /// result of 16K UTF-16 units of at most 3 bytes each; a host's longer string renders.
  @Test func aStringCountsAtMostTheLongestDocumentText() throws {
    #expect(
      RemoteComposeNativeExecutionLimits.longestDocumentTextBytes
        == 3 * NativeSwiftDocumentSession.maximumTextMergeLength)
    let longest = RemoteComposeNativeExecutionLimits.longestDocumentTextBytes
    var budget = NativeFrameBudget()
    try budget.recordStrings(
      [String(repeating: "\u{1F600}", count: 50_000)], limits: .default)
    #expect(budget.textBytes == longest && budget.work == longest)
    // A document's own text counts in full, and repeating it still runs out of budget.
    let documentText = String(repeating: "x", count: 4_000)
    var repeated = NativeFrameBudget()
    #expect(throws: RemoteComposeNativeLimitError.self) {
      for _ in 0..<40 { try repeated.recordStrings([documentText], limits: .default) }
    }
  }

  // MARK: - Texture tiling

  /// A shader matrix a host's NaN, infinity or extreme value reached paints nothing or the
  /// bitmap once; it must never trap converting the tile range to `Int`.
  @Test(arguments: [
    CGAffineTransform(a: .nan, b: 0, c: 0, d: 1, tx: 0, ty: 0),
    CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: .infinity, ty: 0),
    CGAffineTransform(a: 1e-30, b: 0, c: 0, d: 1e-30, tx: 0, ty: 0),
    CGAffineTransform(a: 1e-20, b: 0, c: 0, d: 1, tx: -1e30, ty: 0),
    CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: -1e30, ty: -1e30),
  ])
  func anExtremeShaderMatrixDoesNotTrap(_ transform: CGAffineTransform) throws {
    let context = try #require(
      CGContext(
        data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    let image = try #require(context.makeImage())
    for tileMode in [NativeGradientTiling.mirror, NativeGradientTiling.decal] {
      NativeTexturePolicy.paint(
        image: image, transform: transform, tileModeX: tileMode, tileModeY: tileMode,
        in: context)
    }
  }
}
