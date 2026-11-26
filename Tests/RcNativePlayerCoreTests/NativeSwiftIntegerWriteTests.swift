import Foundation
import Testing

@testable @_spi(Conformance) @_spi(RemoteComposeController) import RcNativePlayerCore

/// Integer writes against Kotlin `RcPlayerState.setInteger`
/// (`if (integers[id] == value) return; integers[id] = value; floats[id] = value.toFloat()`),
/// `applyIntegerExpression` (re-runs every pass, skipped only for an action-overridden id) and
/// `storeFloat` (both views). Every expectation is Kotlin's value.
@Suite struct NativeSwiftIntegerWriteTests {
  private typealias Op = NativeSwiftWireOpcode
  private typealias Named = NativeSwiftNamedVariableType
  private static let mul = Writer.floatOperator(NativeSwiftFloatOperator.mul)

  /// 90 int 4 (unnamed base). 52 int "count" 4, no document float; 60 = [52] * 1.5.
  /// 70 float 7.5 AND integer expression [90] (=4), int "both"; 73 = [70] * 1.
  /// 71 integer expression [90] (=4), int "computed", no document float; 72 = [71] * 1.5.
  /// 80 float 1.25, int "mixed"; 81 = [80] * 1. 62 int "flag" 0; 63 = [62] * 10.
  static func document() -> Data {
    let document = Writer()
    document.header(width: 100, height: 100)
    document.u8(Op.dataInt).int(90).int(4)
    document.u8(Op.dataInt).int(52).int(4)
    document.namedVariable(id: 52, type: Named.int, name: "count")
    document.u8(Op.dataFloat).int(70).float(7.5)
    document.u8(Op.integerExpression).int(70).int(1).int(1).int(90)
    document.namedVariable(id: 70, type: Named.int, name: "both")
    document.u8(Op.integerExpression).int(71).int(1).int(1).int(90)
    document.namedVariable(id: 71, type: Named.int, name: "computed")
    document.u8(Op.dataFloat).int(80).float(1.25)
    document.namedVariable(id: 80, type: Named.int, name: "mixed")
    document.u8(Op.dataInt).int(62).int(0)
    document.namedVariable(id: 62, type: Named.int, name: "flag")
    for (out, source, factor) in [
      (60, 52, 1.5), (73, 70, 1), (72, 71, 1.5), (81, 80, 1), (63, 62, 10),
    ] {
      document.u8(Op.animatedFloat).int(out).int(3).int(Writer.nanReference(source))
        .int(Writer.literal(Float(factor))).int(mul)
    }
    return document.data
  }

  private func open() throws -> NativeSwiftDocumentSession {
    try NativeSwiftDocumentSession.open(data: Self.document(), toleratingRootlessData: true)
  }

  /// The integer and float view of `id` as a frame resolves them.
  private func views(_ session: NativeSwiftDocumentSession, _ id: Int) throws -> (Int?, Float?) {
    let values = try session.probeValues(timeSeconds: 0)
    return (values.integers[id], values.floats[id])
  }

  // 1. A host integer write, no document float, read by a float expression.
  @Test func hostIntegerNoDocumentFloatFeedsAFloatExpression() throws {
    let session = try open()
    #expect(session.setInteger(9, for: "count"))
    for _ in 0..<2 {
      let values = try session.probeValues(timeSeconds: 0)
      #expect(
        values.integers[52] == 9 && values.floats[52] == 9 && values.floats[60] == 13.5,
        "\(values.floats[60] as Any)")
    }
  }

  // 2. Integer-expression output with a document float. Kotlin: each pass setInteger(4) -> 4/4.0.
  @Test func bothOutputAndDocumentFloatAfterAHostWrite() throws {
    let session = try open()
    #expect(session.setInteger(9, for: "both"))
    let (integer, float) = try views(session, 70)
    let floatExpressionOverIt = try session.probeValues(timeSeconds: 0).floats[73]
    #expect(integer == 4, "integer: Kotlin 4, Swift \(integer as Any)")
    #expect(float == 4, "float: Kotlin 4.0, Swift \(float as Any)")
    #expect(
      floatExpressionOverIt == 4,
      "float expression over it: Kotlin 4.0, Swift \(floatExpressionOverIt as Any)")
  }

  @Test func bothOutputAndDocumentFloatWithoutAWrite() throws {
    let (integer, float) = try views(try open(), 70)
    #expect(integer == 4 && float == 4, "Kotlin 4/4.0, Swift \(integer as Any)/\(float as Any)")
  }

  /// The case the commit message reasons about, without a document float: Kotlin 4/4.0.
  @Test func computedOutputWithoutDocumentFloatAfterAHostWrite() throws {
    let session = try open()
    #expect(session.setInteger(9, for: "computed"))
    let values = try session.probeValues(timeSeconds: 0)
    #expect(
      values.integers[71] == 4 && values.floats[71] == 4 && values.floats[72] == 6,
      "\(values.floats[71] as Any)")
  }

  /// Extra: a host float write by id onto an integer-expression output. Kotlin: setFloat(2.5),
  /// then the next pass's setInteger(4) rewrites both -> 4/4.0.
  @Test func hostFloatWriteOntoAnIntegerExpressionOutputIsReplaced() throws {
    let session = try open()
    #expect(session.setFloat(2.5, forID: 71))
    let (integer, float) = try views(session, 71)
    #expect(integer == 4 && float == 4, "Kotlin 4/4.0, Swift \(integer as Any)/\(float as Any)")
  }

  // 3. An equal write after a reopen carry.
  @Test func equalIntegerAfterAReopenCarryKeepsTheCarriedFloat() throws {
    let first = try open()
    #expect(first.setFloat(2.5, forID: 52))
    #expect(first.setFloat(5.5, forID: 80))
    let second = try first.reopened(over: Self.document())
    #expect(second.setInteger(2, for: "count"))
    #expect(second.setInteger(5, for: "mixed"))
    var values = try second.probeValues(timeSeconds: 0)
    #expect(
      values.integers[52] == 2 && values.floats[52] == 2.5 && values.floats[60] == 3.75,
      "\(values.floats[52] as Any)")
    #expect(
      values.integers[80] == 5 && values.floats[80] == 5.5 && values.floats[81] == 5.5,
      "\(values.floats[80] as Any)")
    #expect(second.setInteger(3, for: "count"))
    #expect(second.setInteger(6, for: "mixed"))
    values = try second.probeValues(timeSeconds: 0)
    #expect(
      values.floats[52] == 3 && values.floats[60] == 4.5 && values.floats[80] == 6
        && values.floats[81] == 6)
    // And the carried integer-only write: equal again after a second reopen.
    let third = try second.reopened(over: Self.document())
    #expect(third.setInteger(3, for: "count"))
    values = try third.probeValues(timeSeconds: 0)
    #expect(values.integers[52] == 3 && values.floats[52] == 3, "\(values.floats[52] as Any)")
  }

  // 4. Host integer, then host float, then the same integer again.
  @Test(arguments: [(52, "count"), (80, "mixed")])
  func integerFloatSameInteger(id: Int, name: String) throws {
    let session = try open()
    #expect(session.setInteger(3, for: name))
    _ = try session.probeValues(timeSeconds: 0)
    #expect(session.setFloat(3.5, forID: id))
    _ = try session.probeValues(timeSeconds: 0)
    #expect(session.setInteger(3, for: name))
    var (integer, float) = try views(session, id)
    #expect(
      integer == 3 && float == 3.5, "\(name): Kotlin 3/3.5, Swift \(integer as Any)/\(float as Any)"
    )
    #expect(session.setInteger(6, for: name))
    (integer, float) = try views(session, id)
    #expect(
      integer == 6 && float == 6, "\(name): Kotlin 6/6.0, Swift \(integer as Any)/\(float as Any)")
  }

  // 5. A boolean written as an integer.
  @Test func booleanAsOneAndZero() throws {
    let session = try open()
    for (value, expected) in [(1, Float(10)), (0, 0), (0, 0), (1, 10)] {
      #expect(session.setInteger(value, for: "flag"))
      let values = try session.probeValues(timeSeconds: 0)
      #expect(
        values.integers[62] == value && values.floats[62] == Float(value)
          && values.floats[63] == expected)
    }
    #expect(session.setInteger(0, for: "flag"))
    #expect(session.setFloat(0.5, forID: 62))
    #expect(session.setInteger(0, for: "flag"))  // equal integer: Kotlin keeps 0.5
    var values = try session.probeValues(timeSeconds: 0)
    #expect(
      values.integers[62] == 0 && values.floats[62] == 0.5 && values.floats[63] == 5,
      "\(values.floats[62] as Any)")
    #expect(session.setInteger(1, for: "flag"))
    values = try session.probeValues(timeSeconds: 0)
    #expect(values.integers[62] == 1 && values.floats[62] == 1 && values.floats[63] == 10)
  }

  // 6a. Writes before the first frame.
  @Test func writesBeforeTheFirstFrame() throws {
    let session = try open()
    #expect(session.setInteger(9, for: "count"))
    #expect(session.setInteger(9, for: "computed"))
    #expect(session.setInteger(9, for: "mixed"))
    #expect(session.setInteger(0, for: "flag"))  // equal to the document'session 0
    let values = try session.probeValues(timeSeconds: 0)
    #expect(values.floats[52] == 9 && values.floats[60] == 13.5)
    #expect(values.integers[71] == 4 && values.floats[71] == 4 && values.floats[72] == 6)
    #expect(values.integers[80] == 9 && values.floats[80] == 9 && values.floats[81] == 9)
    #expect(values.integers[62] == 0 && values.floats[62] == 0 && values.floats[63] == 0)
  }

  // 6b. Writes while backgrounded: no frames between them, then the reopen carries them.
  @Test func writesWhileBackgroundedThenReopened() throws {
    let first = try open()
    _ = try first.probeValues(timeSeconds: 0)
    #expect(first.setInteger(9, for: "count"))
    #expect(first.setFloat(9.5, forID: 52))
    #expect(first.setInteger(9, for: "count"))  // equal: Kotlin keeps 9.5
    #expect(first.setInteger(9, for: "computed"))
    #expect(first.setFloat(1.5, forID: 80))
    #expect(first.setInteger(1, for: "mixed"))  // equal: Kotlin keeps 1.5
    let carried = Dictionary(
      uniqueKeysWithValues: first.writtenNamedValues().map { ($0.name, $0.value) })
    #expect(carried["count"] == .integer(9, float: 9.5), "\(carried["count"] as Any)")
    #expect(carried["mixed"] == .integer(1, float: 1.5), "\(carried["mixed"] as Any)")
    let second = try first.reopened(over: Self.document())
    let values = try second.probeValues(timeSeconds: 0)
    #expect(values.integers[52] == 9 && values.floats[52] == 9.5 && values.floats[60] == 14.25)
    #expect(values.integers[71] == 4 && values.floats[71] == 4, "\(values.integers[71] as Any)")
    #expect(values.integers[80] == 1 && values.floats[80] == 1.5)
  }

  /// 6c. A write to an integer-expression output with a document float while backgrounded,
  /// carried into the reopen. Kotlin: the next pass's expression gives 4/4.0.
  @Test func bothWrittenWhileBackgroundedThenReopened() throws {
    let first = try open()
    #expect(first.setInteger(9, for: "both"))
    let second = try first.reopened(over: Self.document())
    let (integer, float) = try views(second, 70)
    #expect(integer == 4 && float == 4, "Kotlin 4/4.0, Swift \(integer as Any)/\(float as Any)")
  }

  // 7. The per-view seeded first open (#974): `restoreNamedValue(.integer(v))` before frame one.
  @Test func seededFirstOpen() throws {
    let session = try open()
    #expect(session.restoreNamedValue(.integer(9), forDeclaredName: "count"))
    #expect(session.restoreNamedValue(.integer(9), forDeclaredName: "mixed"))
    #expect(session.restoreNamedValue(.integer(1), forDeclaredName: "flag"))
    #expect(session.restoreNamedValue(.integer(9), forDeclaredName: "computed"))
    let values = try session.probeValues(timeSeconds: 0)
    #expect(values.floats[52] == 9 && values.floats[60] == 13.5)
    #expect(values.floats[80] == 9 && values.floats[81] == 9)
    #expect(values.floats[62] == 1 && values.floats[63] == 10)
    #expect(values.integers[71] == 4 && values.floats[71] == 4)
    // A seed equal to the document's integer view keeps the document float (Kotlin: no-op).
    let fresh = try open()
    #expect(fresh.restoreNamedValue(.integer(1), forDeclaredName: "mixed"))
    let (integer, float) = try views(fresh, 80)
    #expect(integer == 1 && float == 1.25, "Kotlin 1/1.25, Swift \(integer as Any)/\(float as Any)")
  }

  @Test func seededFirstOpenOntoBoth() throws {
    let session = try open()
    #expect(session.restoreNamedValue(.integer(9), forDeclaredName: "both"))
    let (integer, float) = try views(session, 70)
    #expect(integer == 4 && float == 4, "Kotlin 4/4.0, Swift \(integer as Any)/\(float as Any)")
  }
}
