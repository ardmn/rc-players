import Foundation
import Testing

@testable @_spi(Conformance) @_spi(RemoteComposeController) import RcNativePlayerCore

/// Any value AndroidX's `setNamed*Override` takes (NaN, infinities, strings over 4000 bytes)
/// reaches every consumer without failing the frame, on the Kotlin `RcHostValueEdgeRenderTest`
/// documents.
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
      let root = try session.snapshot(timeSeconds: 0).root
      let offsets = Self.nodes(root).map { ($0.offsetX, $0.offsetY) }
      #expect(offsets.allSatisfy { $0.0.isFinite && $0.1.isFinite }, "\(value): \(offsets)")
      #expect(
        offsets.contains { $0.0 == expected && $0.1 == expected }
          || (expected == 0 && offsets.allSatisfy { $0.0 == 0 && $0.1 == 0 }),
        "\(value): \(offsets)")
    }
  }

  /// Android's `Paint.setTextSize` ignores a size below 0 or NaN (hwui `jni/Paint.cpp:1001`,
  /// `if (textSize >= 0)`), and AndroidX's `replacePaint` has just reset the paint
  /// (`AndroidPaintContext.java:533`), so such text draws at Skia's default of 12 pixels
  /// (`SkPaintDefaults.h:20`). A size past 1e6, an infinity included, is 1e6, as the Kotlin
  /// player's `rcTextSizePixels` caps it (`RC_MAX_TEXT_SIZE_PX`).
  @Test func aHostTextSizeBelowZeroIsAndroidsDefaultSize() throws {
    /// A text layout whose size is the host's float, declared 1.
    func hostTextSizeDocument() -> Data {
      let writer = Writer()
      writer.header(width: 100, height: 60)
      writer.u8(NativeSwiftWireOpcode.dataFloat).int(40).float(1)
      writer.namedVariable(
        id: 40, type: NativeSwiftNamedVariableType.float, name: HostValueEdgeFixtures.floatName)
      writer.text(id: 5, "hello")
      writer.u8(NativeSwiftWireOpcode.layoutRoot).int(1)
      writer.textLayout(id: 5, textID: 5, color: 0xff00_0000, sizeWord: Writer.nanReference(40))
      writer.u8(NativeSwiftWireOpcode.containerEnd)
      return writer.data
    }
    let cases: [(Float, Float)] = [
      (.nan, 12), (-.infinity, 12), (-1e30, 12), (-1, 12), (0, 0), (1e30, 1e6),
      (.infinity, 1e6), (1e6, 1e6), (18, 18),
    ]
    for (value, expected) in cases {
      let session = try NativeSwiftDocumentSession.open(data: hostTextSizeDocument())
      #expect(session.setFloat(value, for: HostValueEdgeFixtures.floatName), "\(value)")
      let root = try session.snapshot(timeSeconds: 0).root
      let text = Self.nodes(root).compactMap(\.text).first
      #expect(text?.size == expected, "\(value): \(String(describing: text?.size))")
      if value.isNaN || value < 0 {
        #expect(text?.sizeIsDensityTyped == false, "\(value): Android's default is pixels")
      }
    }
  }

  /// A host's text weight takes the Kotlin player's `rcFontWeight`: NaN is the normal 400, and
  /// any other value is held to the 1...1000 `FontWeight` takes.
  @Test func aHostTextWeightIsNormalised() throws {
    /// One 16 px text whose weight reads the host's float, declared 400.
    func hostTextWeightDocument() -> Data {
      let writer = Writer()
      writer.header(width: 100, height: 60)
      writer.u8(NativeSwiftWireOpcode.dataFloat).int(40).float(400)
      writer.namedVariable(
        id: 40, type: NativeSwiftNamedVariableType.float, name: HostValueEdgeFixtures.floatName)
      writer.text(id: 5, "hello")
      writer.u8(NativeSwiftWireOpcode.layoutRoot).int(1)
      writer.u8(NativeSwiftWireOpcode.layoutText).int(5).int(0).int(5)
        .int(Int(Int32(bitPattern: 0xff00_0000))).float(16).int(0).int(Writer.nanReference(40))
        .int(-1).int(1).int(1).int(1)
      writer.u8(NativeSwiftWireOpcode.containerEnd)
      writer.u8(NativeSwiftWireOpcode.containerEnd)
      return writer.data
    }
    let cases: [(Float, Float)] = [
      (.nan, 400), (.infinity, 1_000), (-.infinity, 1), (1e30, 1_000), (-1, 1), (700, 700),
    ]
    for (value, expected) in cases {
      let session = try NativeSwiftDocumentSession.open(data: hostTextWeightDocument())
      #expect(session.setFloat(value, for: HostValueEdgeFixtures.floatName), "\(value)")
      let root = try session.snapshot(timeSeconds: 0).root
      let text = Self.nodes(root).compactMap(\.text).first
      #expect(text?.weight == expected, "\(value): \(String(describing: text?.weight))")
    }
  }

  /// A text snapshot a host builds itself follows the same rule, so no platform player has to
  /// refuse a NaN size or weight: `NativeSwiftTextSnapshot.init` owns it.
  @Test func aTextSnapshotNormalisesItsSizeAndWeight() {
    let cases: [(size: Float, weight: Float, expectedSize: Float, expectedWeight: Float)] = [
      (.nan, .nan, 12, 400), (-1, -.infinity, 12, 1), (.infinity, .infinity, 1e6, 1_000),
      (18, 700, 18, 700),
    ]
    for entry in cases {
      let text = NativeSwiftTextSnapshot(
        value: "a", colorARGB: 0xff00_0000, size: entry.size, style: 0, weight: entry.weight,
        familyID: -1, alignment: .start, overflow: 1, maximumLines: 1, sizeIsDensityTyped: true)
      #expect(text.size == entry.expectedSize, "\(entry)")
      #expect(text.weight == entry.expectedWeight, "\(entry)")
      #expect(text.sizeIsDensityTyped == (entry.size >= 0), "\(entry): Android's 12 is pixels")
    }
  }

  /// A canvas paint's text size, as the AppKit player draws it, follows the same rule with the
  /// paint's default for a size Android ignores: the Kotlin player's `rcTextSizePixels`.
  @Test func aPaintTextSizeTakesAndroidsRule() {
    let unset = NativeSwiftTextSnapshot.paintDefaultSize
    let cases: [(Float, Float)] = [
      (.nan, 16), (-1, 16), (-.infinity, 16), (0, 0), (18, 18), (1e30, 1e6), (.infinity, 1e6),
    ]
    for (size, expected) in cases {
      #expect(NativeSwiftTextSnapshot.androidSize(size, unset: unset) == expected, "\(size)")
    }
  }

  /// The Kotlin player passes `NaN.dp`, `Dp.Unspecified`, to `widthIn(max =)` and `heightIn`
  /// (`RcComposePlayer.kt` `applyWidthRange`), which leaves the bound unset.
  @Test func aNaNSizeInMaximumIsUnbounded() throws {
    let canvasID = 3
    /// A canvas under a `widthIn` or `heightIn` from 0 to the host's float, declared 1.
    func sizeInDocument(_ opcode: Int) -> Data {
      let writer = Writer()
      writer.header(width: 100, height: 60)
      writer.u8(NativeSwiftWireOpcode.dataFloat).int(40).float(1)
      writer.namedVariable(
        id: 40, type: NativeSwiftNamedVariableType.float, name: HostValueEdgeFixtures.floatName)
      writer.u8(NativeSwiftWireOpcode.layoutRoot).int(1)
      writer.u8(NativeSwiftWireOpcode.layoutContent).int(2)
      writer.u8(NativeSwiftWireOpcode.layoutCanvas).int(canvasID).int(30)
      writer.u8(opcode).float(0).int(Writer.nanReference(40))
      writer.u8(NativeSwiftWireOpcode.canvasOperations)
      writer.u8(NativeSwiftWireOpcode.drawRect).float(0).float(0).float(40).float(40)
      for _ in 0..<4 { writer.u8(NativeSwiftWireOpcode.containerEnd) }
      return writer.data
    }
    for opcode in [NativeSwiftWireOpcode.modifierWidthIn, NativeSwiftWireOpcode.modifierHeightIn] {
      let isWidth = opcode == NativeSwiftWireOpcode.modifierWidthIn
      for (value, expected) in [(Float.nan, Float(-1)), (50, 50)] {
        let session = try NativeSwiftDocumentSession.open(data: sizeInDocument(opcode))
        #expect(session.setFloat(value, for: HostValueEdgeFixtures.floatName))
        let root = try session.snapshot(timeSeconds: 0).root
        let canvas = Self.nodes(root).first { $0.componentID == canvasID }
        let maximum = isWidth ? canvas?.maximumWidth : canvas?.maximumHeight
        #expect(maximum == expected, "opcode \(opcode), \(value): \(String(describing: maximum))")
      }
    }
  }

  /// A spring towards a non-finite target reads it, as AndroidX's `SpringStopEngine` does, but stops
  /// requesting frames; a finite target then settles it at rest, as Kotlin's `settleAt` does.
  @Test func aSpringTowardsANonFiniteTargetStopsAndRecovers() throws {
    for target in [Float.nan, .infinity, -.infinity] {
      let session = try NativeSwiftDocumentSession.open(data: Self.hostSpringDocument())
      var time = 0.0
      func frame() throws -> (value: Float?, moving: Bool) {
        let snapshot = try session.snapshot(timeSeconds: time)
        let value = try session.probeValues(timeSeconds: time).floats[51]
        time += 0.016
        return (value, snapshot.needsContinuousFrames)
      }
      _ = try frame()
      #expect(session.setFloat(target, for: HostValueEdgeFixtures.floatName))
      _ = try frame()
      let held = try frame()
      #expect(!held.moving, "\(target): the spring kept requesting frames")
      #expect(
        target.isNaN ? held.value?.isNaN == true : held.value == target,
        "\(target): \(String(describing: held.value))")

      #expect(session.setFloat(2, for: HostValueEdgeFixtures.floatName))
      let recovered = try frame()
      #expect(recovered.value == 2, "after \(target): \(String(describing: recovered.value))")
      #expect(!(try frame()).moving, "after \(target): the settled spring kept requesting frames")
      // At rest, not carrying a NaN velocity: the next target springs again rather than jumping.
      #expect(session.setFloat(3, for: HostValueEdgeFixtures.floatName))
      let moving = try frame()
      #expect(moving.moving, "after \(target): a new target did not animate")
      #expect(
        moving.value.map { $0 > 2 && $0 < 3 } == true,
        "after \(target): \(String(describing: moving.value))")
    }
  }

  /// Kotlin's `aSpringConvergesAtCoarseFrameIntervals`: AndroidX over-samples each frame by the
  /// spring's frequency, capped at 1000 (`SpringStopEngine.java:231-232`, mass 1 at `:102`).
  @Test func aStiffSpringConvergesAtCoarseFrameIntervalsAsAndroidXDoes() throws {
    // The `remote-m3` selection spring, critically damped: damping = 2 * sqrt(stiffness).
    let stiffness = 1_400.0
    let damping = Double(Float(74.83315))
    let frameSeconds = 0.1
    // Float rounding of the integrator against the Double reference.
    let tolerance = 1e-3
    let session = try NativeSwiftDocumentSession.open(
      data: Self.hostSpringDocument(
        initial: 0, stiffness: Float(stiffness), damping: Float(damping)))
    var time = 0.0
    _ = try session.snapshot(timeSeconds: time)
    _ = try session.probeValues(timeSeconds: time)
    #expect(session.setFloat(1, for: HostValueEdgeFixtures.floatName))
    var reference = AndroidXSpring(stiffness: stiffness, damping: damping, target: 1)
    for _ in 0..<20 {
      time += frameSeconds
      _ = try session.snapshot(timeSeconds: time)
      let value = try #require(try session.probeValues(timeSeconds: time).floats[51])
      let expected = reference.get(frameSeconds)
      #expect(value >= -0.01 && value <= 1.01, "the spring left [0, 1] at t=\(time): \(value)")
      #expect(
        abs(Double(value) - expected) < tolerance, "t=\(time): \(value), AndroidX \(expected)")
    }
    #expect(try session.probeValues(timeSeconds: time).floats[51] == 1)
    #expect(!(try session.snapshot(timeSeconds: time)).needsContinuousFrames)
  }

  /// `RcPlayerStateTest.loopOperationHonorsTheIterationCap`'s cases: AndroidX counts a pass and each
  /// body operation (`LoopOperation.java:126-140`) and fails the frame past 20 000; here the loop
  /// stops there, so a one-operation body runs 10 000. Bounds are literals here, never NaN.
  @Test func aLoopStopsAtTheFramesOperationBudget() throws {
    let cases: [(from: Float, until: Float, step: Float, passes: Int)] = [
      (0, 1, 0.000_01, 10_000), (0, .infinity, 1, 10_000), (0, 1, 0, 10_000),
      (1e9, 2e9, 1, 10_000), (-.infinity, 0, 1, 10_000), (.infinity, .infinity, 1, 0),
      (0, 1, -1, 10_000), (0, 3, 1, 3),
    ]
    for (from, until, step, passes) in cases {
      let document = Writer()
      document.header(width: 100, height: 100)
      document.u8(NativeSwiftWireOpcode.loopStart).int(0).float(from).float(step).float(until)
      document.u8(NativeSwiftWireOpcode.drawRect).float(0).float(0).float(1).float(1)
      document.u8(NativeSwiftWireOpcode.containerEnd)
      // A draw after the loop, so a document whose loop runs no pass still draws something.
      document.u8(NativeSwiftWireOpcode.drawRect).float(1).float(1).float(2).float(2)
      let label = "from \(from) until \(until) step \(step)"
      let root = try NativeSwiftDocumentSession.open(data: document.data).snapshot().root
      let commands = root.commands
      #expect(commands.count == passes + 1, "\(label): \(commands.count - 1) passes")
    }
  }

  /// The budget is the frame's, every loop's passes and body operations together, charged in the
  /// order AndroidX runs them: a pass and each operation directly in its body.
  @Test func everyLoopInTheFrameSharesOneOperationBudget() throws {
    typealias Op = NativeSwiftWireOpcode
    func rects(_ count: Int, _ document: Writer) {
      for _ in 0..<count { document.u8(Op.drawRect).float(0).float(0).float(1).float(1) }
    }
    func drawn(_ build: (Writer) -> Void) throws -> Int {
      let document = Writer()
      document.header(width: 100, height: 100)
      build(document)
      let root = try NativeSwiftDocumentSession.open(data: document.data).snapshot().root
      return root.commands.count
    }
    let budget = NativeSwiftDocumentDecoder.maximumLoopOperationsPerFrame
    #expect(budget == 20_000)
    // Three operations a pass: 4 each.
    let threeEach = try drawn { document in
      document.u8(Op.loopStart).int(0).float(0).float(1).float(.infinity)
      rects(3, document)
      document.u8(Op.containerEnd)
    }
    #expect(threeEach == budget / 4 * 3)
    // Two loops of 15 000 passes: the first takes the whole budget.
    let twoLoops = try drawn { document in
      for _ in 0..<2 {
        document.u8(Op.loopStart).int(0).float(0).float(1).float(15_000)
        rects(1, document)
        document.u8(Op.containerEnd)
      }
    }
    #expect(twoLoops == budget / 2)
  }

  /// After the loop its index holds the last value it took, as the Kotlin player's `setFloat` of
  /// each pass leaves it, a capped loop's included.
  @Test func aCappedLoopLeavesItsIndexAtTheLastPass() throws {
    for (step, last) in [(Float(1), Float(9_999)), (0, 0)] {
      let document = Writer()
      document.header(width: 100, height: 100)
      document.u8(NativeSwiftWireOpcode.dataFloat).int(70).float(-1)
      document.u8(NativeSwiftWireOpcode.loopStart).int(70).float(0).float(step).float(.infinity)
      document.u8(NativeSwiftWireOpcode.drawRect).float(0).float(0).float(1).float(1)
      document.u8(NativeSwiftWireOpcode.containerEnd)
      document.u8(NativeSwiftWireOpcode.drawRect).int(Writer.nanReference(70)).float(0).float(1)
        .float(1)
      let root = try NativeSwiftDocumentSession.open(data: document.data).snapshot().root
      let commands = root.commands
      // 10 000 capped passes plus the draw after the loop.
      #expect(commands.count == 10_001, "step \(step)")
      #expect(
        commands.last?.values.first == last,
        "step \(step): \(String(describing: commands.last?.values))")
    }
  }

  static func nodes(_ root: NativeSwiftNodeSnapshot) -> [NativeSwiftNodeSnapshot] {
    var all: [NativeSwiftNodeSnapshot] = []
    var pending = [root]
    while let node = pending.popLast() {
      all.append(node)
      pending.append(contentsOf: node.children)
    }
    return all
  }

  /// Float 51 is a spring (stiffness 40, damping 8) towards the host's float, declared 1.
  static func hostSpringDocument(
    initial: Float = 1, stiffness: Float = 40, damping: Float = 8
  ) -> Data {
    let writer = Writer()
    writer.header(width: 100, height: 100)
    writer.u8(NativeSwiftWireOpcode.dataFloat).int(40).float(initial)
    writer.namedVariable(
      id: 40, type: NativeSwiftNamedVariableType.float, name: HostValueEdgeFixtures.floatName)
    writer.u8(NativeSwiftWireOpcode.animatedFloat).int(51).int((5 << 16) | 1)
      .int(Writer.nanReference(40)).float(0).float(stiffness).float(damping).float(0.001).int(0)
    writer.u8(NativeSwiftWireOpcode.drawRect).int(Writer.nanReference(51)).float(0).float(1)
      .float(1)
    return writer.data
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

/// AndroidX's `SpringStopEngine` (`SpringStopEngine.java:172-250`), mass 1 and no boundary, from
/// rest at 0: the reference the Swift spring must match.
struct AndroidXSpring {
  let stiffness: Double
  let damping: Double
  let target: Double
  var position = 0.0
  var velocity = 0.0
  let stopThreshold = Double(Float(0.001))

  init(stiffness: Double, damping: Double, target: Double) {
    self.stiffness = stiffness
    self.damping = damping
    self.target = target
  }

  mutating func get(_ frame: Double) -> Double {
    let requested = 1 + 9 * (stiffness.squareRoot() * frame * 4)
    let overSample = min(requested.isNaN ? 0 : Int(min(requested, 1e9)), 1_000)
    let dt = frame / Double(overSample)
    for _ in 0..<overSample {
      let x = position - target
      var a = -stiffness * x - damping * velocity
      var averageVelocity = velocity + a * dt / 2
      let averageX = position + dt * averageVelocity / 2 - target
      a = -averageX * stiffness - averageVelocity * damping
      let dv = a * dt
      averageVelocity = velocity + dv / 2
      velocity += Double(Float(dv))
      position += Double(Float(averageVelocity * dt))
    }
    let x = position - target
    let energy = velocity * velocity + stiffness * x * x
    if (energy / stiffness).squareRoot() <= stopThreshold { position = target }
    return Double(Float(position))
  }
}
