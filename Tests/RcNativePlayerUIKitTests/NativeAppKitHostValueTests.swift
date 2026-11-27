#if canImport(AppKit) && !targetEnvironment(macCatalyst)
  import AppKit
  import Foundation
  import RcNativePlayerTestDocuments
  import Testing

  @_spi(Conformance) @_spi(RemoteComposeController) @testable import RcNativePlayerCore
  @_spi(RemoteComposeController) @testable import RcNativePlayerUIKit

  /// The AppKit player's frame policy and capture with values AndroidX takes: a host's NaN,
  /// infinite, huge or long value, and a document's own non-finite fill or float, render rather
  /// than fail the frame. The documents are the core tests' `Fixtures/host-value-edges`, as the
  /// UIKit `NativeHostValueEdgeRenderTests` use them.
  @MainActor @Suite struct NativeAppKitHostValueTests {
    nonisolated static let values: [Float] = [.nan, .infinity, -.infinity, 1e30, -1e30]

    static func open(_ name: String) throws -> NativeSwiftDocumentSession {
      let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("RcNativePlayerCoreTests/Fixtures/host-value-edges")
      return try NativeSwiftDocumentSession.open(
        data: Data(contentsOf: directory.appendingPathComponent("\(name).rc")))
    }

    /// A 200 KB host string, over the 128 KiB a frame's own text may take: `setString` takes it,
    /// as AndroidX's `setNamedStringOverride` does, so the frame must render it.
    @Test(arguments: ["long-text", "long-text-length-as-width"])
    func aHostStringOverTheTextBudgetRenders(_ name: String) throws {
      let session = try Self.open(name)
      let text = String(repeating: "\u{1F600}", count: 50_000)
      #expect(session.setString(text, for: "USER:s"))
      let snapshot = try session.snapshot(timeSeconds: 0)
      #expect(throws: Never.self, "\(name) with \(text.utf8.count) bytes") {
        _ = try NativeMacPolicy.evaluate(snapshot, compatibility: .compatible)
      }
    }

    @Test(arguments: values)
    func aHostPaddingRenders(_ value: Float) throws {
      let session = try Self.open("padding")
      #expect(session.setFloat(value, for: "USER:v"))
      let snapshot = try session.snapshot(timeSeconds: 0)
      #expect(throws: Never.self, "\(value)") {
        _ = try NativeMacPolicy.evaluate(snapshot, compatibility: .compatible)
      }
    }

    /// RC_MACOS_PLAYER_APP.md: a resolved value never fails the frame by itself. A negative fill
    /// fraction lays out as no width and an infinite one as the parent's
    /// (`NativeLayoutDimension.resolve`), as AppKit drew them before the frame policy checked them.
    @Test(arguments: NativeHostValueDocuments.unusualFillFractions)
    func aNegativeOrInfiniteFillFractionDraws(_ fraction: Float) throws {
      let frame = try NativeAppKitWindowController.renderFrame(
        data: NativeHostValueDocuments.fillBox(fraction: fraction))
      let box = try #require(
        frame.tree.first { $0["id"] as? Int == NativeHostValueDocuments.fillBoxID },
        "\(frame.tree)")
      let width = try #require(box["width"] as? Double)
      #expect(width.isFinite && width >= 0 && width <= 100, "\(fraction): \(box)")
    }

    /// The comparison batch writes a frame's tree, values and records with `JSONSerialization`,
    /// which raises on a non-finite number. A float the document computes as NaN or an infinity
    /// (`0/0`, `±1/0`, as Java's float division gives them) is reported as Java's
    /// `Float.toString` spells it.
    @Test func aNonFiniteProbedFloatIsReportedAsValidJSON() throws {
      typealias Op = NativeSwiftWireOpcode
      let wire = NativeTestWire()
      wire.header(width: 100, height: 100)
      let spelled: [(id: Int, dividend: Float, divisor: Float, text: String)] = [
        (700, 0, 0, "NaN"), (701, 1, 0, "Infinity"), (702, -1, 0, "-Infinity"), (703, 3, 2, ""),
      ]
      let divide = NativeSwiftFloatExpression.operatorWord(NativeSwiftFloatOperator.div)
      for entry in spelled {
        wire.u8(Op.animatedFloat).int(entry.id).int(3).float(entry.dividend).float(entry.divisor)
          .int(Int(Int32(bitPattern: divide)))
      }
      wire.u8(Op.layoutRoot).int(1)
      wire.box(id: 10, size: 10)
      wire.u8(Op.containerEnd)
      let frame = try NativeAppKitWindowController.renderFrame(
        data: wire.data, values: NativeMacValueRequest(floats: spelled.map { String($0.id) }))
      let values = try #require(frame.values)
      let result: [String: Any] = ["tree": frame.tree, "values": values, "records": frame.records]
      #expect(JSONSerialization.isValidJSONObject(result))
      let floats = try #require(values["floats"] as? [String: Any])
      for entry in spelled where !entry.text.isEmpty {
        #expect(floats[String(entry.id)] as? String == entry.text, "\(floats)")
      }
      #expect(floats["703"] as? Double == 1.5, "\(floats)")
    }
  }
#endif
