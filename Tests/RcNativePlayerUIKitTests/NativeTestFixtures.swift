import Foundation
import RcNativePlayerCore
import RcNativePlayerTestDocuments

/// The platform tests' fixtures, copied into this test bundle by the manifest's `.copy("Fixtures")`.
///
/// The fonts live here, and a copy of the one document `NativePlayerEngineTests` drives. The other
/// `.rc` documents belong to `RcNativePlayerCoreTests`, which has its own copy of this helper
/// reading its own bundle, so the core suite can run without the platform targets.
enum NativeTestFixtures {
  struct Missing: Error, CustomStringConvertible {
    let name: String
    var description: String { "test fixture not bundled: Fixtures/\(name)" }
  }

  static func url(_ name: String) throws -> URL {
    guard let directory = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
      throw Missing(name: name)
    }
    let url = directory.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: url.path) else { throw Missing(name: name) }
    return url
  }

  static func data(_ name: String) throws -> Data {
    try Data(contentsOf: url(name))
  }
}

/// Documents the UIKit and AppKit host-value suites both build.
enum NativeHostValueDocuments {
  /// The id of the box in ``fillBox(fraction:)``.
  static let fillBoxID = 10

  /// A 100×100 document whose box (``fillBoxID``), 10 high, fills `fraction` of its width.
  static func fillBox(fraction: Float) -> Data {
    typealias Op = NativeSwiftWireOpcode
    let wire = NativeTestWire()
    wire.header(width: 100, height: 100)
    wire.u8(Op.layoutRoot).int(1)
    wire.u8(Op.layoutBox).int(fillBoxID).int(-1).int(1).int(1)
    wire.u8(Op.modifierWidth).int(NativeSwiftDimensionType.fill).float(fraction)
    wire.u8(Op.modifierHeight).int(NativeSwiftDimensionType.exact).float(10)
    wire.u8(Op.layoutContent).int(fillBoxID + 100)
    wire.u8(Op.containerEnd)
    wire.u8(Op.containerEnd)
    wire.u8(Op.containerEnd)
    return wire.data
  }

  /// The id of the text in ``hostTextSizeAndWeight()``.
  static let hostTextID = 20
  /// The float both the text's size and weight read in ``hostTextSizeAndWeight()``.
  static let hostTextFloatName = "USER:v"

  /// A 100×60 document showing one text (``hostTextID``) whose font size and weight both read
  /// the host float ``hostTextFloatName``, declared 16.
  static func hostTextSizeAndWeight() -> Data {
    typealias Op = NativeSwiftWireOpcode
    let wire = NativeTestWire()
    wire.header(width: 100, height: 60)
    wire.u8(Op.dataFloat).int(700).float(16)
      .named(700, NativeTestWire.NamedType.float, hostTextFloatName)
    wire.u8(Op.dataText).int(701).utf8("hello")
    wire.u8(Op.layoutRoot).int(1)
    let reference = Int(Int32(bitPattern: 0xff80_0000 | 700))
    // TextLayout: component, animation, text, colour, size, style, weight, family, alignment,
    // overflow, maximum lines.
    wire.u8(Op.layoutText).int(hostTextID).int(0).int(701)
      .int(NativeTestDocuments.opaqueBlack).int(reference).int(0).int(reference).int(-1).int(1)
      .int(1).int(1)
    wire.u8(Op.containerEnd)
    wire.u8(Op.containerEnd)
    return wire.data
  }

  /// The host floats a text size or weight may read that AndroidX draws: Android's `Paint`
  /// ignores a NaN or negative size (hwui `jni/Paint.cpp:1001`) and keeps a reset paint's 12 px.
  static let unusualTextSizesAndWeights: [Float] = [.nan, .infinity, -.infinity, 1e30, -1]

  /// The fill fractions a host or a document may resolve that AndroidX lays out.
  static let unusualFillFractions: [Float] = [-0.5, -.infinity, .infinity, .nan]
}
