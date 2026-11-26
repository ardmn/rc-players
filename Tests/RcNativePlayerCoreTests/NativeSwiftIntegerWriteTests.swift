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
    let d = Writer()
    d.header(width: 100, height: 100)
    d.u8(Op.dataInt).int(90).int(4)
    d.u8(Op.dataInt).int(52).int(4)
    d.namedVariable(id: 52, type: Named.int, name: "count")
    d.u8(Op.dataFloat).int(70).float(7.5)
    d.u8(Op.integerExpression).int(70).int(1).int(1).int(90)
    d.namedVariable(id: 70, type: Named.int, name: "both")
    d.u8(Op.integerExpression).int(71).int(1).int(1).int(90)
    d.namedVariable(id: 71, type: Named.int, name: "computed")
    d.u8(Op.dataFloat).int(80).float(1.25)
    d.namedVariable(id: 80, type: Named.int, name: "mixed")
    d.u8(Op.dataInt).int(62).int(0)
    d.namedVariable(id: 62, type: Named.int, name: "flag")
    for (out, source, factor) in [
      (60, 52, 1.5), (73, 70, 1), (72, 71, 1.5), (81, 80, 1), (63, 62, 10),
    ] {
      d.u8(Op.animatedFloat).int(out).int(3).int(Writer.nanReference(source))
        .int(Writer.literal(Float(factor))).int(mul)
    }
    return d.data
  }

  private func open() throws -> NativeSwiftDocumentSession {
    try NativeSwiftDocumentSession.open(data: Self.document(), toleratingRootlessData: true)
  }

  private func views(_ s: NativeSwiftDocumentSession, _ id: Int) throws -> (Int?, Float?) {
    let v = try s.probeValues(timeSeconds: 0)
    return (v.integers[id], v.floats[id])
  }

  private func reopen(_ s: NativeSwiftDocumentSession) throws -> NativeSwiftDocumentSession {
    let next = try open()
    for (name, value) in s.writtenNamedValues() {
      #expect(next.restoreNamedValue(value, forDeclaredName: name))
    }
    return next
  }

  // 1. A host integer write, no document float, read by a float expression.
  @Test func hostIntegerNoDocumentFloatFeedsAFloatExpression() throws {
    let s = try open()
    #expect(s.setInteger(9, for: "count"))
    for _ in 0..<2 {
      let v = try s.probeValues(timeSeconds: 0)
      #expect(
        v.integers[52] == 9 && v.floats[52] == 9 && v.floats[60] == 13.5, "\(v.floats[60] as Any)")
    }
  }

  // 2. Integer-expression output with a document float. Kotlin: each pass setInteger(4) -> 4/4.0.
  @Test func bothOutputAndDocumentFloatAfterAHostWrite() throws {
    let s = try open()
    #expect(s.setInteger(9, for: "both"))
    let (i, f) = try views(s, 70)
    let f73 = try s.probeValues(timeSeconds: 0).floats[73]
    #expect(i == 4, "integer: Kotlin 4, Swift \(i as Any)")
    #expect(f == 4, "float: Kotlin 4.0, Swift \(f as Any)")
    #expect(f73 == 4, "float expression over it: Kotlin 4.0, Swift \(f73 as Any)")
  }

  @Test func bothOutputAndDocumentFloatWithoutAWrite() throws {
    let (i, f) = try views(try open(), 70)
    #expect(i == 4 && f == 4, "Kotlin 4/4.0, Swift \(i as Any)/\(f as Any)")
  }

  /// The case the commit message reasons about, without a document float: Kotlin 4/4.0.
  @Test func computedOutputWithoutDocumentFloatAfterAHostWrite() throws {
    let s = try open()
    #expect(s.setInteger(9, for: "computed"))
    let v = try s.probeValues(timeSeconds: 0)
    #expect(v.integers[71] == 4 && v.floats[71] == 4 && v.floats[72] == 6, "\(v.floats[71] as Any)")
  }

  /// Extra: a host float write by id onto an integer-expression output. Kotlin: setFloat(2.5),
  /// then the next pass's setInteger(4) rewrites both -> 4/4.0.
  @Test func hostFloatWriteOntoAnIntegerExpressionOutputIsReplaced() throws {
    let s = try open()
    #expect(s.setFloat(2.5, forID: 71))
    let (i, f) = try views(s, 71)
    #expect(i == 4 && f == 4, "Kotlin 4/4.0, Swift \(i as Any)/\(f as Any)")
  }

  // 3. An equal write after a reopen carry.
  @Test func equalIntegerAfterAReopenCarryKeepsTheCarriedFloat() throws {
    let a = try open()
    #expect(a.setFloat(2.5, forID: 52))
    #expect(a.setFloat(5.5, forID: 80))
    let b = try reopen(a)
    #expect(b.setInteger(2, for: "count"))
    #expect(b.setInteger(5, for: "mixed"))
    var v = try b.probeValues(timeSeconds: 0)
    #expect(
      v.integers[52] == 2 && v.floats[52] == 2.5 && v.floats[60] == 3.75, "\(v.floats[52] as Any)")
    #expect(
      v.integers[80] == 5 && v.floats[80] == 5.5 && v.floats[81] == 5.5, "\(v.floats[80] as Any)")
    #expect(b.setInteger(3, for: "count"))
    #expect(b.setInteger(6, for: "mixed"))
    v = try b.probeValues(timeSeconds: 0)
    #expect(v.floats[52] == 3 && v.floats[60] == 4.5 && v.floats[80] == 6 && v.floats[81] == 6)
    // And the carried integer-only write: equal again after a second reopen.
    let c = try reopen(b)
    #expect(c.setInteger(3, for: "count"))
    v = try c.probeValues(timeSeconds: 0)
    #expect(v.integers[52] == 3 && v.floats[52] == 3, "\(v.floats[52] as Any)")
  }

  // 4. Host integer, then host float, then the same integer again.
  @Test(arguments: [(52, "count"), (80, "mixed")])
  func integerFloatSameInteger(id: Int, name: String) throws {
    let s = try open()
    #expect(s.setInteger(3, for: name))
    _ = try s.probeValues(timeSeconds: 0)
    #expect(s.setFloat(3.5, forID: id))
    _ = try s.probeValues(timeSeconds: 0)
    #expect(s.setInteger(3, for: name))
    var (i, f) = try views(s, id)
    #expect(i == 3 && f == 3.5, "\(name): Kotlin 3/3.5, Swift \(i as Any)/\(f as Any)")
    #expect(s.setInteger(6, for: name))
    (i, f) = try views(s, id)
    #expect(i == 6 && f == 6, "\(name): Kotlin 6/6.0, Swift \(i as Any)/\(f as Any)")
  }

  // 5. A boolean written as an integer.
  @Test func booleanAsOneAndZero() throws {
    let s = try open()
    for (value, expected) in [(1, Float(10)), (0, 0), (0, 0), (1, 10)] {
      #expect(s.setInteger(value, for: "flag"))
      let v = try s.probeValues(timeSeconds: 0)
      #expect(v.integers[62] == value && v.floats[62] == Float(value) && v.floats[63] == expected)
    }
    #expect(s.setInteger(0, for: "flag"))
    #expect(s.setFloat(0.5, forID: 62))
    #expect(s.setInteger(0, for: "flag"))  // equal integer: Kotlin keeps 0.5
    var v = try s.probeValues(timeSeconds: 0)
    #expect(
      v.integers[62] == 0 && v.floats[62] == 0.5 && v.floats[63] == 5, "\(v.floats[62] as Any)")
    #expect(s.setInteger(1, for: "flag"))
    v = try s.probeValues(timeSeconds: 0)
    #expect(v.integers[62] == 1 && v.floats[62] == 1 && v.floats[63] == 10)
  }

  // 6a. Writes before the first frame.
  @Test func writesBeforeTheFirstFrame() throws {
    let s = try open()
    #expect(s.setInteger(9, for: "count"))
    #expect(s.setInteger(9, for: "computed"))
    #expect(s.setInteger(9, for: "mixed"))
    #expect(s.setInteger(0, for: "flag"))  // equal to the document's 0
    let v = try s.probeValues(timeSeconds: 0)
    #expect(v.floats[52] == 9 && v.floats[60] == 13.5)
    #expect(v.integers[71] == 4 && v.floats[71] == 4 && v.floats[72] == 6)
    #expect(v.integers[80] == 9 && v.floats[80] == 9 && v.floats[81] == 9)
    #expect(v.integers[62] == 0 && v.floats[62] == 0 && v.floats[63] == 0)
  }

  // 6b. Writes while backgrounded: no frames between them, then the reopen carries them.
  @Test func writesWhileBackgroundedThenReopened() throws {
    let a = try open()
    _ = try a.probeValues(timeSeconds: 0)
    #expect(a.setInteger(9, for: "count"))
    #expect(a.setFloat(9.5, forID: 52))
    #expect(a.setInteger(9, for: "count"))  // equal: Kotlin keeps 9.5
    #expect(a.setInteger(9, for: "computed"))
    #expect(a.setFloat(1.5, forID: 80))
    #expect(a.setInteger(1, for: "mixed"))  // equal: Kotlin keeps 1.5
    let carried = Dictionary(
      uniqueKeysWithValues: a.writtenNamedValues().map { ($0.name, $0.value) })
    #expect(carried["count"] == .integer(9, float: 9.5), "\(carried["count"] as Any)")
    #expect(carried["mixed"] == .integer(1, float: 1.5), "\(carried["mixed"] as Any)")
    let b = try reopen(a)
    let v = try b.probeValues(timeSeconds: 0)
    #expect(v.integers[52] == 9 && v.floats[52] == 9.5 && v.floats[60] == 14.25)
    #expect(v.integers[71] == 4 && v.floats[71] == 4, "\(v.integers[71] as Any)")
    #expect(v.integers[80] == 1 && v.floats[80] == 1.5)
  }

  /// 6c. A write to an integer-expression output with a document float while backgrounded,
  /// carried into the reopen. Kotlin: the next pass's expression gives 4/4.0.
  @Test func bothWrittenWhileBackgroundedThenReopened() throws {
    let a = try open()
    #expect(a.setInteger(9, for: "both"))
    let b = try reopen(a)
    let (i, f) = try views(b, 70)
    #expect(i == 4 && f == 4, "Kotlin 4/4.0, Swift \(i as Any)/\(f as Any)")
  }

  // 7. The per-view seeded first open (#974): `restoreNamedValue(.integer(v))` before frame one.
  @Test func seededFirstOpen() throws {
    let s = try open()
    #expect(s.restoreNamedValue(.integer(9), forDeclaredName: "count"))
    #expect(s.restoreNamedValue(.integer(9), forDeclaredName: "mixed"))
    #expect(s.restoreNamedValue(.integer(1), forDeclaredName: "flag"))
    #expect(s.restoreNamedValue(.integer(9), forDeclaredName: "computed"))
    let v = try s.probeValues(timeSeconds: 0)
    #expect(v.floats[52] == 9 && v.floats[60] == 13.5)
    #expect(v.floats[80] == 9 && v.floats[81] == 9)
    #expect(v.floats[62] == 1 && v.floats[63] == 10)
    #expect(v.integers[71] == 4 && v.floats[71] == 4)
    // A seed equal to the document's integer view keeps the document float (Kotlin: no-op).
    let t = try open()
    #expect(t.restoreNamedValue(.integer(1), forDeclaredName: "mixed"))
    let (i, f) = try views(t, 80)
    #expect(i == 1 && f == 1.25, "Kotlin 1/1.25, Swift \(i as Any)/\(f as Any)")
  }

  @Test func seededFirstOpenOntoBoth() throws {
    let s = try open()
    #expect(s.restoreNamedValue(.integer(9), forDeclaredName: "both"))
    let (i, f) = try views(s, 70)
    #expect(i == 4 && f == 4, "Kotlin 4/4.0, Swift \(i as Any)/\(f as Any)")
  }
}
