import Foundation
import Testing

@testable @_spi(Conformance) @_spi(RemoteComposeController) import RcNativePlayerCore

/// Values the Kotlin player's tests use, which the Swift tests that replay them must use too: one
/// constant each here, and `kotlinValuesHaveNotDrifted` fails when the Kotlin source changes one.
enum KotlinReference {
  /// `RcSystemVariableTest.EPOCH_MILLIS`: 2026-08-20T16:30:45.250Z, 30:45 into the hour.
  static let epochMillis: Int64 = 1_787_243_445_250
  /// `RcNamedValueOverrideTest`'s `red` and `blue`.
  static let red: UInt32 = 0xFFFF_0000
  static let blue: UInt32 = 0xFF00_00FF
  /// The finite inputs of `RcPlayerStateTest.floatResultsFeedIntegerExpressions…` and their
  /// integer views (its MIN/MAX cases are the platforms' own constants).
  static let truncatedFloats: [(Float, Int)] = [(1.75, 1), (-2.75, -2)]
}

extension Writer {
  /// An `RcIntegerExpression` operator token, as `floatOperator` is for a float expression's.
  static func integerOperator(_ operation: Int) -> Int {
    NativeSwiftIntegerOperator.offset + operation
  }
}

extension NativeSwiftNodeSnapshot {
  /// This node or the first descendant, depth first, with `componentID`.
  func node(withComponentID componentID: Int) -> NativeSwiftNodeSnapshot? {
    if self.componentID == componentID { return self }
    return children.lazy.compactMap { $0.node(withComponentID: componentID) }.first
  }
}

extension NativeSwiftDocumentSession {
  /// A new session over `data` that starts from every value this one wrote, as a reopen hands
  /// `writtenNamedValues()` to the next session. Session level only: the player's merge with
  /// left-out values and host seeds is covered by `NativeNamedValueCarryTests`.
  func reopened(over data: Data) throws -> NativeSwiftDocumentSession {
    let next = try NativeSwiftDocumentSession.open(data: data, toleratingRootlessData: true)
    for (name, value) in writtenNamedValues() {
      #expect(next.restoreNamedValue(value, forDeclaredName: name), "\(name)")
    }
    return next
  }
}

@Suite struct NativeSwiftKotlinReferenceTests {
  @Test func kotlinValuesHaveNotDrifted() throws {
    let tests = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent(
        "rc-player/runtime/src/commonTest/kotlin/ee/schimke/composeai/rcplayer/runtime")
    let clock = try String(
      contentsOf: tests.appendingPathComponent("RcSystemVariableTest.kt"), encoding: .utf8)
    let marker = "const val EPOCH_MILLIS = "
    let declared = clock.range(of: marker).map { range in
      Int64(clock[range.upperBound...].prefix { $0 != "L" }.filter { $0 != "_" })
    }
    #expect(declared == KotlinReference.epochMillis, "\(declared as Any)")
    let overrides = try String(
      contentsOf: tests.appendingPathComponent("RcNamedValueOverrideTest.kt"), encoding: .utf8)
    let state = try String(
      contentsOf: tests.appendingPathComponent("RcPlayerStateTest.kt"), encoding: .utf8)
    for (value, expected) in KotlinReference.truncatedFloats {
      #expect(state.contains("\(value)f to \(expected),"), "\(value)")
    }
    for (name, value) in [("red", KotlinReference.red), ("blue", KotlinReference.blue)] {
      #expect(
        overrides.contains("val \(name) = 0x\(String(value, radix: 16)).toInt()"), "\(name)")
    }
  }
}
