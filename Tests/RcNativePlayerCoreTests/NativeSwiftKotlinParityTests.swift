import Foundation
import Testing

@testable @_spi(Conformance) @_spi(RemoteComposeController) import RcNativePlayerCore

/// The Kotlin player's named-value tests, replayed against the native Swift session: the same
/// inputs, and the outcome the Kotlin test expects. Each test names the Kotlin test it mirrors.
/// Kotlin's `RcPlayerState` throws for a mistyped write where the session answers `false`; that is
/// a deliberate difference of API shape, and these tests assert the Swift spelling of it.
@Suite struct NativeSwiftKotlinParityTests {
  private typealias Op = NativeSwiftWireOpcode
  private typealias Named = NativeSwiftNamedVariableType

  /// `RcPlayerStateTest.floatResultsFeedIntegerExpressionsWithoutLosingTheirFloatValue`: a float
  /// written to an id is also its integer view, truncated toward zero, so an integer expression
  /// reading that id sees it; the float view keeps the exact value.
  @Test func floatWritesFeedIntegerExpressionsTruncatingTowardZero() throws {
    let document = Writer()
    document.header(width: 100, height: 100)
    document.u8(Op.dataFloat).int(51).float(1.75)
    // Integer 52 = integer view of id 51 (mask bit 0: the single token is an id reference).
    document.u8(Op.integerExpression).int(52).int(1).int(1).int(51)
    let session = try NativeSwiftDocumentSession.open(
      data: document.data, toleratingRootlessData: true)
    // NaN is left out: the Swift session refuses a non-finite write (a documented difference).
    let cases: [(Float, Int)] = [
      (1.75, 1), (-2.75, -2), (.leastNonzeroMagnitude, 0),
      (.greatestFiniteMagnitude, Int(Int32.max)), (-.greatestFiniteMagnitude, Int(Int32.min)),
    ]
    for (value, expected) in cases {
      #expect(session.setFloat(value, forID: 51))
      let values = try session.probeValues(timeSeconds: 0)
      #expect(
        values.integers[52] == expected,
        "integer view of \(value): \(String(describing: values.integers[52]))")
      #expect(values.floats[51]?.bitPattern == value.bitPattern, "float view of \(value)")
    }
  }

  /// `RcPlayerStateTest.namedFloatActionsAndRestorationRefreshTheIntegerView` (the host half; the
  /// restore half needs `clearNamedValue`, which the session does not have): a named float write
  /// moves the integer view an integer expression reads.
  @Test func aNamedFloatWriteRefreshesTheIntegerView() throws {
    let document = Writer()
    document.header(width: 100, height: 100)
    document.u8(Op.dataFloat).int(51).float(1.75)
    document.namedVariable(id: 51, type: Named.float, name: "page")
    document.u8(Op.integerExpression).int(53).int(1).int(1).int(51)
    let session = try NativeSwiftDocumentSession.open(
      data: document.data, toleratingRootlessData: true)
    let initial = try session.probeValues(timeSeconds: 0).integers[53]
    #expect(initial == 1, "integer view of 1.75: \(String(describing: initial))")

    #expect(session.setFloat(-2.75, for: "page"))
    let written = try session.probeValues(timeSeconds: 0).integers[53]
    #expect(written == -2, "integer view of -2.75: \(String(describing: written))")
  }

  /// `RcPlayerStateTest.integerValuesAlsoPopulateTheSharedFloatNamespace`: an integer is also its
  /// float view, and an integer write moves that view — including when a float write reached the
  /// id first (Kotlin's `setInteger` rewrites `floats[id]`).
  @Test func integerWritesAlsoFeedTheSharedFloatNamespace() throws {
    let document = Writer()
    document.header(width: 100, height: 100)
    document.u8(Op.dataInt).int(51).int(1)
    document.namedVariable(id: 51, type: Named.int, name: "USER:count")
    let session = try NativeSwiftDocumentSession.open(
      data: document.data, toleratingRootlessData: true)
    #expect(try session.probeValues(timeSeconds: 0).floats[51] == 1)

    #expect(session.setInteger(7, for: "count"))
    #expect(try session.probeValues(timeSeconds: 0).floats[51] == 7)

    // A float write by id, then an integer write by name: Kotlin's float view follows the integer.
    #expect(session.setFloat(2.5, forID: 51))
    #expect(session.setInteger(9, for: "count"))
    let values = try session.probeValues(timeSeconds: 0)
    #expect(values.integers[51] == 9)
    #expect(
      values.floats[51] == 9,
      "a stale float write shadows the integer's float view: \(String(describing: values.floats[51]))"
    )
  }

  /// `RcSystemVariableTest.aHostOverrideOfANamedSystemVariableHoldsUntilCleared` (the hold half):
  /// a host write to a named system variable replaces the clock's value.
  @Test func aHostOverrideOfANamedSystemVariableHolds() throws {
    let document = Writer()
    document.header(width: 100, height: 100)
    document.namedVariable(
      id: NativeSwiftSystemVariables.year, type: Named.float, name: "cal_year")
    let session = try NativeSwiftDocumentSession.open(
      data: document.data, toleratingRootlessData: true)
    // 2026-01-19T12:00:00Z.
    let clock = NativeSwiftWallClock(epochMillis: 1_768_824_000_000)
    #expect(
      try session.probeValues(timeSeconds: 0, wallClock: clock)
        .floats[NativeSwiftSystemVariables.year] == 2026)

    #expect(session.setFloat(1999, for: "cal_year"))
    #expect(
      try session.probeValues(timeSeconds: 0, wallClock: clock)
        .floats[NativeSwiftSystemVariables.year] == 1999)
  }

  /// `RcNamedValueOverrideTest.aColourOverrideSurvivesTheExpressionThatDefaultsItAndClearingHandsItBack`
  /// (the override half): a named colour whose default is a colour expression's output keeps the
  /// host's value — AndroidX's `RemoteComposeState.updateColor` returns early for an overridden id.
  @Test func aColourOverrideSurvivesTheExpressionThatDefaultsIt() throws {
    let red: UInt32 = 0xFFFF_0000
    let blue: UInt32 = 0xFF00_00FF
    let document = Writer()
    document.header(width: 100, height: 100)
    document.u8(Op.colorConstant).int(60).int(Int(Int32(bitPattern: red)))
    document.u8(Op.colorExpressions).int(61).int(NativeSwiftColorExpressionMode.idIDInterpolate)
      .int(60).int(60).float(0)
    document.namedVariable(id: 61, type: Named.color, name: "USER:accent")
    let session = try NativeSwiftDocumentSession.open(
      data: document.data, toleratingRootlessData: true)
    #expect(try session.probeValues(timeSeconds: 0).colors[61] == red)

    #expect(session.setColor(blue, for: "accent"))
    let colors = try session.probeValues(timeSeconds: 0).colors
    #expect(
      colors[61] == blue,
      "the colour expression replaced the host's colour: \(String(describing: colors[61]))")
  }

  /// `RcNamedValueOverrideTest.anUnqualifiedNameResolvesIntoTheUserNamespaceFirst` and
  /// `anUndeclaredUserNameFallsBackToThePlainOneAndAColonIsUsedAsIs`, plus
  /// `RcPlayerStateTest.appliesTypedHostOverridesByAndroidXVariableName` (a variable declared with
  /// no recorded value still takes an override; another type is refused).
  @Test func hostNamesResolveAsTheKotlinRuntimeResolvesThem() throws {
    let document = Writer()
    document.header(width: 100, height: 100)
    document.u8(Op.dataInt).int(50).int(0)
    document.namedVariable(id: 50, type: Named.int, name: "USER:enabled")
    document.u8(Op.dataFloat).int(52).float(3)
    document.namedVariable(id: 52, type: Named.float, name: "plain")
    document.u8(Op.dataFloat).int(53).float(4)
    document.namedVariable(id: 53, type: Named.float, name: "OTHER:plain")
    document.namedVariable(id: 9, type: Named.float, name: "USER:temperature")
    let session = try NativeSwiftDocumentSession.open(
      data: document.data, toleratingRootlessData: true)

    #expect(session.setInteger(1, for: "enabled"))
    #expect(session.setFloat(8, for: "plain"))
    #expect(session.setFloat(9, for: "OTHER:plain"))
    #expect(!session.setFloat(10, for: "USER:plain"), "USER:plain is not declared")
    #expect(session.setFloat(21.5, for: "USER:temperature"))
    #expect(!session.setString("wrong type", for: "USER:temperature"))

    let values = try session.probeValues(timeSeconds: 0)
    #expect(values.integers[50] == 1)
    #expect(values.floats[52] == 8)
    #expect(values.floats[53] == 9)
    #expect(values.floats[9] == 21.5)
  }

  /// `RcNamedValueLifecycleTest.aDocumentDeclaringATypeWithNoHostValueStillConstructs`: a document
  /// declaring an image and a float-array variable opens, the representable variable beside them
  /// is driven as usual, and no scalar write reaches the other two.
  @Test func aDocumentDeclaringATypeWithNoHostValueStillOpens() throws {
    let document = Writer()
    document.header(width: 100, height: 100)
    document.u8(Op.dataFloat).int(9).float(21.5)
    document.namedVariable(id: 9, type: Named.float, name: "USER:temperature")
    document.namedVariable(id: 12, type: Named.image, name: "USER:avatar")
    document.namedVariable(id: 13, type: Named.floatArray, name: "USER:series")
    let session = try NativeSwiftDocumentSession.open(
      data: document.data, toleratingRootlessData: true)

    #expect(session.setFloat(-4, for: "USER:temperature"))
    #expect(try session.probeValues(timeSeconds: 0).floats[9] == -4)
    for name in ["USER:avatar", "USER:series", "avatar", "series"] {
      #expect(!session.setFloat(1, for: name), "\(name)")
      #expect(!session.setInteger(1, for: name), "\(name)")
      #expect(!session.setString("x", for: name), "\(name)")
      #expect(!session.setColor(0, for: name), "\(name)")
    }
  }

  /// `RcHostValueTypeTest.eachValueFitsExactlyItsOwnWireType`, for the four value kinds the Swift
  /// API has: each fits its own wire type and no other — a boolean is an integer, so it fits the
  /// integer type and not the long one.
  @Test func eachValueFitsExactlyItsOwnWireType() {
    let values: [(NativeSwiftNamedValue, Int)] = [
      (.text("a"), Named.string),
      (.float(1), Named.float),
      (.color(0), Named.color),
      (.integer(1), Named.int),
    ]
    let wireTypes = [
      Named.string, Named.float, Named.color, Named.image, Named.int, Named.long, Named.floatArray,
    ]
    for (value, wireType) in values {
      for other in wireTypes {
        let variable = ParsedNamedVariable(id: 1, type: other)
        #expect(
          NativeSwiftNamedVariableDeclarations.accepts(value, by: variable) == (other == wireType),
          "\(value) in \(other)")
      }
    }
  }

  /// `RcNamedValueRenderTest.changingANamedValueMidAnimationLeavesTheTimelineRunning`, at the
  /// session: a host write to an unrelated name keeps the value a document action set.
  @Test func aHostWriteKeepsTheValueADocumentActionSet() throws {
    let document = Writer()
    document.header(width: 100, height: 100)
    document.u8(Op.dataFloat).int(20).float(20)
    document.u8(Op.dataFloat).int(21).float(1)
    document.namedVariable(id: 21, type: Named.float, name: "USER:tint")
    document.u8(Op.layoutRoot).int(1)
    document.u8(Op.layoutBox).int(3).int(-1).int(1).int(4)
    document.u8(Op.modifierClick)
      .u8(Op.valueFloatChangeAction).int(20).float(40)
      .u8(Op.containerEnd).u8(Op.containerEnd).u8(Op.containerEnd)
    let session = try NativeSwiftDocumentSession.open(data: document.data)
    _ = try session.click(componentID: 3, timeSeconds: 0)
    #expect(try session.probeValues(timeSeconds: 0).floats[20] == 40)

    #expect(session.setFloat(7, for: "USER:tint"))
    let values = try session.probeValues(timeSeconds: 0.15)
    #expect(values.floats[20] == 40, "the host write reset what the document's action set")
    #expect(values.floats[21] == 7)
  }
}
