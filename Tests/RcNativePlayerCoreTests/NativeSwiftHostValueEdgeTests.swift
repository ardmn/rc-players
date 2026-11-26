import Foundation
import Testing

@testable @_spi(Conformance) @_spi(RemoteComposeController) import RcNativePlayerCore

/// Every value a host may write, as AndroidX's `setNamed*Override` takes it — NaN, the infinities
/// and strings far over a document string's 4000 bytes — is accepted, and reaches each float and
/// text consumer without trapping, hanging or failing the frame. The documents are the Kotlin
/// `RcHostValueEdgeRenderTest`'s (`Fixtures/host-value-edges`), which the Kotlin player renders
/// with the same values.
@Suite(.timeLimit(.minutes(2))) struct NativeSwiftHostValueEdgeTests {
  static let floats: [Float] = [.nan, .infinity, -.infinity, -0.0, 3e9]
  static let texts = [
    String(repeating: "x", count: 4_001), String(repeating: "word ", count: 20_000),
    String(repeating: "\u{1F600}", count: 50_000),
  ]

  @Test(arguments: try HostValueEdgeFixtures.cases(kind: "float"))
  func everyFloatConsumerTakesNonFiniteHostValues(_ name: String) throws {
    let data = try HostValueEdgeFixtures.document(name)
    for value in Self.floats {
      let session = try NativeSwiftDocumentSession.open(data: data)
      #expect(session.setFloat(value, for: HostValueEdgeFixtures.floatName), "\(name) \(value)")
      try HostValueEdgeFixtures.frames(session, "\(name) with \(value)")
    }
  }

  @Test(arguments: try HostValueEdgeFixtures.cases(kind: "text"))
  func everyTextConsumerTakesAStringFarOverADocumentString(_ name: String) throws {
    let data = try HostValueEdgeFixtures.document(name)
    for text in Self.texts {
      let session = try NativeSwiftDocumentSession.open(data: data)
      #expect(session.setString(text, for: HostValueEdgeFixtures.textName), "\(name)")
      try HostValueEdgeFixtures.frames(session, "\(name) with \(text.utf16.count) units")
    }
  }

  /// A host offset reaches the snapshot as a finite number: NaN reads 0 and an infinity is held at
  /// the largest finite float of its sign, as the Kotlin player's `javaRoundToInt` reads it and as
  /// `resolvedFloat` saturates a padding.
  @Test func aHostOffsetIsSaturatedInTheSnapshot() throws {
    let data = try HostValueEdgeFixtures.document("offset")
    let cases: [(Float, Float)] = [
      (.nan, 0), (.infinity, .greatestFiniteMagnitude), (-.infinity, -.greatestFiniteMagnitude),
      (3e9, 3e9), (-12.5, -12.5),
    ]
    for (value, expected) in cases {
      let session = try NativeSwiftDocumentSession.open(data: data)
      #expect(session.setFloat(value, for: HostValueEdgeFixtures.floatName))
      let snapshot = try session.snapshot(timeSeconds: 0)
      var offsets: [(Float, Float)] = []
      var pending = [snapshot.root]
      while let node = pending.popLast() {
        offsets.append((node.offsetX, node.offsetY))
        pending.append(contentsOf: node.children)
      }
      #expect(offsets.allSatisfy { $0.0.isFinite && $0.1.isFinite }, "\(value): \(offsets)")
      #expect(
        offsets.contains { $0.0 == expected && $0.1 == expected }
          || (expected == 0 && offsets.allSatisfy { $0.0 == 0 && $0.1 == 0 }),
        "\(value): \(offsets)")
    }
  }
}

/// `Fixtures/host-value-edges`: one document per consumer, and `index.tsv` naming each with the
/// kind of value it takes.
enum HostValueEdgeFixtures {
  /// The names the Kotlin test declares, `RcHostValueEdgeRenderTest.FLOAT_NAME` and `TEXT_NAME`.
  static let floatName = "USER:v"
  static let textName = "USER:s"
  static let directory = "host-value-edges"

  static func cases(kind: String) throws -> [String] {
    let index = try String(
      decoding: NativeTestFixtures.data("\(directory)/index.tsv"), as: UTF8.self)
    let rows = index.split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
    return rows.filter { $0.count == 2 && $0[1] == kind }.map { $0[0] }
  }

  static func document(_ name: String) throws -> Data {
    try NativeTestFixtures.data("\(directory)/\(name).rc")
  }

  /// A few frames, as the Kotlin test renders, so an animation steps.
  static func frames(_ session: NativeSwiftDocumentSession, _ label: String) throws {
    for frame in 0...4 {
      #expect(throws: Never.self, "\(label), frame \(frame)") {
        _ = try session.snapshot(timeSeconds: TimeInterval(frame) * 0.016)
      }
    }
  }
}
