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

  /// Android's `Paint.setTextSize` ignores a size below 0 or NaN (hwui `jni/Paint.cpp:1001`,
  /// `if (textSize >= 0)`), and AndroidX's `replacePaint` has just reset the paint
  /// (`AndroidPaintContext.java:533`), so such text draws at Skia's default of 12 pixels
  /// (`SkPaintDefaults.h:20`). An infinity saturates as any layout float does.
  @Test func aHostTextSizeBelowZeroIsAndroidsDefaultSize() throws {
    let cases: [(Float, Float)] = [
      (.nan, 12), (-.infinity, 12), (-1e30, 12), (-1, 12), (0, 0), (1e30, 1e30),
      (.infinity, .greatestFiniteMagnitude), (18, 18),
    ]
    for (value, expected) in cases {
      let session = try NativeSwiftDocumentSession.open(data: Self.hostTextSizeDocument())
      #expect(session.setFloat(value, for: HostValueEdgeFixtures.floatName), "\(value)")
      let text = try Self.nodes(session.snapshot(timeSeconds: 0).root).compactMap(\.text).first
      #expect(text?.size == expected, "\(value): \(String(describing: text?.size))")
      if value.isNaN || value < 0 {
        #expect(text?.sizeIsDensityTyped == false, "\(value): Android's default is pixels")
      }
    }
  }

  /// A host's text weight takes the Kotlin player's `rcFontWeight`: NaN is the normal 400, and
  /// any other value is held to the 1...1000 `FontWeight` takes.
  @Test func aHostTextWeightIsNormalised() throws {
    let cases: [(Float, Float)] = [
      (.nan, 400), (.infinity, 1_000), (-.infinity, 1), (1e30, 1_000), (-1, 1), (700, 700),
    ]
    for (value, expected) in cases {
      let session = try NativeSwiftDocumentSession.open(data: Self.hostTextWeightDocument())
      #expect(session.setFloat(value, for: HostValueEdgeFixtures.floatName), "\(value)")
      let text = try Self.nodes(session.snapshot(timeSeconds: 0).root).compactMap(\.text).first
      #expect(text?.weight == expected, "\(value): \(String(describing: text?.weight))")
    }
  }

  /// A text snapshot a host builds itself follows the same rule, so no platform player has to
  /// refuse a NaN size or weight: `NativeSwiftTextSnapshot.init` owns it.
  @Test func aTextSnapshotNormalisesItsSizeAndWeight() {
    let cases: [(size: Float, weight: Float, expectedSize: Float, expectedWeight: Float)] = [
      (.nan, .nan, 12, 400), (-1, -.infinity, 12, 1),
      (
        .infinity, .infinity,
        .greatestFiniteMagnitude, 1_000
      ), (18, 700, 18, 700),
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

  /// The Kotlin player passes `NaN.dp`, `Dp.Unspecified`, to `widthIn(max =)` and `heightIn`
  /// (`RcComposePlayer.kt` `applyWidthRange`), which leaves the bound unset.
  @Test func aNaNSizeInMaximumIsUnbounded() throws {
    for opcode in [NativeSwiftWireOpcode.modifierWidthIn, NativeSwiftWireOpcode.modifierHeightIn] {
      for (value, expected) in [(Float.nan, Float(-1)), (50, 50)] {
        let session = try NativeSwiftDocumentSession.open(data: Self.sizeInDocument(opcode))
        #expect(session.setFloat(value, for: HostValueEdgeFixtures.floatName))
        let canvas = try Self.nodes(session.snapshot(timeSeconds: 0).root)
          .first { $0.componentID == 3 }
        let maximum =
          opcode == NativeSwiftWireOpcode.modifierWidthIn
          ? canvas?.maximumWidth : canvas?.maximumHeight
        #expect(maximum == expected, "opcode \(opcode), \(value): \(String(describing: maximum))")
      }
    }
  }

  /// A spring towards a host's NaN reads NaN, as AndroidX's `SpringStopEngine` and the Kotlin
  /// `RcSpringAnimation` compute it, but it is final: it stops requesting frames, where both of
  /// them repaint forever. A finite target afterwards settles the spring on it at rest, as
  /// Kotlin's `settleAt` does, rather than leaving the NaN velocity AndroidX's `setInitialValue`
  /// keeps, which would hold the value at NaN for good.
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

  /// AndroidX's `SpringStopEngine.compute` over-samples a frame in proportion to the spring's
  /// natural frequency times the frame, `(int) (1 + 9 * (Math.sqrt(mStiffness / mMass) * dt * 4))`
  /// capped at 1000 (`SpringStopEngine.java:231-232`, mass 1 at `:101`), as the Kotlin
  /// `RcSpringAnimation.compute` does. Kotlin's `aSpringConvergesAtCoarseFrameIntervals`: the
  /// `remote-m3` selection spring (stiffness 1400, critically damped) at 100 ms frames stays in
  /// [0, 1] and settles, and every frame matches AndroidX's integrator.
  @Test func aStiffSpringConvergesAtCoarseFrameIntervalsAsAndroidXDoes() throws {
    let stiffness = 1_400.0
    let damping = Double(Float(74.83315))
    let session = try NativeSwiftDocumentSession.open(
      data: Self.hostSpringDocument(
        initial: 0, stiffness: Float(stiffness), damping: Float(damping)))
    var time = 0.0
    _ = try session.snapshot(timeSeconds: time)
    _ = try session.probeValues(timeSeconds: time)
    #expect(session.setFloat(1, for: HostValueEdgeFixtures.floatName))
    var reference = AndroidXSpring(stiffness: stiffness, damping: damping, target: 1)
    for _ in 0..<20 {
      time += 0.1
      _ = try session.snapshot(timeSeconds: time)
      let value = try #require(try session.probeValues(timeSeconds: time).floats[51])
      let expected = reference.get(0.1)
      #expect(value >= -0.01 && value <= 1.01, "the spring left [0, 1] at t=\(time): \(value)")
      #expect(abs(Double(value) - expected) < 1e-3, "t=\(time): \(value), AndroidX \(expected)")
    }
    #expect(try session.probeValues(timeSeconds: time).floats[51] == 1)
    #expect(!(try session.snapshot(timeSeconds: time)).needsContinuousFrames)
  }

  /// The Kotlin player runs AndroidX's loop, `for (i = from; i < until; i += step)`
  /// (`LoopOperation.java:125`), and stops a loop that would not end after 10 000 passes
  /// (`RcPlayerState.forEachLoopValue`): `RcPlayerStateTest.loopOperationHonorsTheIterationCap`'s
  /// cases. This player unrolls the loop when it opens the document, with the same cap. It reads
  /// the bounds then, from literals and document constants, which cannot be NaN, so Kotlin's NaN
  /// cases have no counterpart here.
  @Test func aLoopStopsAtKotlinsCap() throws {
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
      let commands = try NativeSwiftDocumentSession.open(data: document.data).snapshot().root
        .commands
      #expect(commands.count == passes + 1, "\(label): \(commands.count - 1) passes")
    }
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
      let commands = try NativeSwiftDocumentSession.open(data: document.data).snapshot().root
        .commands
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

  /// A text layout whose size is the host's float, declared 1.
  static func hostTextSizeDocument() -> Data {
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

  /// One 16 px text whose weight reads the host's float, declared 400.
  static func hostTextWeightDocument() -> Data {
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

  /// A canvas (id 3) under a `widthIn` or `heightIn` from 0 to the host's float, declared 1.
  static func sizeInDocument(_ opcode: Int) -> Data {
    let writer = Writer()
    writer.header(width: 100, height: 60)
    writer.u8(NativeSwiftWireOpcode.dataFloat).int(40).float(1)
    writer.namedVariable(
      id: 40, type: NativeSwiftNamedVariableType.float, name: HostValueEdgeFixtures.floatName)
    writer.u8(NativeSwiftWireOpcode.layoutRoot).int(1)
    writer.u8(NativeSwiftWireOpcode.layoutContent).int(2)
    writer.u8(NativeSwiftWireOpcode.layoutCanvas).int(3).int(30)
    writer.u8(opcode).float(0).int(Writer.nanReference(40))
    writer.u8(NativeSwiftWireOpcode.canvasOperations)
    writer.u8(NativeSwiftWireOpcode.drawRect).float(0).float(0).float(40).float(40)
    for _ in 0..<4 { writer.u8(NativeSwiftWireOpcode.containerEnd) }
    return writer.data
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
