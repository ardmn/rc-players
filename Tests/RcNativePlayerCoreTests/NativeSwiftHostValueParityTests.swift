import Foundation
import Testing

@testable @_spi(Conformance) @_spi(RemoteComposeController) import RcNativePlayerCore

/// The native player held to what AndroidX remote-core computes for host values it accepts: NaN,
/// the infinities and signed zeros read by every float operator, and NaN and infinities formatted
/// by `TextFromFloat` (each row's value as AndroidX's state holds it after the host's write).
/// `Fixtures/host-value-parity.tsv` is written by the Kotlin
/// `AndroidxHostValueParityTest` (`:rc-player-compat-tests`), which runs AndroidX itself and holds
/// the Kotlin player to the same table, so the three agree. Where AndroidX throws (an array
/// operator with no array, `A_SUM_TILL` past its limit) the table holds the Kotlin player's value,
/// marked `k`: the players do not crash there.
@Suite struct NativeSwiftHostValueParityTests {
  @Test func everyOperatorTreatsNonFiniteOperandsAsAndroidXDoes() throws {
    let fixture = try HostValueParityFixture.load()
    let triples = fixture.operands.flatMap { a in
      fixture.operands.flatMap { b in fixture.operands.map { c in [a, b, c] } }
    }
    #expect(fixture.operators.count > 70)
    var mismatches: [String] = []
    for (operation, expected) in fixture.operators {
      #expect(expected.count == triples.count, "operator \(operation)")
      let words =
        (1...3).map { 0xff80_0000 | UInt32($0) }
        + [NativeSwiftFloatExpression.operatorWord(operation)]
      for (operands, result) in zip(triples, expected) {
        let values = Dictionary(uniqueKeysWithValues: zip(1...3, operands))
        let actual =
          (try? NativeSwiftFloatExpression.evaluate(
            words, values: values, arrays: [:], opcode: 0, offset: 0)) ?? 0
        if !HostValueParityFixture.same(actual, result) {
          mismatches.append("operator \(operation) over \(operands): \(actual), AndroidX \(result)")
        }
      }
    }
    #expect(mismatches.isEmpty, "\(mismatches.count) mismatches:\n\(mismatches.prefix(40).joined(separator: "\n"))")
  }

  @Test func textFromFloatFormatsNonFiniteValuesAsAndroidXDoes() throws {
    let fixture = try HostValueParityFixture.load()
    #expect(fixture.texts.count > 100)
    var mismatches: [String] = []
    for row in fixture.texts {
      let actual = NativeSwiftTextFormatter.format(
        row.value, digitsBefore: row.before, digitsAfter: row.after, flags: row.flags)
      if actual != row.text {
        mismatches.append("\(row.value) \(row.before).\(row.after) \(row.flags): '\(actual)', AndroidX '\(row.text)'")
      }
    }
    #expect(mismatches.isEmpty, "\(mismatches.count) mismatches:\n\(mismatches.prefix(40).joined(separator: "\n"))")
  }

  /// The merge limit the fixture carries is the one the session applies.
  @Test func theMergeLimitIsAndroidXs() throws {
    let fixture = try HostValueParityFixture.load()
    #expect(fixture.mergeLimit == NativeSwiftDocumentSession.maximumTextMergeLength)
  }
}

/// `Fixtures/host-value-parity.tsv`, read strictly: an unknown row or a malformed value fails the
/// load instead of being skipped.
struct HostValueParityFixture {
  struct Malformed: Error, CustomStringConvertible {
    let description: String
  }

  struct TextRow {
    let value: Float
    let before: Int
    let after: Int
    let flags: Int
    let text: String
  }

  static let format = "host-value-parity-v1"

  var mergeLimit = 0
  var operands: [Float] = []
  var operators: [(Int, [Float])] = []
  var texts: [TextRow] = []

  static func load() throws -> Self {
    let text = try String(
      decoding: NativeTestFixtures.data("host-value-parity.tsv"), as: UTF8.self)
    var fixture = Self()
    var sawFormat = false
    for line in text.split(separator: "\n", omittingEmptySubsequences: true)
    where !line.hasPrefix("#") {
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      switch fields[0] {
      case "format":
        guard fields.count == 2, fields[1] == format else {
          throw Malformed(description: "format \(fields)")
        }
        sawFormat = true
      case "mergeLimit":
        fixture.mergeLimit = try integer(fields, 1)
      case "operands":
        fixture.operands = try fields.dropFirst().map(float)
      case "operator":
        fixture.operators.append((try integer(fields, 1), try fields.dropFirst(2).map(float)))
      case "text":
        guard fields.count == 6 else { throw Malformed(description: "text row \(fields)") }
        fixture.texts.append(
          TextRow(
            value: try float(fields[1]), before: try integer(fields, 2),
            after: try integer(fields, 3), flags: try integer(fields, 4), text: fields[5]))
      default:
        throw Malformed(description: "unknown row \(fields[0])")
      }
    }
    guard sawFormat, !fixture.operands.isEmpty else {
      throw Malformed(description: "no format or operands")
    }
    return fixture
  }

  /// Equal as the fixture means it: any NaN matches any NaN, and otherwise the bits, so -0.0 and
  /// 0.0 differ.
  static func same(_ actual: Float, _ expected: Float) -> Bool {
    expected.isNaN ? actual.isNaN : actual.bitPattern == expected.bitPattern
  }

  private static func integer(_ fields: [String], _ index: Int) throws -> Int {
    guard fields.indices.contains(index), let value = Int(fields[index]) else {
      throw Malformed(description: "integer at \(index) in \(fields)")
    }
    return value
  }

  /// Eight hex digits of a float's bits, `k`-prefixed where the value is the Kotlin player's.
  private static func float(_ field: String) throws -> Float {
    let digits = field.hasPrefix("k") ? field.dropFirst() : Substring(field)
    guard digits.count == 8, let bits = UInt32(digits, radix: 16) else {
      throw Malformed(description: "float \(field)")
    }
    return Float(bitPattern: bits)
  }
}
