import Foundation
import Testing

@testable @_spi(Conformance) import RcNativePlayerCore

/// Replays the Kotlin player's value resolution against the session.
///
/// `RcValueResolutionDifferentialTest` (`:rc-player-runtime` jvmTest) generates documents from
/// seeds — constants, float and integer expressions, colour expressions and attributes, id and
/// data-map lookups, text merges, lengths and conversions over one small pool of ids, with clicks
/// that write the same pool — plays each through `RcPlayerState` with a sequence of frames, host
/// writes and clicks, and records every observed id's views after each step in
/// `Fixtures/value-resolution-differential.json`. This suite plays the same bytes and steps: a
/// frame is one resolution (`probeValues`) at the step's instant with a UTC wall clock, a host write
/// or a click resolves nothing (`currentValues` reads what it left). Every id must match at every
/// step, and there is no allow-list: the generator stays out of the differences that are not about
/// order. It declares every id before anything reads it (Kotlin reads an unset reference as its own
/// NaN bits, this session as 0), writes one float expression per id (Kotlin's input memo skips a
/// second one at an id, ardmn/work#135) and builds no expression deeper than the evaluator's
/// 128-entry stack, which this session keeps from AndroidX by decision.
@Suite struct NativeSwiftValueResolutionDifferentialTests {
  /// The fixture, as the Kotlin test writes it; `format` must be the one this suite reads.
  private struct Fixture: Decodable {
    let format: Int
    let epochMillis: Int64
    let frameTimes: [Double]
    let observedIds: [Int]
    let textIds: [Int]
    let colorIds: [Int]
    let clickComponent: Int
    let namedFloat: String
    let namedInteger: String
    let cases: [Case]
  }

  private struct Case: Decodable {
    let seed: Int64
    let document: String
    /// Each step: its kind's letter, its argument, the id a by-id write targets, and the slots it
    /// changed (every slot on the first step).
    let steps: [Step]
  }

  private struct Step: Decodable {
    let kind: StepKind
    let argument: Int
    let id: Int
    let changes: [Change]

    init(from decoder: Decoder) throws {
      var container = try decoder.unkeyedContainer()
      kind = try container.decode(StepKind.self)
      argument = try container.decode(Int.self)
      id = try container.decode(Int.self)
      changes = try container.decode([Change].self)
    }
  }

  /// One slot's new view: `[slot, value]`, the value `null` for a text that is not there.
  private struct Change: Decodable {
    let slot: Int
    let value: String?

    init(from decoder: Decoder) throws {
      var container = try decoder.unkeyedContainer()
      slot = try container.decode(Int.self)
      value = try container.decode(String?.self)
    }
  }

  /// `RcValueResolutionDifferentialTest.StepKind`'s letters.
  private enum StepKind: String, Decodable {
    case frame = "P"
    case setFloatByID = "F"
    case setNamedFloat = "N"
    case setNamedInteger = "I"
    case click = "K"
  }

  private static let fixtureFormat = 2

  private static func fixture() throws -> Fixture {
    let data = try Data(contentsOf: NativeTestFixtures.url("value-resolution-differential.json"))
    return try JSONDecoder().decode(Fixture.self, from: data)
  }

  @Test func everyGeneratedDocumentResolvesAsTheKotlinPlayerDoes() throws {
    let fixture = try Self.fixture()
    try #require(fixture.format == Self.fixtureFormat)
    #expect(fixture.cases.count >= 100, "\(fixture.cases.count) cases")
    var mismatches: [String] = []
    for testCase in fixture.cases {
      let data = try #require(Data(base64Encoded: testCase.document))
      let session = try NativeSwiftDocumentSession.open(data: data)
      var expected = [String?](repeating: nil, count: Self.labels(fixture).count)
      for (index, step) in testCase.steps.enumerated() {
        for change in step.changes { expected[change.slot] = change.value }
        let observed: NativeSwiftProbeValues
        switch step.kind {
        case .frame:
          let time = fixture.frameTimes[step.argument]
          observed = try session.probeValues(
            timeSeconds: time,
            wallClock: NativeSwiftWallClock(
              epochMillis: fixture.epochMillis + Int64((time * 1000).rounded())))
        case .setFloatByID:
          _ = session.setFloat(Self.float(step.argument), forID: step.id)
          observed = session.currentValues()
        case .setNamedFloat:
          _ = session.setFloat(Self.float(step.argument), for: fixture.namedFloat)
          observed = session.currentValues()
        case .setNamedInteger:
          _ = session.setInteger(step.argument, for: fixture.namedInteger)
          observed = session.currentValues()
        case .click:
          _ = try session.click(componentID: fixture.clickComponent, timeSeconds: 0)
          observed = session.currentValues()
        }
        let swift = Self.views(observed, fixture)
        let differences = zip(Self.labels(fixture), zip(expected, swift)).filter {
          $0.1.0 != $0.1.1
        }
        if !differences.isEmpty {
          let shown = differences.prefix(4).map { label, views in
            "\(label) Kotlin \(views.0 ?? "nil") Swift \(views.1 ?? "nil")"
          }
          mismatches.append(
            "seed \(testCase.seed) step \(index) \(step.kind): \(shown.joined(separator: "; "))")
          break
        }
      }
    }
    #expect(
      mismatches.isEmpty,
      "\(mismatches.count) cases differ:\n\(mismatches.prefix(20).joined(separator: "\n"))")
  }

  /// A float step argument: the value's bits, as the Kotlin test writes them.
  private static func float(_ bits: Int) -> Float {
    Float(bitPattern: UInt32(truncatingIfNeeded: bits))
  }

  /// What each observed slot is, for a mismatch report.
  private static func labels(_ fixture: Fixture) -> [String] {
    fixture.observedIds.map { "#\($0)" } + fixture.textIds.map { "T\($0)" }
      + fixture.colorIds.map { "C\($0)" }
  }

  /// The session's views in the fixture's spelling: `integer/floatBits` per id (`-` for none), each
  /// text, each colour as unsigned hex.
  private static func views(_ values: NativeSwiftProbeValues, _ fixture: Fixture) -> [String?] {
    let numbers: [String?] = fixture.observedIds.map { id in
      let integer = values.integers[id].map(String.init) ?? "-"
      let float = values.floats[id].map { String($0.bitPattern, radix: 16) } ?? "-"
      return "\(integer)/\(float)"
    }
    let texts: [String?] = fixture.textIds.map { values.texts[$0] }
    let colors: [String?] = fixture.colorIds.map { id in
      values.colors[id].map { String($0, radix: 16) } ?? "-"
    }
    return numbers + texts + colors
  }
}
