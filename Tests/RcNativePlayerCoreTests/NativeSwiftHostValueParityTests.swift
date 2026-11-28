import Foundation
import Testing

@testable @_spi(Conformance) @_spi(RemoteComposeController) import RcNativePlayerCore

/// Every float operator and `TextFromFloat` over NaN, infinities and signed zeros, against
/// `Fixtures/host-value-parity.tsv`, which the Kotlin `AndroidxHostValueParityTest` writes from
/// AndroidX itself. Rows where AndroidX throws hold the Kotlin player's value, marked `k`.
@Suite struct NativeSwiftHostValueParityTests {
  private typealias Op = NativeSwiftWireOpcode
  /// A NaN's bits whose low bits name the variable a float expression reads.
  private static let nanReferenceBits: UInt32 = 0xff80_0000

  /// The fixture's operators this player refuses over three operands, so a document using one
  /// fails to open rather than draw a value unlike AndroidX's.
  static let unimplementedOperators: [Int: String] = [
    NativeSwiftFloatOperator.arrayDeref: "A_DEREF: a missing list is refused, AndroidX reads 0",
    NativeSwiftFloatOperator.arraySpline: "A_SPLINE: no spline evaluator",
    NativeSwiftFloatOperator.randSeed: "RAND_SEED: AndroidX's seeded java.util.Random",
    NativeSwiftFloatOperator.noiseFrom: "NOISE_FROM: AndroidX's noise table",
    NativeSwiftFloatOperator.dup: "DUP",
    NativeSwiftFloatOperator.nop: "NOP",
    NativeSwiftFloatOperator.storeR0: "STORE_R0: no registers",
    NativeSwiftFloatOperator.storeR1: "STORE_R1: no registers",
    NativeSwiftFloatOperator.storeR2: "STORE_R2: no registers",
    NativeSwiftFloatOperator.storeR3: "STORE_R3: no registers",
    NativeSwiftFloatOperator.loadR0: "LOAD_R0: no registers",
    NativeSwiftFloatOperator.loadR1: "LOAD_R1: no registers",
    NativeSwiftFloatOperator.loadR2: "LOAD_R2: no registers",
    NativeSwiftFloatOperator.loadR3: "LOAD_R3: no registers",
    NativeSwiftFloatOperator.cmd1: "CMD1: only inside a particle loop, rewritten before evaluation",
    NativeSwiftFloatOperator.cmd2: "CMD2: only inside a particle loop, rewritten before evaluation",
    NativeSwiftFloatOperator.cmd3: "CMD3",
    NativeSwiftFloatOperator.cmd4: "CMD4",
    // 68 and 69 have no AndroidX name (AnimatedFloatExpression.java:239-245).
    68: "68: unnamed in AndroidX",
    69: "69: unnamed in AndroidX",
    NativeSwiftFloatOperator.cubic: "CUBIC: five operands; with three AndroidX throws too",
    NativeSwiftFloatOperator.arraySplineLoop: "A_SPLINE_LOOP: no spline evaluator",
    NativeSwiftFloatOperator.arraySumTill: "A_SUM_TILL",
    NativeSwiftFloatOperator.arraySumXY: "A_SUM_XY",
    NativeSwiftFloatOperator.arraySumSquares: "A_SUM_SQR",
    NativeSwiftFloatOperator.arrayLerp: "A_LERP",
  ]

  @Test func everyOperatorTreatsNonFiniteOperandsAsAndroidXDoes() throws {
    let fixture = try HostValueParityFixture.load()
    let triples = fixture.operands.flatMap { a in
      fixture.operands.flatMap { b in fixture.operands.map { c in [a, b, c] } }
    }
    #expect(fixture.operators.count > 70)
    var mismatches: [String] = []
    var compared = 0
    for (operation, expected) in fixture.operators {
      #expect(expected.count == triples.count, "operator \(operation)")
      let words =
        (1...3).map { Self.nanReferenceBits | UInt32($0) }
        + [NativeSwiftFloatExpression.operatorWord(operation)]
      let excluded = Self.unimplementedOperators[operation] != nil
      for (operands, result) in zip(triples, expected) {
        let values = Dictionary(uniqueKeysWithValues: zip(1...3, operands))
        do {
          let actual = try NativeSwiftFloatExpression.evaluate(
            words, values: values, arrays: [:], opcode: 0, offset: 0)
          if excluded {
            mismatches.append("operator \(operation) is listed as unimplemented but evaluates")
          } else if !HostValueParityFixture.same(actual, result) {
            mismatches.append(
              "operator \(operation) over \(operands): \(actual), AndroidX \(result)")
          } else {
            compared += 1
          }
        } catch is NativeSwiftCoreError where excluded {
          continue
        } catch {
          mismatches.append("operator \(operation) over \(operands): \(error)")
        }
      }
    }
    #expect(
      compared == (fixture.operators.count - Self.unimplementedOperators.count) * triples.count)
    #expect(
      mismatches.isEmpty,
      "\(mismatches.count) mismatches:\n\(mismatches.prefix(40).joined(separator: "\n"))")
  }

  /// Each unimplemented operator is in the fixture (so the list cannot go stale) and refuses the
  /// document that uses it when it is opened, not at some later frame.
  @Test func aDocumentUsingAnUnimplementedOperatorIsRefused() throws {
    let fixture = try HostValueParityFixture.load()
    let operators = Set(fixture.operators.map(\.0))
    for (operation, name) in Self.unimplementedOperators.sorted(by: { $0.key < $1.key }) {
      #expect(operators.contains(operation), "\(name) is not in the fixture")
      let document = Writer()
      document.header(width: 100, height: 100)
      document.u8(Op.dataFloat).int(51).float(1.5)
      document.u8(Op.animatedFloat).int(60).int(4)
        .int(Writer.nanReference(51)).int(Writer.nanReference(51)).int(Writer.nanReference(51))
        .int(Writer.floatOperator(operation))
      document.u8(Op.layoutRoot).int(1).u8(Op.containerEnd)
      #expect(throws: NativeSwiftCoreError.self, "\(name)") {
        let session = try NativeSwiftDocumentSession.open(data: document.data)
        _ = try session.snapshot(timeSeconds: 0)
      }
    }
  }

  @Test func textFromFloatFormatsNonFiniteValuesAsAndroidXDoes() throws {
    let fixture = try HostValueParityFixture.load()
    #expect(fixture.texts.count > 100)
    var mismatches: [String] = []
    for row in fixture.texts {
      let actual = NativeSwiftTextFormatter.format(
        row.value, digitsBefore: row.before, digitsAfter: row.after, flags: row.flags)
      if actual != row.text {
        mismatches.append(
          "\(row.value) \(row.before).\(row.after) \(row.flags): "
            + "'\(actual)', AndroidX '\(row.text)'")
      }
    }
    #expect(
      mismatches.isEmpty,
      "\(mismatches.count) mismatches:\n\(mismatches.prefix(40).joined(separator: "\n"))")
  }

  /// `StringUtils.floatToString` rounds the scaled fraction with Java's `Math.round(float)`
  /// (StringUtils.java:91), which is exact: 0.049999997 to one place scales to 0.49999997, which
  /// rounds to 0, where `floor(x + 0.5)` taken in Float reads 1.
  @Test func textFromFloatRoundsTheFractionAsJavaMathRoundDoes() {
    let text = NativeSwiftTextFormatter.format(
      0.049_999_997, digitsBefore: 2, digitsAfter: 1, flags: 0)
    #expect(text == " 0.0", "'\(text)'")
  }

  /// AndroidX's `A_MAX` and `A_MIN` fold a list with `Math.max` and `Math.min`
  /// (AnimatedFloatExpression.java:1009, :1025): a NaN element anywhere makes the result NaN, and
  /// 0 is above -0. The fixture's operands are not lists, so it does not reach these.
  @Test func arrayMaxAndMinFoldAsJavaMathDoes() throws {
    let arrayID = NativeSwiftIDRegion.array | 5
    let cases: [([Float], max: Float, min: Float)] = [
      ([1, .nan, 2], .nan, .nan), ([.nan, 1], .nan, .nan), ([1, 2, .nan], .nan, .nan),
      ([-0.0, 0], 0, -0.0), ([0, -0.0], 0, -0.0),
      ([-.infinity, 3, .infinity], .infinity, -.infinity), ([], 0, 0),
    ]
    for (list, expectedMax, expectedMin) in cases {
      for (operation, expected) in [
        (NativeSwiftFloatOperator.arrayMax, expectedMax),
        (NativeSwiftFloatOperator.arrayMin, expectedMin),
      ] {
        let listReference = Self.nanReferenceBits | UInt32(arrayID)
        let words = [listReference, NativeSwiftFloatExpression.operatorWord(operation)]
        let actual = try NativeSwiftFloatExpression.evaluate(
          words, values: [:], arrays: [arrayID: list], opcode: 0, offset: 0)
        #expect(
          HostValueParityFixture.same(actual, expected),
          "operator \(operation) over \(list): \(actual), AndroidX \(expected)")
      }
    }
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
