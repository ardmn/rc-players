import Foundation
import Testing

@testable import RcComposePlayerSwiftUI
@_spi(Conformance) @_spi(RemoteComposeController) @testable import RcNativePlayerCore

/// The native fallback against the Kotlin player, on the same named-value inputs.
///
/// `Tests/RcNativePlayerCoreTests/Fixtures/named-value-differential.json` is written by the Kotlin
/// player (`RcNamedValueDifferentialTest` in `:rc-player-compose`'s JVM tests, which says how to
/// regenerate it): a document's bytes, what each of its clickable components writes, and directed
/// and seeded sequences of host writes, clicks, frames and reopens, each step with the Kotlin
/// player's answer and the variables it changed.
///
/// Each sequence is replayed here through the real controller (`RemoteComposePlayerController` and
/// its `NativeControllerBackend`: the declarations' check, and no change for a write equal to the
/// last one) and a real `NativeSwiftDocumentSession`, which takes each accepted write under the
/// declared name, as the native player hands it on. A reopen opens a new session over the same
/// document and restores the old one's `writtenNamedValues()` first, as the native player does.
///
/// Every step is compared, answer and variables. A variable that differs is a divergence at the
/// step where it stopped agreeing; while it still differs later steps carry that divergence on and
/// are not counted again (so a second fault on the same variable shows only once the two agree
/// again), and every other variable is still compared. A divergence fails the test with the seed,
/// the step, the steps up to it and both results, unless `named-value-differential-allowlist.json`
/// names a rule (`DifferentialRule`) that explains every difference at that step — its kind of
/// step, the variable it targets, the Kotlin value and the Swift value. An entry no divergence needs
/// fails too, so the list cannot go stale.
///
/// The values both languages spell — the fixture's format and field names, the step letters, the
/// click kinds and the string limit — are checked as the fixture loads: one this suite does not
/// know, a kind of step or click the fixture never uses, or an index out of range fails it.
@MainActor
@Suite struct NativeControllerDifferentialTests {
  @Test func theNativeFallbackMatchesTheKotlinPlayer() throws {
    let fixture = try DifferentialFixture.load()
    let allowList = try DifferentialAllowList.load()
    var failures: [String] = []
    var allowedCounts: [DifferentialRule: Int] = [:]
    var steps = 0
    for sequence in fixture.sequences {
      steps += sequence.steps.count
      for divergence in try Self.replay(sequence, fixture: fixture) {
        if let rule = divergence.rule, allowList.reasonsByRule[rule] != nil {
          allowedCounts[rule, default: 0] += 1
        } else {
          failures.append(divergence.report)
        }
      }
    }
    // Sorted by rule id, so the summary and the unused list read the same on every run.
    let summary = allowedCounts.sorted { $0.key.rawValue < $1.key.rawValue }.map {
      "\($0.key.rawValue) ×\($0.value)"
    }
    print(
      "named-value differential: \(fixture.sequences.count) sequences, \(steps) steps,",
      "\(failures.count) divergences, allow-listed: \(summary)")
    let unused = allowList.reasonsByRule.keys.filter { allowedCounts[$0] == nil }.map(\.rawValue)
      .sorted()
    #expect(
      unused.isEmpty,
      "allow-list entries no divergence needs any more: \(unused.joined(separator: ", "))")
    // Ten reports are enough to act on; `RC_NAMED_VALUE_DIFFERENTIAL_ALL=1` prints every one.
    let reported =
      ProcessInfo.processInfo.environment["RC_NAMED_VALUE_DIFFERENTIAL_ALL"] == "1" ? Int.max : 10
    #expect(
      failures.isEmpty,
      """
      \(failures.count) divergences from the Kotlin player no allow-list rule explains \
      (allow-listed: \(summary)):

      \(failures.prefix(reported).joined(separator: "\n\n"))
      """)
  }

  private struct Divergence {
    let report: String
    let rule: DifferentialRule?
  }

  /// Replays `sequence` and returns one divergence for each step where the native fallback answers
  /// differently or a variable newly differs.
  private static func replay(_ sequence: DifferentialSequence, fixture: DifferentialFixture) throws
    -> [Divergence]
  {
    let player = try NativeDifferentialPlayer(fixture: fixture)
    var kotlinValues = fixture.initial
    var swiftValues = try player.observe()
    var divergences: [Divergence] = []
    if swiftValues != kotlinValues {
      divergences.append(
        Divergence(
          report: "seed \(sequence.seed): the opened document already differs\n"
            + describe(
              fixture.variables.indices.filter { kotlinValues[$0] != swiftValues[$0] },
              kotlinValues: kotlinValues, swiftValues: swiftValues, fixture: fixture),
          rule: nil))
    }
    // The variables whose last host write the Kotlin controller stored and the native one refused,
    // so the two controllers hold different last values for them.
    var heldDifferently: Set<Int> = []
    for (index, step) in sequence.steps.enumerated() {
      let before = DifferentialState(kotlin: kotlinValues, swift: swiftValues)
      let target = player.target(of: step.op)
      let accepted = try player.apply(step.op)
      defer {
        if let target, let accepted {
          if step.accepted == true, !accepted {
            heldDifferently.insert(target)
          } else if accepted {
            heldDifferently.remove(target)
          }
        }
      }
      for change in step.changes { kotlinValues[change.variable] = change.value }
      swiftValues = try player.observe()
      // A variable that already differed only carries the earlier divergence on: what a step
      // makes of a differing value (an action that adds one to it) is not a new one.
      let newlyDiffering = fixture.variables.indices.filter {
        kotlinValues[$0] != swiftValues[$0] && before.kotlin[$0] == before.swift[$0]
      }
      if accepted == step.accepted, newlyDiffering.isEmpty { continue }
      let stepsSoFar = sequence.steps[...index].enumerated().map {
        "  \($0.offset): \($0.element.op)"
      }
      let report = """
        seed \(sequence.seed), step \(index) of \(sequence.steps.count): \(step.op)
        steps up to it:
        \(stepsSoFar.joined(separator: "\n"))
        answer: Kotlin \(step.accepted.map(String.init) ?? "-"), Swift \
        \(accepted.map(String.init) ?? "-")
        """
        + "\n"
        + describe(
          newlyDiffering, kotlinValues: kotlinValues, swiftValues: swiftValues, fixture: fixture)
      let context = DifferentialStepContext(
        step: step, swiftAccepted: accepted, target: target, newlyDiffering: newlyDiffering,
        before: before, after: DifferentialState(kotlin: kotlinValues, swift: swiftValues),
        targetHeldDifferently: target.map(heldDifferently.contains) ?? false, fixture: fixture)
      let rule = DifferentialRule.allCases.first { $0.explains(context) }
      divergences.append(Divergence(report: report, rule: rule))
    }
    return divergences
  }

  private static func describe(
    _ variables: [Int], kotlinValues: [String], swiftValues: [String],
    fixture: DifferentialFixture
  ) -> String {
    variables.map {
      "  \(fixture.variables[$0].name): Kotlin \(kotlinValues[$0]), Swift \(swiftValues[$0])"
    }.joined(separator: "\n")
  }
}

/// Both players' observed variables at one instant, in the fixture's order.
private struct DifferentialState {
  let kotlin: [String]
  let swift: [String]
}

/// One divergent step, as a rule judges it.
private struct DifferentialStepContext {
  let step: DifferentialStep
  /// The native controller's answer; nil for a step that is not a host write.
  let swiftAccepted: Bool?
  /// The variable the step writes, by index; nil when it writes none or several.
  let target: Int?
  let newlyDiffering: [Int]
  let before: DifferentialState
  let after: DifferentialState
  /// Whether the target's last host write was stored by the Kotlin controller and refused here.
  let targetHeldDifferently: Bool
  let fixture: DifferentialFixture
}

/// A class of divergence the allow-list may name. Each explains a step only when every difference
/// at it fits: the kind of step, the one variable that step targets, the value the Kotlin player
/// shows and the value the native fallback shows.
private enum DifferentialRule: String, CaseIterable {
  /// A non-finite float: the native controller refuses it, the Kotlin one stores it.
  case nonFiniteFloat = "native-refuses-non-finite-float"
  /// A string past the document string limit: refused natively, stored by Kotlin.
  case overLongString = "native-refuses-over-long-string"
  /// A write equal to the native controller's last accepted value, after a write it refused and
  /// the Kotlin controller stored: no change natively, a change from the refused value on Kotlin.
  case equalWriteAfterRefusal = "native-skips-an-equal-write-after-a-refused-one"

  func explains(_ context: DifferentialStepContext) -> Bool {
    // At most the targeted variable differs, and it is the one the rule speaks about.
    guard let target = context.target, context.newlyDiffering.allSatisfy({ $0 == target }) else {
      return false
    }
    let step = context.step
    let kotlin = context.after.kotlin[target]
    let swiftUnchanged = context.after.swift[target] == context.before.swift[target]
    switch self {
    case .nonFiniteFloat:
      guard case .setFloat(_, let value) = step.op, !value.isFinite,
        step.accepted == true, context.swiftAccepted == false
      else { return false }
      return context.newlyDiffering.isEmpty
        || (kotlin == FloatSpelling.of(value) && swiftUnchanged)
    case .overLongString:
      guard case .setString(_, let index) = step.op,
        context.fixture.strings[index].utf8.count
          > NativeSwiftDocumentDecoder.maximumStringBytes,
        step.accepted == true, context.swiftAccepted == false
      else { return false }
      return context.newlyDiffering.isEmpty || (kotlin == "#\(index)" && swiftUnchanged)
    case .equalWriteAfterRefusal:
      guard context.targetHeldDifferently, step.accepted == true, context.swiftAccepted == true,
        !context.newlyDiffering.isEmpty, swiftUnchanged
      else { return false }
      switch step.op {
      case .setFloat(_, let value): return kotlin == FloatSpelling.of(value)
      case .setString(_, let index): return kotlin == "#\(index)"
      default: return false
      }
    }
  }
}

/// How both tests spell a float: its bits in hex, `nan` for any NaN, `-` for none.
private enum FloatSpelling {
  static func of(_ value: Float?) -> String {
    guard let value else { return "-" }
    return value.isNaN ? "nan" : String(value.bitPattern, radix: 16)
  }
}

/// The controller and the native core behind it, driven as the native fallback drives them.
@MainActor
private final class NativeDifferentialPlayer {
  private let prepared: NativeSwiftPreparedDocument
  private let fixture: DifferentialFixture
  private let controller = RemoteComposePlayerController()
  private var session: NativeSwiftDocumentSession

  init(fixture: DifferentialFixture) throws {
    prepared = try NativeSwiftPreparedDocument.decode(data: fixture.document)
    self.fixture = fixture
    session = NativeSwiftDocumentSession.open(prepared: prepared)
    controller.backend.attach(session.namedVariableDeclarations)
    // `unowned`: this player owns the controller, so the handler never outlives it.
    controller.backend.installUpdateHandler { [unowned self] name, value in
      self.deliver(value, for: name)
    }
  }

  /// What the native player hands its session for a write or a clear (nil) the controller
  /// accepted (`NativePlayerEngine.apply`).
  private func deliver(_ value: ControllerNamedValue?, for name: String) {
    guard let value else {
      session.clearNamedValue(name)
      return
    }
    switch value.nativeValue {
    case .float(let value): _ = session.setFloat(value, for: name)
    case .text(let value): _ = session.setString(value, for: name)
    case .color(let argb): _ = session.setColor(argb, for: name)
    case .integer(let value): _ = session.setInteger(value, for: name)
    case .long(let value): _ = session.setLong(value, for: name)
    case .floatArray(let values): _ = session.setFloatArray(values, for: name)
    }
  }

  /// The answer a host write gets; nil for a step that is not one.
  func apply(_ op: DifferentialOp) throws -> Bool? {
    switch op {
    case .setFloat(let name, let value): return controller.setFloat(value, for: name)
    case .setInteger(let name, let value): return controller.setInteger(Int(value), for: name)
    case .setBoolean(let name, let value): return controller.setBoolean(value, for: name)
    case .setString(let name, let index):
      return controller.setString(fixture.strings[index], for: name)
    case .setColor(let name, let argb): return controller.setColor(argb, for: name)
    case .click(let component):
      // nil is a click the core did not dispatch: the step would compare nothing.
      guard try session.click(componentID: component, timeSeconds: 0) != nil else {
        throw DifferentialFixture.Malformed(reason: "click(\(component)) was not dispatched")
      }
      return nil
    case .reopen:
      let carried = session.writtenNamedValues()
      session = NativeSwiftDocumentSession.open(prepared: prepared)
      for (name, value) in carried { session.restoreNamedValue(value, forDeclaredName: name) }
      return nil
    case .frame:
      _ = try session.snapshot(timeSeconds: 0)
      return nil
    }
  }

  /// The variable a step writes, by index; nil for a reopen, a frame or an undeclared name.
  func target(of op: DifferentialOp) -> Int? {
    let name: String
    switch op {
    case .setFloat(let host, _), .setInteger(let host, _), .setBoolean(let host, _),
      .setString(let host, _), .setColor(let host, _):
      name = host
    case .click(let component):
      let targets = Set(fixture.clicks[component]?.compactMap(\.target) ?? [])
      return targets.count == 1 ? targets.first : nil
    case .reopen, .frame:
      return nil
    }
    guard let declared = session.namedVariableDeclarations.declaredName(for: name) else {
      return nil
    }
    return fixture.variables.firstIndex { $0.name == declared }
  }

  /// Every variable, spelled as the Kotlin test spells it.
  func observe() throws -> [String] {
    let probe = try session.probeValues(timeSeconds: 0)
    return fixture.variables.map { variable in
      let id = variable.id
      switch variable.type {
      case .integer:
        return "\(probe.integers[id].map(String.init) ?? "-")/\(FloatSpelling.of(probe.floats[id]))"
      case .float:
        return FloatSpelling.of(probe.floats[id])
      case .string:
        guard let text = probe.texts[id] else { return "-" }
        // By UTF-8 bytes, as Kotlin's `indexOf` compares: Swift's `==` would equate a decomposed
        // string with its composed form.
        return fixture.strings.firstIndex { $0.utf8.elementsEqual(text.utf8) }.map { "#\($0)" }
          ?? "?\(text)"
      case .color:
        return String(probe.colors[id] ?? 0, radix: 16)
      }
    }
  }
}

/// A kind of step, by the letter the fixture spells it with (the Kotlin test's `StepKind`).
private enum DifferentialStepKind: String, CaseIterable, Decodable {
  case setFloat = "F"
  case setInteger = "I"
  case setBoolean = "B"
  case setString = "S"
  case setColor = "C"
  case click = "K"
  case reopen = "R"
  case frame = "P"
}

/// What a click action writes, as the fixture spells it (the Kotlin test's `ClickKind`).
private enum DifferentialClickKind: String, CaseIterable, Decodable {
  case integer = "int"
  case integerExpression = "intExpression"
  case float
  case floatExpression
  case text
}

/// The variable types the fixture declares and `NativeDifferentialPlayer.observe()` spells.
private enum DifferentialVariableType {
  case integer, float, string, color

  init(wireType: Int) throws {
    switch wireType {
    case NativeSwiftNamedVariableType.int: self = .integer
    case NativeSwiftNamedVariableType.float: self = .float
    case NativeSwiftNamedVariableType.string: self = .string
    case NativeSwiftNamedVariableType.color: self = .color
    default: throw DifferentialFixture.Malformed(reason: "no observation for type \(wireType)")
    }
  }
}

/// Throws unless every element of a positional row was read.
private func expectEnd(of row: UnkeyedDecodingContainer) throws {
  guard row.isAtEnd else {
    throw DifferentialFixture.Malformed(reason: "a row has more elements than expected")
  }
}

private enum DifferentialOp: CustomStringConvertible, Decodable {
  case setFloat(String, Float)
  case setInteger(String, Int32)
  case setBoolean(String, Bool)
  case setString(String, Int)
  case setColor(String, UInt32)
  case click(Int)
  case reopen
  case frame

  /// `[letter, arguments...]`; a float as its bits, a colour as its unsigned ARGB.
  init(from decoder: Decoder) throws {
    var row = try decoder.unkeyedContainer()
    switch try row.decode(DifferentialStepKind.self) {
    case .setFloat:
      self = .setFloat(try row.decode(String.self), Float(bitPattern: try row.decode(UInt32.self)))
    case .setInteger: self = .setInteger(try row.decode(String.self), try row.decode(Int32.self))
    case .setBoolean: self = .setBoolean(try row.decode(String.self), try row.decode(Bool.self))
    case .setString: self = .setString(try row.decode(String.self), try row.decode(Int.self))
    case .setColor: self = .setColor(try row.decode(String.self), try row.decode(UInt32.self))
    case .click: self = .click(try row.decode(Int.self))
    case .reopen: self = .reopen
    case .frame: self = .frame
    }
    try expectEnd(of: row)
  }

  var kind: DifferentialStepKind {
    switch self {
    case .setFloat: .setFloat
    case .setInteger: .setInteger
    case .setBoolean: .setBoolean
    case .setString: .setString
    case .setColor: .setColor
    case .click: .click
    case .reopen: .reopen
    case .frame: .frame
    }
  }

  var description: String {
    switch self {
    case .setFloat(let name, let value):
      "setFloat(\(value) [0x\(String(value.bitPattern, radix: 16))], \"\(name)\")"
    case .setInteger(let name, let value): "setInteger(\(value), \"\(name)\")"
    case .setBoolean(let name, let value): "setBoolean(\(value), \"\(name)\")"
    case .setString(let name, let index): "setString(strings[\(index)], \"\(name)\")"
    case .setColor(let name, let argb): "setColor(0x\(String(argb, radix: 16)), \"\(name)\")"
    case .click(let component): "click(\(component))"
    case .reopen: "reopen"
    case .frame: "frame"
    }
  }
}

/// `[op, accepted or null, [[variable, value], ...]]`.
private struct DifferentialStep: Decodable {
  struct Change: Decodable {
    let variable: Int
    let value: String

    init(from decoder: Decoder) throws {
      var row = try decoder.unkeyedContainer()
      variable = try row.decode(Int.self)
      value = try row.decode(String.self)
      try expectEnd(of: row)
    }
  }

  let op: DifferentialOp
  /// The Kotlin player's answer to a host write; nil for any other step.
  let accepted: Bool?
  /// The variables the step changed on the Kotlin player, by index, with their new values.
  let changes: [Change]

  init(from decoder: Decoder) throws {
    var row = try decoder.unkeyedContainer()
    op = try row.decode(DifferentialOp.self)
    accepted = try row.decodeNil() ? nil : try row.decode(Bool.self)
    changes = try row.decode([Change].self)
    try expectEnd(of: row)
  }
}

private struct DifferentialSequence: Decodable {
  let seed: Int
  let steps: [DifferentialStep]
}

private struct DifferentialFixture: Decodable {
  struct Malformed: Error, CustomStringConvertible {
    let reason: String
    var description: String { "named-value differential: \(reason)" }
  }

  /// `[name, id, type]`.
  struct Variable: Decodable {
    let name: String
    let id: Int
    let type: DifferentialVariableType

    init(from decoder: Decoder) throws {
      var row = try decoder.unkeyedContainer()
      name = try row.decode(String.self)
      id = try row.decode(Int.self)
      type = try DifferentialVariableType(wireType: try row.decode(Int.self))
      try expectEnd(of: row)
    }
  }

  /// One write a click performs, `[kind, target]`: the variable it targets is an index, or null
  /// for an id no variable is declared at.
  struct ClickWrite: Decodable {
    let kind: DifferentialClickKind
    let target: Int?

    init(from decoder: Decoder) throws {
      var row = try decoder.unkeyedContainer()
      kind = try row.decode(DifferentialClickKind.self)
      target = try row.decodeNil() ? nil : try row.decode(Int.self)
      try expectEnd(of: row)
    }
  }

  /// `[component, [write, ...]]`.
  private struct ClickRow: Decodable {
    let component: Int
    let writes: [ClickWrite]

    init(from decoder: Decoder) throws {
      var row = try decoder.unkeyedContainer()
      component = try row.decode(Int.self)
      writes = try row.decode([ClickWrite].self)
      try expectEnd(of: row)
    }
  }

  /// The fixture's field names (the Kotlin test's `FixtureKey`).
  private enum CodingKeys: String, CodingKey {
    case format, stringLimitBytes, document, variables, clicks, strings, initial, sequences
  }

  /// Just the format, read first, so a fixture of another layout says so rather than failing on a
  /// field.
  private struct FormatProbe: Decodable {
    let format: Int
  }

  /// The fixture layout this suite reads; the Kotlin test's `FIXTURE_FORMAT`.
  static let format = 3
  /// Where the fixtures live, from `Tests/`; with the file name, the Kotlin test's `FIXTURE_PATH`.
  static let directory = "RcNativePlayerCoreTests/Fixtures"
  static let fixtureFile = "named-value-differential.json"
  static let allowListFile = "named-value-differential-allowlist.json"

  let stringLimitBytes: Int
  let document: Data
  let variables: [Variable]
  let clicks: [Int: [ClickWrite]]
  let strings: [String]
  let initial: [String]
  let sequences: [DifferentialSequence]

  init(from decoder: Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    stringLimitBytes = try fields.decode(Int.self, forKey: .stringLimitBytes)
    guard let document = Data(base64Encoded: try fields.decode(String.self, forKey: .document))
    else { throw Malformed(reason: "document is not base64") }
    self.document = document
    variables = try fields.decode([Variable].self, forKey: .variables)
    var clicks: [Int: [ClickWrite]] = [:]
    for row in try fields.decode([ClickRow].self, forKey: .clicks) {
      guard clicks.updateValue(row.writes, forKey: row.component) == nil else {
        throw Malformed(reason: "click \(row.component) is listed twice")
      }
    }
    self.clicks = clicks
    strings = try fields.decode([String].self, forKey: .strings)
    initial = try fields.decode([String].self, forKey: .initial)
    sequences = try fields.decode([DifferentialSequence].self, forKey: .sequences)
  }

  /// The fixtures live with the core suite's, where the Kotlin test writes them; this suite reads
  /// them from the checkout.
  static func data(_ name: String) throws -> Data {
    try Data(
      contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(directory)
        .appendingPathComponent(name))
  }

  static func load() throws -> DifferentialFixture {
    let data = try data(fixtureFile)
    let found = try JSONDecoder().decode(FormatProbe.self, from: data).format
    guard found == format else { throw Malformed(reason: "format \(found) is not \(format)") }
    let fixture = try JSONDecoder().decode(DifferentialFixture.self, from: data)
    try fixture.validate()
    return fixture
  }

  /// The checks decoding cannot make: the limit both languages share, every index in range, and
  /// every kind of step and click used.
  private func validate() throws {
    // The strings at and past the limit are the Kotlin test's; the limit they test is this one.
    guard stringLimitBytes == NativeSwiftDocumentDecoder.maximumStringBytes else {
      throw Malformed(
        reason: "the fixture's string limit, \(stringLimitBytes) bytes, is not the native player's "
          + "\(NativeSwiftDocumentDecoder.maximumStringBytes)")
    }
    guard initial.count == variables.count else {
      throw Malformed(reason: "\(initial.count) initial values for \(variables.count) variables")
    }
    for writes in clicks.values {
      for case let target? in writes.map(\.target) where !variables.indices.contains(target) {
        throw Malformed(reason: "a click targets variable \(target)")
      }
    }
    for sequence in sequences {
      for step in sequence.steps {
        for change in step.changes where !variables.indices.contains(change.variable) {
          throw Malformed(reason: "seed \(sequence.seed) changes variable \(change.variable)")
        }
        switch step.op {
        case .setString(_, let index) where !strings.indices.contains(index):
          throw Malformed(reason: "seed \(sequence.seed) writes string \(index)")
        case .click(let component) where clicks[component] == nil:
          throw Malformed(reason: "seed \(sequence.seed) clicks unknown \(component)")
        default:
          break
        }
      }
    }
    // A kind the Kotlin test no longer writes would leave a case here that nothing exercises.
    let stepKinds = Set(sequences.flatMap { $0.steps.map(\.op.kind) })
    guard stepKinds == Set(DifferentialStepKind.allCases) else {
      throw Malformed(reason: "steps cover \(stepKinds), not every DifferentialStepKind")
    }
    let clickKinds = Set(clicks.values.flatMap { $0.map(\.kind) })
    guard clickKinds == Set(DifferentialClickKind.allCases) else {
      throw Malformed(reason: "clicks cover \(clickKinds), not every DifferentialClickKind")
    }
  }
}

/// The divergences this suite tolerates, by rule: `deliberate` ones, each with why it is not a
/// bug, and known `bug`s, each with a public `tracking` issue (`trackingPattern`) or a reason of at
/// least `minimumBugReasonLength` characters describing it, so the suite stays green until the fix
/// lands and then fails until the entry is removed.
private struct DifferentialAllowList {
  enum Kind: String, Decodable {
    case deliberate, bug
  }

  struct Entry: Decodable {
    let id: String
    let kind: Kind
    let reason: String
    let tracking: String?
  }

  private struct File: Decodable {
    let allowed: [Entry]
  }

  static let minimumBugReasonLength = 20
  static let trackingPattern = #"^yschimke/rc-players#\d+$"#

  let reasonsByRule: [DifferentialRule: String]

  static func load() throws -> DifferentialAllowList {
    let file = try JSONDecoder().decode(
      File.self, from: DifferentialFixture.data(DifferentialFixture.allowListFile))
    var reasonsByRule: [DifferentialRule: String] = [:]
    for entry in file.allowed {
      guard let rule = DifferentialRule(rawValue: entry.id), !entry.reason.isEmpty else {
        throw DifferentialFixture.Malformed(
          reason: "an allow-list entry needs a known rule id and a reason: \(entry.id)")
      }
      guard reasonsByRule[rule] == nil else {
        throw DifferentialFixture.Malformed(reason: "allow-list entry \(entry.id) is listed twice")
      }
      switch entry.kind {
      case .deliberate:
        break
      case .bug:
        if let tracking = entry.tracking {
          guard tracking.range(of: trackingPattern, options: .regularExpression) != nil else {
            throw DifferentialFixture.Malformed(
              reason: "bug entry \(entry.id): tracking is yschimke/rc-players#number")
          }
        } else if entry.reason.count < minimumBugReasonLength {
          throw DifferentialFixture.Malformed(
            reason: "bug entry \(entry.id) needs a public tracking issue or a reason describing it")
        }
      }
      reasonsByRule[rule] = entry.reason
    }
    return DifferentialAllowList(reasonsByRule: reasonsByRule)
  }
}
