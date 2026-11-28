#if canImport(UIKit)
  import Foundation
  import Testing
  import RcNativePlayerTestDocuments
  import UIKit

  @_spi(Conformance) @_spi(RemoteComposeController) @testable import RcNativePlayerCore
  @_spi(RemoteComposeController) @testable import RcNativePlayerUIKit

  /// Every value a host may write renders on UIKit with finite component frames, on the Kotlin
  /// `RcHostValueEdgeRenderTest` documents; documents that abuse the frame budget stay refused.
  @MainActor @Suite(.serialized, .timeLimit(.minutes(10))) struct NativeHostValueEdgeRenderTests {
    static let floats: [Float] = [.nan, .infinity, -.infinity, 1e9, -0.0]
    static let texts = [
      String(repeating: "x", count: 100_000), String(repeating: "word ", count: 20_000),
      String(repeating: "\u{1F600}", count: 25_000),
    ]

    @Test(arguments: try UIKitHostValueEdgeFixtures.cases(kind: "float"))
    func everyFloatConsumerRendersNonFiniteAndHugeHostValues(_ name: String) async throws {
      for value in Self.floats {
        try await UIKitHostValueEdgeFixtures.render(
          name, .float(value), for: UIKitHostValueEdgeFixtures.floatName, "\(name) with \(value)")
      }
    }

    @Test(arguments: try UIKitHostValueEdgeFixtures.cases(kind: "text"))
    func everyTextConsumerRendersAHundredKilobyteHostString(_ name: String) async throws {
      for text in Self.texts {
        try await UIKitHostValueEdgeFixtures.render(
          name, .text(text), for: UIKitHostValueEdgeFixtures.textName,
          "\(name) with \(text.utf8.count) bytes")
      }
    }

    /// A 200 KB host string, over the 192 KiB of text one frame may lay out, counts as the longest
    /// text a document can make by itself (`longestDocumentTextBytes`) and renders, as AndroidX
    /// shows it (`AndroidRemoteContext.setNamedStringOverride`).
    @Test(arguments: ["long-text", "long-text-length-as-width"])
    func aHostStringOverTheTextBudgetRenders(_ name: String) async throws {
      let text = String(repeating: "\u{1F600}", count: 50_000)
      #expect(text.utf8.count > RemoteComposeNativeExecutionLimits.default.maximumTextBytes)
      try await UIKitHostValueEdgeFixtures.render(
        name, .text(text), for: UIKitHostValueEdgeFixtures.textName,
        "\(name) with \(text.utf8.count) bytes")
    }

    /// A negative fill fraction lays out as no width and an infinite one as the parent's
    /// (`NativeLayoutDimension.resolve`), as on AppKit (`NativeAppKitHostValueTests`): a resolved
    /// value never fails the frame by itself.
    @Test(arguments: NativeHostValueDocuments.unusualFillFractions)
    func aNegativeOrInfiniteFillFractionDraws(_ fraction: Float) async throws {
      var errors: [RemoteComposeNativePlayerError] = []
      let view = RemoteComposeNativePlayerView(
        data: NativeHostValueDocuments.fillBox(fraction: fraction), resourceResolver: nil,
        onError: { errors.append($0) })
      view.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
      try await waitUntil("\(fraction) opens", within: 60) {
        !view.isOpeningDocument && !view.isBusy
      }
      view.layoutIfNeeded()
      #expect(errors.isEmpty, "\(fraction): \(errors)")
      #expect(!UIKitHostValueEdgeFixtures.showsTheErrorLabel(view), "\(fraction)")
      var pending: [UIView] = [view]
      var box: NativeComponentView?
      while box == nil, let next = pending.popLast() {
        box = (next as? NativeComponentView)?.descendant(withID: NativeHostValueDocuments.fillBoxID)
        pending.append(contentsOf: next.subviews)
      }
      let width = try #require(box, "\(fraction): no box").frame.width
      #expect(width.isFinite && width >= 0 && width <= 100, "\(fraction): \(width)")
    }

    /// A host's NaN, infinite, huge or negative text size or weight renders, as the core and the
    /// Kotlin player take it (`rcTextSizePixels`, `rcFontWeight`): a NaN or negative size is
    /// Android's 12 px (hwui `jni/Paint.cpp:1001`) and a NaN weight the normal 400.
    @Test(arguments: NativeHostValueDocuments.unusualTextSizesAndWeights)
    func aHostTextSizeOrWeightRenders(_ value: Float) async throws {
      var errors: [RemoteComposeNativePlayerError] = []
      let view = RemoteComposeNativePlayerView(
        data: NativeHostValueDocuments.hostTextSizeAndWeight(), resourceResolver: nil,
        onError: { errors.append($0) })
      view.frame = CGRect(x: 0, y: 0, width: 100, height: 60)
      try await waitUntil("\(value) opens", within: 60) {
        !view.isOpeningDocument && !view.isBusy
      }
      let result = await view.submit(
        .float(value), for: NativeHostValueDocuments.hostTextFloatName)
      #expect(result == .accepted, "\(value)")
      try await waitUntil("\(value) settles", within: 60) { !view.isBusy }
      view.setNeedsLayout()
      view.layoutIfNeeded()
      _ = UIGraphicsImageRenderer(size: view.bounds.size).image {
        view.layer.render(in: $0.cgContext)
      }
      #expect(errors.isEmpty, "\(value): \(errors)")
      #expect(!UIKitHostValueEdgeFixtures.showsTheErrorLabel(view), "\(value)")
    }

    /// A host's 1e9 width is clamped to the parent, as AndroidX's measure clamps an exact size to
    /// the maximum constraint (`BaseModernMeasurePolicy.measure`, `LegacyMeasurePolicy.measure`),
    /// and a NaN offset reads 0, as Java's `(int)` reads it where the Kotlin player rounds one.
    @Test func aHugeWidthFillsTheParentAndANaNOffsetReadsZero() async throws {
      let width = try await UIKitHostValueEdgeFixtures.render(
        "width", .float(1e9), for: UIKitHostValueEdgeFixtures.floatName, "width 1e9")
      #expect(width.canvasFrame?.width == UIKitHostValueEdgeFixtures.size.width)
      let offset = try await UIKitHostValueEdgeFixtures.render(
        "offset", .float(.nan), for: UIKitHostValueEdgeFixtures.floatName, "offset NaN")
      let plain = try await UIKitHostValueEdgeFixtures.render(
        "offset", .float(0), for: UIKitHostValueEdgeFixtures.floatName, "offset 0")
      #expect(offset.canvasFrame != nil && offset.canvasFrame == plain.canvasFrame)
    }

    // MARK: - Hostile documents are still refused

    /// One 4000-byte document string (AndroidX `Limits.MAX_STRING_SIZE`) shown by 50 texts is
    /// over the 192 KiB of text one frame may show: the document is refused, not laid out.
    @Test func aDocumentRepeatingItsTextPastTheBudgetIsRefused() async throws {
      typealias Op = NativeSwiftWireOpcode
      let wire = NativeTestWire()
      wire.header(width: 100, height: 100)
      let textID = 700
      wire.u8(Op.dataText).int(textID).utf8(String(repeating: "x", count: 4_000))
      wire.u8(Op.layoutRoot).int(1)
      for index in 0..<50 { wire.text(id: 3000 + index, reading: textID) }
      wire.u8(Op.containerEnd)
      let error = try await UIKitHostValueEdgeFixtures.refusal(of: wire.data)
      let limit = RemoteComposeNativeExecutionLimits.default.maximumTextBytes
      #expect(error.contains("UTF-8 bytes; the limit is \(limit)"), "\(error)")
    }

    /// A document of more nodes than the budget is refused (the core's decoder, sharing the
    /// player's 20,000, refuses it first), whatever its values.
    @Test func aDocumentOverTheNodeBudgetIsRefused() async throws {
      let count = RemoteComposeNativeExecutionLimits.default.maximumNodeCount
      let wire = NativeTestWire()
      wire.header(width: 100, height: 100)
      wire.u8(NativeSwiftWireOpcode.layoutRoot).int(1)
      // A box and its content are two nodes.
      for index in 0...(count / 2) { wire.box(id: 10 + index, size: 1, content: 50_000 + index) }
      wire.u8(NativeSwiftWireOpcode.containerEnd)
      let error = try await UIKitHostValueEdgeFixtures.refusal(of: wire.data)
      #expect(error.contains("Node count exceeds \(count)"), "\(error)")
    }

    // MARK: - The normalisation itself

    /// A failed write is recognised by its value on the next open (`failedWrites`,
    /// `takenHostWrites`), so a NaN must equal a NaN there, as Kotlin's boxed `==` compares
    /// floats (`floatToIntBits`): every NaN alike, 0 not -0.
    @Test func aNaNWriteIsTheSameValueAsItself() {
      let payloadNaN = Float(bitPattern: Float.nan.bitPattern | 1)
      #expect(NativeSwiftNamedValue.float(.nan).isSameValue(as: .float(payloadNaN)))
      #expect(NativeSwiftNamedValue.floatArray([1, .nan]).isSameValue(as: .floatArray([1, .nan])))
      #expect(
        NativeSwiftNamedValue.integer(3, float: .nan).isSameValue(as: .integer(3, float: .nan)))
      #expect(!NativeSwiftNamedValue.float(0).isSameValue(as: .float(-0.0)))
      #expect(!NativeSwiftNamedValue.float(.nan).isSameValue(as: .float(1)))
      #expect(!NativeSwiftNamedValue.integer(3, float: nil).isSameValue(as: .integer(3, float: 3)))
      #expect(!NativeSwiftNamedValue.floatArray([.nan]).isSameValue(as: .floatArray([.nan, 1])))
      #expect(NativeSwiftNamedValue.text("a").isSameValue(as: .text("a")))
      #expect(!NativeSwiftNamedValue.float(1).isSameValue(as: .text("1")))
    }

    @Test func layoutFloatsReadNaNAsZeroAndStayWithinTheCoordinateLimit() {
      let limits = RemoteComposeNativeExecutionLimits(maximumCoordinateMagnitude: 10)
      #expect(limits.layoutCoordinate(.nan) == 0)
      #expect(limits.layoutCoordinate(.infinity) == 10)
      #expect(limits.layoutCoordinate(-.infinity) == -10)
      #expect(limits.layoutCoordinate(-3) == -3)
      #expect(limits.layoutCoordinate(1e9) == 10)
    }

    @Test func anExactSizeStaysWithinTheCanvasLimitAndAFillKeepsItsNaN() {
      let limits = RemoteComposeNativeExecutionLimits(
        maximumCanvasDimension: 100, maximumCoordinateMagnitude: 10)
      let exact = NativeSwiftDimensionType.exact
      #expect(limits.layoutDimension(1e9, type: exact) == 100)
      #expect(limits.layoutDimension(-.infinity, type: exact) == -100)
      #expect(limits.layoutDimension(.nan, type: NativeSwiftDimensionType.exactDp) == 0)
      #expect(limits.layoutDimension(50, type: exact) == 50)
      #expect(limits.layoutDimension(.nan, type: NativeSwiftDimensionType.fill).isNaN)
      #expect(limits.layoutDimension(1e9, type: NativeSwiftDimensionType.weight) == 10)
    }

    @Test func aNonFiniteDrawIsDroppedAndAHugeOneClamped() {
      let limits = RemoteComposeNativeExecutionLimits(maximumCoordinateMagnitude: 10)
      func rect(
        _ values: [Float], strokeWidth: Float = 1, isStroke: Bool = false, path: [Float] = []
      ) -> NativeSwiftDrawCommandSnapshot
      {
        let elements =
          path.isEmpty
          ? [] : [NativeSwiftPathElementSnapshot(kind: NativeSwiftPathCommand.move, values: path)]
        return NativeSwiftDrawCommandSnapshot(
          kind: NativeSwiftDrawKind.rect, values: values, colorARGB: 0xff00_00ff, alpha: 1,
          strokeWidth: strokeWidth, isStroke: isStroke, strokeCap: .butt, strokeJoin: .miter,
          blendMode: .sourceOver, path: elements,
          pathWinding: .nonZero, image: nil, textureImageID: nil, textureTileModeX: 0,
          textureTileModeY: 0, shaderMatrix: nil, filterQuality: nil,
          usesComponentGeometry: false, gradient: nil, text: nil, textSize: 14, textFlags: 0,
          unsetValueIndices: [], offscreenTarget: nil)
      }
      #expect(limits.isDrawable(rect([0, 0, 5, 5])))
      #expect(!limits.isDrawable(rect([0, .nan, 5, 5])))
      #expect(!limits.isDrawable(rect([0, 0, .infinity, 5])))
      // Only a stroke reads the width (Skia's `SkCanvas` rejects a stroke's infinite bounds).
      #expect(limits.isDrawable(rect([0, 0, 5, 5], strokeWidth: .infinity)))
      #expect(!limits.isDrawable(rect([0, 0, 5, 5], strokeWidth: .infinity, isStroke: true)))
      #expect(!limits.isDrawable(rect([0, 0, 5, 5], path: [-.infinity, 0])))
      let clamped = NativeDrawCommand(rect([-1e9, 0, 1e9, 5], path: [1e9, -1e9]), limits: limits)
      #expect(clamped.values == [-10, 0, 10, 5])
      #expect(clamped.path.first?.values == [10, -10])
    }
  }

  /// The core tests' `Fixtures/host-value-edges`, read from the source tree so the documents stay
  /// the one copy the Kotlin test checks.
  @MainActor enum UIKitHostValueEdgeFixtures {
    /// `RcHostValueEdgeRenderTest.FLOAT_NAME` and `TEXT_NAME`, `WIDTH` and `HEIGHT`.
    static let floatName = "USER:v"
    static let textName = "USER:s"
    static let size = CGSize(width: 100, height: 60)
    /// The fixtures' canvas component.
    static let canvasID = 3
    nonisolated static var directory: URL {
      URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("RcNativePlayerCoreTests/Fixtures/host-value-edges")
    }

    nonisolated static func cases(kind: String) throws -> [String] {
      let index = try String(
        contentsOf: directory.appendingPathComponent("index.tsv"), encoding: .utf8)
      let rows = index.split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
      return rows.filter { $0.count == 2 && $0[1] == kind }.map { $0[0] }
    }

    struct Rendered {
      let canvasFrame: CGRect?
    }

    /// Opens `name` in a player view, writes `value`, and requires the write accepted, nothing
    /// reported, the document shown rather than the error label, every component frame finite,
    /// and a few frames drawn.
    @discardableResult
    static func render(
      _ name: String, _ value: RemoteComposeNativeNamedValue, for variable: String,
      _ label: String
    ) async throws -> Rendered {
      var errors: [RemoteComposeNativePlayerError] = []
      let view = RemoteComposeNativePlayerView(
        data: try Data(contentsOf: directory.appendingPathComponent("\(name).rc")),
        resourceResolver: nil, onError: { errors.append($0) })
      view.frame = CGRect(origin: .zero, size: size)
      try await waitUntil("\(label) opens", within: 60) {
        !view.isOpeningDocument && !view.isBusy
      }
      #expect(errors.isEmpty, "\(label) before the write: \(errors)")
      #expect(await view.submit(value, for: variable) == .accepted, "\(label)")
      try await waitUntil("\(label) settles", within: 60) { !view.isBusy }
      for _ in 0..<4 {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: size).image {
          view.layer.render(in: $0.cgContext)
        }
        #expect(image.size == size, "\(label)")
      }
      #expect(errors.isEmpty, "\(label): \(errors)")
      #expect(!showsTheErrorLabel(view), "\(label) shows the error label")
      var pending: [UIView] = [view]
      var canvasFrame: CGRect?
      while let next = pending.popLast() {
        if let component = next as? NativeComponentView {
          let frame = component.frame
          let isFinite = [frame.minX, frame.minY, frame.width, frame.height].allSatisfy {
            $0.isFinite
          }
          #expect(isFinite, "\(label): a component at \(frame)")
          if canvasFrame == nil { canvasFrame = component.descendant(withID: canvasID)?.frame }
        }
        pending.append(contentsOf: next.subviews)
      }
      return Rendered(canvasFrame: canvasFrame)
    }

    /// The error the player reports for `data`, which it must refuse rather than show.
    static func refusal(of data: Data) async throws -> String {
      var errors: [RemoteComposeNativePlayerError] = []
      let view = RemoteComposeNativePlayerView(
        data: data, resourceResolver: nil, onError: { errors.append($0) })
      view.frame = CGRect(origin: .zero, size: CGSize(width: 100, height: 100))
      try await waitUntil("the refusal", within: 120) {
        !view.isOpeningDocument && !view.isBusy && !errors.isEmpty
      }
      #expect(showsTheErrorLabel(view), "the refused document is not reported on screen")
      return errors.map { String(describing: $0) }.joined(separator: "; ")
    }

    /// Whether the player shows its own error label, not a label inside the document.
    static func showsTheErrorLabel(_ view: RemoteComposeNativePlayerView) -> Bool {
      view.subviews.contains { ($0 as? UILabel)?.isHidden == false }
    }
  }
#endif
