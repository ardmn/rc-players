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

  /// The fill fractions a host or a document may resolve that AndroidX lays out.
  static let unusualFillFractions: [Float] = [-0.5, -.infinity, .infinity, .nan]
}
