import Foundation

/// Retained document state with synchronous, internally serialized access across tasks.
public final class NativeSwiftDocumentSession: @unchecked Sendable {
  private struct StaticSnapshotCache {
    let measuredComponents: [Int: NativeSwiftMeasuredSize]
    let snapshot: NativeSwiftDocumentSnapshot
  }

  // Preserve the synchronous API while serializing its mutable session and snapshot cache. A
  // recursive lock is required because click() forwards to gesture().
  private let stateLock = NSRecursiveLock()
  private let document: ParsedDocument
  /// What a host may write by name. Immutable, like `document`, so it needs no lock.
  public let namedVariableDeclarations: NativeSwiftNamedVariableDeclarations
  /// Every text, live: the document's, then what the frame's text operations computed and what a
  /// write set. Each resolution starts it again from the document's and `textOverrides`
  /// (`RcPlayerState.beginFrame`).
  private var texts: [Int: String]
  /// The texts a write set — a host's, a document action's, a custom component's — which every
  /// resolution puts back over the document's (`RcPlayerState.textOverrides`).
  private var textOverrides: [Int: String] = [:]
  /// The float view of every numeric value, live (`RcPlayerState.floats`). Writes go through
  /// `storeFloat`, `setFloat` or `setInteger` so the integer view moves with it.
  ///
  /// Exclusivity checks are off for this and `integers`: `stateLock` already serialises access, and
  /// the check cost about a tenth of a resolution at 5000 values (`scenarios.resolutionCost`). So
  /// never pass either `inout` across a call that reads it.
  @exclusivity(unchecked) private var floats: [Int: Float]
  /// The integer view of every numeric value, live (`RcPlayerState.integers`).
  @exclusivity(unchecked) private var integers: [Int: Int]
  /// The ids a document action wrote a float to (`RcPlayerState.overriddenFloats`): a float
  /// expression at one of them no longer runs, so the action's value stays.
  private var overriddenFloats: Set<Int> = []
  /// The ids a document action wrote an integer to (`RcPlayerState.overriddenIntegers`): an integer
  /// expression at one of them no longer runs.
  private var overriddenIntegers: Set<Int> = []
  /// The system ids (`NativeSwiftSystemVariables.allIDs`) the player no longer loads: the ones the
  /// document declares a value at, and any a float write or a host's named write reached
  /// (`RcPlayerState.claimedSystemIds`).
  private var claimedSystemIDs: Set<Int>
  /// The claims the document made itself, which clearing a host's named value leaves standing.
  private let documentClaimedSystemIDs: Set<Int>
  /// The ids whose float a host or a document action wrote, so `writtenNamedValues` can carry it.
  private var writtenFloatIDs: Set<Int> = []
  /// The ids whose float the document declares as a `FloatConstant`: an action's integer write
  /// there is carried as the float variable's value (`writtenNamedValues`).
  private let floatConstantIDs: Set<Int>
  /// The longs a host has set by name, over the document's `LongConstant`s.
  private var longOverrides: [Int: Int64] = [:]
  /// The float arrays a host has set by name, over the lists the document keeps at those ids.
  private var floatArrayOverrides: [Int: [Float]] = [:]
  private var hostDensity: Float = 1
  private var hostFontScale: Float = 1
  private var requestedTheme = NativeSwiftTheme.unspecified
  /// Every colour, live (`RcPlayerState.colors`): the document's constants, then what its colour
  /// expressions and themed colours wrote, and a host's named writes.
  private var colors: [Int: UInt32]
  /// Both numeric views as the document loaded them when it opened (`seededNumericViews`): what
  /// `clearNamedValue` restores a float or integer variable to.
  private let recordedFloats: [Int: Float]
  private let recordedIntegers: [Int: Int]
  /// The colours a host has set by name, which the document's own writes leave alone
  /// (`RcPlayerState.colorOverrides`).
  private var hostSetColors: Set<Int> = []
  /// The integer and text slots a write has reached since the session opened — the host's, or one
  /// of the document's own actions — as opposed to ones only the document's computations fill (a
  /// text operation's output, an integer expression). A float write is in `writtenFloatIDs`.
  private var writtenIntegerAndTextIDs: Set<Int> = []
  /// The wall clock the last resolution ran at, which a float expression's animation (an action's
  /// included) and a time attribute read.
  private var frameWallClock: NativeSwiftWallClock?
  /// The instant the last resolution ran at, which an animation and a time attribute read.
  private var frameTimeSeconds: TimeInterval = 0
  /// The instant the last resolution that finished ran at, nil before one has (or while one runs);
  /// see `resolveUnlessResolved`.
  private var resolvedFrameTime: TimeInterval?
  /// What the host last measured its bound components at, which a probe resolves against rather
  /// than this core's estimate.
  private var lastMeasuredComponents: [Int: NativeSwiftMeasuredSize] = [:]
  private var floatAnimationRuntimes: [Int: NativeSwiftFloatAnimationRuntime] = [:]
  private var particleSystems: [Int: NativeSwiftParticleSystemRuntime] = [:]
  /// AndroidX's per-impulse "first frame in the window" bit, and each impulse's phase at the frame
  /// last advanced to.
  private var impulseInitialPass: [Int: Bool] = [:]
  private var impulsePhases: [Int: NativeSwiftImpulsePhase] = [:]
  private var lastImpulseFrameTime: TimeInterval?
  private var lastParticleFrameTime: TimeInterval?
  /// Whether a particle comparison's condition passed on the frame last advanced to: the reference
  /// asks for another frame then, and only then, where a loop always asks.
  private var particleCompareFired = false
  /// The frame instant `RUN_ACTION` bodies last ran at, so that resolving one frame twice (a
  /// snapshot and a probe) runs them once.
  private var lastRunActionFrameTime: TimeInterval?
  private var lastFrameEffectsTime: TimeInterval?
  private var pendingFrameEffects: [NativeSwiftEvent] = []
  /// The instant this session was first painted at, on the clock its frames are resolved against;
  /// what a marquee times itself from. Latched by the first snapshot unless a host pinned it.
  private var firstPaintSeconds: TimeInterval?
  // A host may request another frame for a document that has no clock-driven state. Preserve the
  // public value snapshot while sharing its copy-on-write storage instead of re-resolving the
  // complete parsed tree each time. Measurements remain part of the cache key because they are the
  // deliberate second pass of the layout contract.
  private var staticSnapshotCache: StaticSnapshotCache?
  /// The custom visibility animations playing, by component.
  private var visibilityTracker = NativeSwiftVisibilityTracker()

  private init(document: ParsedDocument) {
    self.document = document
    namedVariableDeclarations = NativeSwiftNamedVariableDeclarations(
      variables: document.namedVariables)
    texts = document.texts
    colors = document.colors
    var (floats, integers) = Self.seededNumericViews(of: document)
    // Room for every value a resolution writes, so the first frame does not grow the tables step
    // by step: each step writes about one id, a component value one, the system variables theirs.
    let capacity =
      floats.count + document.resolutionSteps.count + document.componentValues.count
      + NativeSwiftSystemVariables.allIDs.count
    floats.reserveCapacity(capacity)
    integers.reserveCapacity(capacity)
    // `RcPlayerState`'s init: a component value nothing declared reads 0 until it is measured.
    for binding in document.componentValues where floats[binding.valueID] == nil {
      floats[binding.valueID] = 0
      integers[binding.valueID] = 0
    }
    (self.floats, self.integers) = (floats, integers)
    (recordedFloats, recordedIntegers) = (floats, integers)
    floatConstantIDs = Set(
      document.numericConstants.compactMap {
        if case .float(let id, _) = $0 { id } else { nil }
      })
    // `rcClaimedSystemIdsOf`: the system ids the document declares a constant or a component
    // value at.
    // A `FloatConstant` that names another value is one too, though the decoder runs it as an
    // expression.
    var claimed = Set(document.numericConstants.map(\.id))
    claimed.formUnion(document.componentValues.map(\.valueID))
    claimed.formUnion(
      document.expressions.filter { $0.opcode == NativeSwiftWireOpcode.dataFloat }.map(\.id))
    claimed = claimed.filter(NativeSwiftSystemVariables.isSystem)
    (claimedSystemIDs, documentClaimedSystemIDs) = (claimed, claimed)
    // `RcPlayerState`'s init ends with `beginFrame()`: the system variables and the density are
    // loaded before any frame, so input that arrives first reads them rather than 0.
    beginFrame(timeSeconds: 0, wallClock: nil)
  }

  /// The document's own floats and integers, loaded as `RcSeedValues.load` loads them: constants in
  /// wire order, a float publishing both views (the integer truncated), an integer replacing both
  /// unless the id already holds that integer. What an expression, lookup or image attribute
  /// computes is not here: the first resolution writes it.
  private static func seededNumericViews(of document: ParsedDocument) -> ([Int: Float], [Int: Int])
  {
    var floats: [Int: Float] = [:]
    var integers: [Int: Int] = [:]
    for constant in document.numericConstants {
      switch constant {
      case .float(let id, let value):
        floats[id] = value
        integers[id] = nativeSwiftIntegerView(value)
      case .integer(let id, let value):
        guard integers[id] != value else { continue }
        integers[id] = value
        floats[id] = Float(value)
      }
    }
    return (floats, integers)
  }

  /// Opens a document.
  ///
  /// - Parameter toleratingRootlessData: decode a *data-only* document — one that declares values
  ///   and nothing to draw — instead of refusing it. The conformance lane asks for this so its value
  ///   probes can be answered; a host that is about to render keeps the default and is told the
  ///   document has nothing to paint.
  public static func open(
    data: Data, toleratingRootlessData: Bool = false
  ) throws -> NativeSwiftDocumentSession {
    open(
      prepared: try NativeSwiftPreparedDocument.decode(
        data: data, toleratingRootlessData: toleratingRootlessData))
  }

  /// Opens a fresh session over an already-decoded ``NativeSwiftPreparedDocument``.
  ///
  /// The returned session shares the immutable parsed AST and owns its own mutable variables,
  /// animation runtimes, and snapshot cache.
  public static func open(
    prepared: NativeSwiftPreparedDocument
  ) -> NativeSwiftDocumentSession {
    NativeSwiftDocumentSession(document: prepared.parsed)
  }

  /// The operation spans of a document the decoder accepts, for structure-aware mutation.
  ///
  /// Data-only documents remain strict by default. The conformance value lane can deliberately
  /// opt into the same rootless mode as ``open(data:toleratingRootlessData:)``.
  @_spi(Conformance) public static func operationSpans(
    in data: Data, toleratingRootlessData: Bool = false
  ) throws -> [NativeSwiftOperationSpan] {
    var spans: [NativeSwiftOperationSpan] = []
    _ = try NativeSwiftDocumentDecoder.decode(
      data, spans: &spans, toleratingRootlessData: toleratingRootlessData)
    return spans
  }

  /// The linked document's top-level operation census, with the header included. This is the
  /// operation model conformance exposes; it intentionally differs from raw wire spans.
  @_spi(Conformance) public var linkedOperationCount: Int { document.linkedOperationCount }

  /// Every operation the document carries on the wire, by opcode, once each and in wire order,
  /// header excluded — the census the reference takes of `document.operations`. Unlike
  /// ``operationSpans(in:toleratingRootlessData:)`` it counts a branch that does not run, and a
  /// macro body once however often it is called.
  @_spi(Conformance) public var operationCensus: [Int] { document.operationCensus }

  private init(copying other: NativeSwiftDocumentSession) {
    document = other.document
    namedVariableDeclarations = other.namedVariableDeclarations
    texts = other.texts
    textOverrides = other.textOverrides
    floats = other.floats
    integers = other.integers
    overriddenFloats = other.overriddenFloats
    overriddenIntegers = other.overriddenIntegers
    claimedSystemIDs = other.claimedSystemIDs
    documentClaimedSystemIDs = other.documentClaimedSystemIDs
    writtenFloatIDs = other.writtenFloatIDs
    floatConstantIDs = other.floatConstantIDs
    longOverrides = other.longOverrides
    floatArrayOverrides = other.floatArrayOverrides
    colors = other.colors
    recordedFloats = other.recordedFloats
    recordedIntegers = other.recordedIntegers
    hostSetColors = other.hostSetColors
    writtenIntegerAndTextIDs = other.writtenIntegerAndTextIDs
    frameWallClock = other.frameWallClock
    frameTimeSeconds = other.frameTimeSeconds
    resolvedFrameTime = other.resolvedFrameTime
    lastMeasuredComponents = other.lastMeasuredComponents
    hostDensity = other.hostDensity
    hostFontScale = other.hostFontScale
    floatAnimationRuntimes = other.floatAnimationRuntimes.mapValues { $0.detachedCopy() }
    particleSystems = other.particleSystems.mapValues { $0.detachedCopy() }
    impulseInitialPass = other.impulseInitialPass
    requestedTheme = other.requestedTheme
    impulsePhases = other.impulsePhases
    lastImpulseFrameTime = other.lastImpulseFrameTime
    lastParticleFrameTime = other.lastParticleFrameTime
    particleCompareFired = other.particleCompareFired
    lastRunActionFrameTime = other.lastRunActionFrameTime
    lastFrameEffectsTime = other.lastFrameEffectsTime
    firstPaintSeconds = other.firstPaintSeconds
    staticSnapshotCache = other.staticSnapshotCache
    visibilityTracker = other.visibilityTracker
  }

  /// A session with this one's state, sharing nothing mutable.
  ///
  /// It exists so a host can re-resolve a snapshot **synchronously**, from inside its own layout
  /// pass, without reaching into the session its frames come from. That matters because `snapshot`
  /// writes as well as reads -- float-to-text conversions, lookups and merges all populate `texts`
  /// -- so calling it from another isolation domain would race whatever is producing frames.
  ///
  /// The copy holds the parsed document, which is immutable once decoded, and its own copies of
  /// everything else. Its state is therefore frozen at the moment it was taken: a host should take
  /// a fresh one with each frame rather than keeping one across document state changes.
  public func detachedCopy() -> NativeSwiftDocumentSession {
    stateLock.lock()
    defer { stateLock.unlock() }
    return NativeSwiftDocumentSession(copying: self)
  }

  /// Tells the document what density it is being played at.
  ///
  /// A `RemoteDensity.Host` capture defers its density instead of folding it in: it writes
  /// expressions over `ID_DENSITY` (27) and `ID_FONT_SIZE` (33), so the same document resolves at
  /// whatever the player supplies. Left unsaid, the native player plays at 1.0 — which is the
  /// density its default layout mode resolves dp geometry at, so the two agree by construction.
  /// A host reproducing Android geometry supplies its real playback density here.
  ///
  /// Non-finite and non-positive values are ignored rather than stored: both reach a document as a
  /// divisor, and a host that reports a zero density mid-layout should not turn the frame's
  /// geometry into NaN.
  public func setHostDensity(_ density: Float, fontScale: Float = 1) {
    stateLock.lock()
    defer { stateLock.unlock() }
    if density.isFinite, density > 0 { hostDensity = density }
    if fontScale.isFinite, fontScale > 0 { hostFontScale = fontScale }
    // Published now, not at the next resolution, as `RcPlayerState.setHostDensity` does: input that
    // arrives before the next frame reads the density the host just reported.
    loadHostDensity()
    invalidateResolution()
  }

  /// Pins the instant the document was first painted, on the `timeSeconds` clock.
  ///
  /// A host that renders frames from a fresh session each time — the conformance batch — would
  /// otherwise latch every frame as the first, and a marquee would never move. The reference
  /// harness holds its clock one second before a frame sequence's base through the warm-up paints,
  /// so that is the instant it names here.
  public func setFirstPaintTime(_ seconds: TimeInterval) {
    stateLock.lock()
    defer { stateLock.unlock() }
    firstPaintSeconds = seconds
    staticSnapshotCache = nil
  }

  /// Seconds since the first paint; the first snapshot latches it.
  private func marqueeElapsedSeconds(at timeSeconds: TimeInterval) -> TimeInterval {
    if firstPaintSeconds == nil { firstPaintSeconds = timeSeconds }
    return max(timeSeconds - (firstPaintSeconds ?? timeSeconds), 0)
  }

  /// Whether a component's change of visibility plays its custom visibility animation — the
  /// reference's `isAnimationEnabled`. On by default. A host turns it off when it stops advancing
  /// frames for Reduce Motion, so a change lands at once instead of stalling part-way; turning it
  /// off ends the animations playing.
  public func setVisibilityAnimationsEnabled(_ enabled: Bool) {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard visibilityTracker.animationsEnabled != enabled else { return }
    visibilityTracker.animationsEnabled = enabled
    staticSnapshotCache = nil
  }

  /// The theme the host is showing: `NativeSwiftTheme.dark`, `.light` or `.unspecified`.
  ///
  /// A `ColorTheme` resolves to its dark fallback under a dark theme and to its light one
  /// otherwise. Unspecified stays light rather than following the TypeScript reference's dark,
  /// because light is what the reference JVM lane renders for a player with no theme (see the
  /// `ColorTheme` decode). Operations a `THEME` marker scopes are not filtered by it yet. It
  /// lands at the next resolution, whose `ColorTheme` steps write the chosen fallbacks.
  public func setRequestedTheme(_ theme: Int) {
    stateLock.lock()
    defer { stateLock.unlock() }
    requestedTheme = theme
    invalidateResolution()
  }

  /// - Parameter measuredComponents: what the host laid each bound component out at, once it knows.
  ///   A component named here resolves its width and height bindings from the measurement; one that
  ///   is absent falls back to this core's own estimate, which is what every caller got before this
  ///   parameter existed. Pass nothing on the first pass -- there is nothing to measure yet.
  /// - Parameter wallClock: the host's absolute time, for a document that reads a calendar or
  ///   time-of-day variable. Omitted, those variables are left unset and the elapsed clock is the
  ///   only one a document can animate off.
  public func snapshot(
    timeSeconds: TimeInterval = 0, wallClock: NativeSwiftWallClock? = nil,
    measuredComponents: [Int: NativeSwiftMeasuredSize] = [:]
  ) throws -> NativeSwiftDocumentSnapshot {
    stateLock.lock()
    defer { stateLock.unlock() }
    if canReuseStaticSnapshot(timeSeconds: timeSeconds, wallClock: wallClock),
      let cached = staticSnapshotCache, cached.measuredComponents == measuredComponents
    {
      return cached.snapshot
    }
    lastMeasuredComponents = measuredComponents
    try resolveFrameAndRunDocument(timeSeconds: timeSeconds, wallClock: wallClock)
    advanceImpulses(values: floats, timeSeconds: timeSeconds)
    if lastFrameEffectsTime != timeSeconds, !document.frameEffects.isEmpty {
      lastFrameEffectsTime = timeSeconds
      if document.runActions.isEmpty { pendingFrameEffects.removeAll() }
      pendingFrameEffects += try execute(
        document.frameEffects.filter { impulseAllows($0.impulseGate) }.map(\.action))
    }
    let values = floats
    let resolvedColors = colors
    // Resolved ahead of the snapshot's other fields: resolving advances the visibility transitions,
    // and whether one is still playing decides `needsContinuousFrames`.
    let root = try resolve(
      document.root, values: values, colors: resolvedColors, timeSeconds: timeSeconds)
    let snapshot = NativeSwiftDocumentSnapshot(
      width: document.width,
      height: document.height,
      density: document.density,
      densityBehavior: document.densityBehavior,
      root: root,
      images: document.imageSnapshots,
      clickAreas: document.clickAreas.map { area in
        NativeSwiftClickAreaSnapshot(
          id: area.id, contentDescription: texts[area.contentDescriptionID],
          left: NativeSwiftFloatExpression.resolve(area.left, values: values),
          top: NativeSwiftFloatExpression.resolve(area.top, values: values),
          right: NativeSwiftFloatExpression.resolve(area.right, values: values),
          bottom: NativeSwiftFloatExpression.resolve(area.bottom, values: values),
          metadata: texts[area.metadataID])
      },
      needsContinuousFrames: document.needsContinuousFrames || document.hasParticleLoop
        || particleCompareFired || visibilityTracker.hasActiveTransition
        || floatAnimationRuntimes.contains {
          !overriddenFloats.contains($0.key) && $0.value.isAnimating(at: Float(timeSeconds))
        },
      needsWallClockRefresh: document.needsWallClockRefresh || measuresFromNowForAMissingArgument,
      boundComponents: document.boundComponentIDs,
      animationSpecs: document.animationSpecs,
      accessibilityRecords: document.accessibilityRecords.map {
        NativeSwiftAccessibilitySnapshot(
          contentDescriptionID: $0.contentDescriptionID, role: $0.role, textID: $0.textID,
          stateDescriptionID: $0.stateDescriptionID, mode: $0.mode,
          contentDescription: texts[$0.contentDescriptionID], text: texts[$0.textID],
          stateDescription: texts[$0.stateDescriptionID], isEnabled: $0.isEnabled,
          isClickable: $0.isClickable)
      },
      impulses: document.impulses.map {
        NativeSwiftImpulseSnapshot(
          duration: NativeSwiftFloatExpression.resolve($0.durationWord, values: values),
          startAt: NativeSwiftFloatExpression.resolve($0.startAtWord, values: values))
      },
      wakeAfter: wakeAfter(values: values, timeSeconds: timeSeconds),
      marqueeElapsedSeconds: marqueeElapsedSeconds(at: timeSeconds),
      conformanceAnimationSpecOrder: document.animationSpecOrder,
      conformancePathIDs: document.pathIDs, conformancePathTweenIDs: document.pathTweenIDs,
      conformanceShaderUniformNames: document.shaderUniformNames,
      conformanceConditionalTraces: document.conditionalTraces)
    if canReuseStaticSnapshot(timeSeconds: timeSeconds, wallClock: wallClock) {
      staticSnapshotCache = StaticSnapshotCache(
        measuredComponents: measuredComponents, snapshot: snapshot)
    }
    return snapshot
  }

  /// AndroidX `ImpulseOperation`: waiting before the window, initializing on the first frame inside
  /// it, processing on every later frame inside it, idle after it, which re-arms the first frame.
  /// Advanced once per frame time, so resolving a frame twice does not consume the first frame.
  private func advanceImpulses(values: [Int: Float], timeSeconds: TimeInterval) {
    guard !document.impulses.isEmpty, lastImpulseFrameTime != timeSeconds else { return }
    lastImpulseFrameTime = timeSeconds
    let time = Float(timeSeconds)
    for (index, impulse) in document.impulses.enumerated() {
      let startAt = NativeSwiftFloatExpression.resolve(impulse.startAtWord, values: values)
      let duration = NativeSwiftFloatExpression.resolve(impulse.durationWord, values: values)
      if time < startAt {
        impulsePhases[index] = .waiting
      } else if time <= startAt + duration {
        impulsePhases[index] = impulseInitialPass[index, default: true] ? .initialize : .process
        impulseInitialPass[index] = false
      } else {
        impulsePhases[index] = .idle
        impulseInitialPass[index] = true
      }
    }
  }

  /// Whether a command drawn inside an impulse belongs to the impulse's phase at this frame.
  private func impulseAllows(_ gate: ParsedImpulseGate?) -> Bool {
    guard let gate else { return true }
    let phase = impulsePhases[gate.impulse] ?? .idle
    if gate.segment == document.impulses[gate.impulse].processSegment { return phase == .process }
    return phase == .initialize
  }

  private func wakeAfter(values: [Int: Float], timeSeconds: TimeInterval) -> TimeInterval? {
    var requests = document.wakeWords.compactMap { word -> TimeInterval? in
      let seconds = NativeSwiftFloatExpression.resolve(word, values: values)
      return seconds.isFinite && seconds >= 0 ? TimeInterval(seconds) : nil
    }
    for (index, impulse) in document.impulses.enumerated() {
      switch impulsePhases[index] ?? .idle {
      case .waiting:
        let startAt = NativeSwiftFloatExpression.resolve(impulse.startAtWord, values: values)
        requests.append(max(TimeInterval(startAt) - timeSeconds, 0))
      case .initialize, .process: requests.append(0)
      case .idle: break
      }
    }
    return requests.min()
  }

  /// Advances retained particle systems to this frame and returns one system's current state.
  /// Rendering a particle loop uses the same retained state; this accessor additionally makes the
  /// behaviour observable to the native conformance host without exposing decoder internals.
  @_spi(Conformance) public func particleSnapshot(id: Int, timeSeconds: TimeInterval = 0) throws
    -> NativeSwiftParticleSystemSnapshot?
  {
    stateLock.lock()
    defer { stateLock.unlock() }
    try resolveUnlessResolved(at: timeSeconds)
    advanceParticles(timeSeconds: timeSeconds)
    return particleSystems[id]?.snapshot
  }

  /// Advances retained particle systems to this frame and returns every decoded system in stable
  /// wire order. Conformance documents can declare more than one system, so callers that observe
  /// particle state must not depend on dictionary iteration order.
  @_spi(Conformance) public func particleSnapshots(timeSeconds: TimeInterval = 0) throws
    -> [NativeSwiftParticleSystemSnapshot]
  {
    stateLock.lock()
    defer { stateLock.unlock() }
    try resolveUnlessResolved(at: timeSeconds)
    advanceParticles(timeSeconds: timeSeconds)
    return document.particleDefinitions.compactMap { particleSystems[$0.id]?.snapshot }
  }

  /// A tap on `componentID`; see `gesture`.
  public func click(componentID: Int, timeSeconds: TimeInterval) throws -> [NativeSwiftEvent]? {
    stateLock.lock()
    defer { stateLock.unlock() }
    return try gesture(.tap, componentID: componentID, sample: nil, timeSeconds: timeSeconds)
  }

  /// Effects emitted while resolving the latest frame. Draining prevents layout refinements from
  /// replaying a sound or haptic that belongs to the frame already presented.
  public func takeFrameEffects() -> [NativeSwiftEvent] {
    stateLock.lock()
    defer { stateLock.unlock() }
    let events = pendingFrameEffects
    pendingFrameEffects.removeAll()
    return events
  }

  /// Dispatches every legacy document-space click area containing the point, in wire order, with
  /// the bounds the last resolution left (`RcPlayerState.executeClickAreasAt`).
  ///
  /// - Parameter timeSeconds: Unused; input acts on the values the last resolution left.
  public func clickAreas(x: Float, y: Float, timeSeconds: TimeInterval) throws -> [NativeSwiftEvent]? {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard x.isFinite, y.isFinite, !document.clickAreas.isEmpty else { return nil }
    var events: [NativeSwiftEvent] = []
    for area in document.clickAreas {
      let left = NativeSwiftFloatExpression.resolve(area.left, values: floats)
      let top = NativeSwiftFloatExpression.resolve(area.top, values: floats)
      let right = NativeSwiftFloatExpression.resolve(area.right, values: floats)
      let bottom = NativeSwiftFloatExpression.resolve(area.bottom, values: floats)
      if x >= left && x < right && y >= top && y < bottom {
        events.append(.actionWithMetadata(id: area.id, metadata: texts[area.metadataID] ?? ""))
      }
    }
    return events.isEmpty ? nil : events
  }

  /// Runs the component's actions for `kind` against the values the last resolution left, without
  /// resolving again (`RcPlayerState.executeClick`): a value derived from an earlier action's write
  /// reads as the last frame left it.
  ///
  /// - Parameter timeSeconds: Unused; input acts on the values the last resolution left.
  public func gesture(
    _ kind: NativeSwiftGestureKind, componentID: Int,
    sample: NativeSwiftPointerSample? = nil, timeSeconds: TimeInterval
  ) throws -> [NativeSwiftEvent]? {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard let node = document.nodes[componentID], node.isClickable,
      node.accessibility?.isEnabled != false, let actions = node.actions[kind]
    else { return nil }
    return try execute(actions)
  }

  /// Delivers a host event to the document's `EVENT_ACTION` handlers.
  ///
  /// AndroidX leaves routing to the host: a handler is registered with whatever router the host
  /// installed for its event type, and the core ships none. This is the plain router: every handler
  /// for `type`, in document order. A handler takes the event when its filter equals `metadata`: it
  /// writes `data` into its data ids, slot by slot (a zero id skips a slot), then, unless its
  /// condition evaluates to zero, runs its actions and reports its flags. After a handler writes
  /// its data the steps run again, so the condition and actions read the values derived from it.
  public func dispatchEvent(
    type: Int, metadata: Int, data: [Float] = [], timeSeconds: TimeInterval
  ) throws -> NativeSwiftEventDispatch {
    stateLock.lock()
    defer { stateLock.unlock() }
    var handledFlags: [Int] = []
    var events: [NativeSwiftEvent] = []
    for handler in document.eventHandlers where handler.type == type && handler.filter == metadata {
      var wroteData = false
      for (id, value) in zip(handler.dataIDs, data) where id != 0 && value.isFinite {
        invalidateResolution()
        overrideFloat(id, value)
        wroteData = true
      }
      // The values derived from the event's data are worked out before its condition reads them.
      if wroteData { try reapplyResolutionSteps() }
      if let condition = handler.condition {
        let result = try NativeSwiftFloatExpression.evaluate(
          condition, values: floats, opcode: NativeSwiftWireOpcode.eventAction,
          offset: handler.offset)
        guard result != 0 else { continue }
      }
      events += try execute(handler.actions)
      handledFlags.append(handler.flags)
    }
    return NativeSwiftEventDispatch(handledFlags: handledFlags, events: events)
  }

  /// Runs every `RUN_ACTION` body that follows a component, once per frame instant, as the
  /// reference does each time it paints the document. Returns whether any action ran, so the caller
  /// can apply the steps again (`reapplyResolutionSteps`) and draw the derived values this frame.
  private func runFrameActions(timeSeconds: TimeInterval) throws -> Bool {
    guard !document.runActions.isEmpty, lastRunActionFrameTime != timeSeconds else { return false }
    lastRunActionFrameTime = timeSeconds
    pendingFrameEffects.removeAll()
    var ran = false
    for runAction in document.runActions where runAction.followsComponent {
      guard !runAction.actions.isEmpty else { continue }
      // A RUN_ACTION holds no host action (the decoder drops them), so nothing reaches the host.
      pendingFrameEffects += try execute(runAction.actions)
      ran = true
    }
    return ran
  }

  /// Runs a gesture's, handler's or frame's actions in order against the live store, as the
  /// reference's `executeActionsUnchecked` does: each write is visible to the actions after it, and
  /// a value write is an override the document's own expression at that id then leaves alone.
  private func execute(_ actions: [ParsedAction]) throws -> [NativeSwiftEvent] {
    // A sequence can mutate state before a later expression fails. Invalidate before executing the
    // first action so an error cannot leave a stale static snapshot cached over that mutation.
    invalidateResolution()
    var events: [NativeSwiftEvent] = []
    for action in actions {
      switch action {
      case .integerExpression(let targetID, let expressionID):
        if let expression = document.integerExpressions[expressionID] {
          overrideInteger(targetID, try evaluateInteger(expression))
        } else if let value = integers[expressionID] {
          overrideInteger(targetID, value)
        }
      case .floatExpression(let targetID, let expressionID):
        // The last expression declared at the id, eased by its animation at the last resolution's
        // instant, as Kotlin's `floatExpressions` map and runtime give it.
        guard let expression = document.floatExpressions[expressionID] else { continue }
        overrideFloat(targetID, try evaluatedFloat(expression))
      case .integerValue(let targetID, let value):
        overrideInteger(targetID, value)
      case .floatValue(let targetID, let value):
        let resolved = NativeSwiftFloatExpression.resolve(value, values: floats)
        if resolved.isFinite { overrideFloat(targetID, resolved) }
      case .textValue(let targetID, let textID):
        if let text = currentText(textID) { setText(targetID, text) }
      case .hostAction(let id):
        events.append(.action(id: id))
      case .hostMetadataAction(let id, let textID):
        events.append(.actionWithMetadata(id: id, metadata: currentText(textID) ?? ""))
      case .haptic(let type):
        if type >= 0 { events.append(.haptic(type: type)) }
      case .playSound(let id):
        if let sound = document.sounds[id] {
          switch sound {
          case .data(let data): events.append(.playSound(id: id, data: data))
          case .expression(let parameters):
            if let data = NativeSwiftToneSynthesizer.synthesize(
              parameters: parameters, values: floats)
            {
              events.append(.playSound(id: id, data: data))
            }
          }
        }
      case .named(let action):
        guard let name = texts[action.nameTextID] else { continue }
        let value: NativeSwiftActionValue
        switch action.valueType {
        case NativeSwiftHostActionValueType.none: value = .none
        case NativeSwiftHostActionValueType.float: value = .float(floats[action.valueID] ?? 0)
        case NativeSwiftHostActionValueType.integer: value = .integer(integers[action.valueID] ?? 0)
        case NativeSwiftHostActionValueType.string: value = .text(currentText(action.valueID) ?? "")
        default: continue
        }
        events.append(.namedAction(name: name, value: value))
      }
    }
    return events
  }

  /// Text `id` as it stands now, for an action that sends or stores it
  /// (`RcPlayerState.currentText`).
  ///
  /// A derived text is recomputed by its producer, inputs first, because its inputs may have moved
  /// since the last frame. O(the texts `id` depends on), walked with an explicit stack.
  private func currentText(_ id: Int) -> String? {
    guard textOverrides[id] == nil, document.textProducers[id] != nil else { return texts[id] }
    var order: [ParsedTextOperation] = []
    var visited: Set<Int> = []
    var stack: [(id: Int, expanded: Bool)] = [(id, false)]
    while let (next, expanded) = stack.popLast() {
      guard textOverrides[next] == nil, let producer = document.textProducers[next] else {
        continue
      }
      if expanded {
        order.append(producer)
        continue
      }
      guard visited.insert(next).inserted else { continue }
      stack.append((next, true))
      for input in producer.textInputs(idLists: document.idLists) where !visited.contains(input) {
        stack.append((input, false))
      }
    }
    for producer in order { applyTextOperation(producer) }
    return texts[id]
  }

  /// Every value the document holds at `timeSeconds`, after one resolution at that instant.
  ///
  /// Resolves as `snapshot` does, minus impulses and frame effects, so a probe after a `snapshot`
  /// at the same instant is a second pass: values that read their previous ones move again.
  @_spi(Conformance) public func probeValues(
    timeSeconds: TimeInterval, wallClock: NativeSwiftWallClock? = nil
  ) throws -> NativeSwiftProbeValues {
    stateLock.lock()
    defer { stateLock.unlock() }
    try resolveFrameAndRunDocument(timeSeconds: timeSeconds, wallClock: wallClock)
    // The resolution updated retained state, so a previously cached static frame is no longer a
    // valid result for a later snapshot.
    staticSnapshotCache = nil
    return NativeSwiftProbeValues(floats: floats, integers: integers, texts: texts, colors: colors)
  }

  /// Every value the session holds now, without resolving: what the last resolution, and any host
  /// write or input since, left in the live store.
  @_spi(Conformance) public func currentValues() -> NativeSwiftProbeValues {
    stateLock.lock()
    defer { stateLock.unlock() }
    return NativeSwiftProbeValues(floats: floats, integers: integers, texts: texts, colors: colors)
  }

  /// Resolves a static or dynamic float list for conformance state probes.
  @_spi(Conformance) public func probeFloatList(
    id: Int, dynamic: Bool, timeSeconds: TimeInterval
  ) throws -> [Float]? {
    stateLock.lock()
    defer { stateLock.unlock() }
    try resolveUnlessResolved(at: timeSeconds)
    return floatList(id: id, staticFirst: !dynamic, values: floats)
  }

  /// A float list as `values` resolves it: a static `DataListFloat` (when `staticFirst`) with its
  /// updates applied, or else a `DynamicFloatList`, zero-filled to its length.
  private func floatList(id: Int, staticFirst: Bool, values: [Int: Float]) -> [Float]? {
    // A host's float array replaces whatever list the document keeps at the id, static or dynamic,
    // as the Kotlin player's `floatValues` reads its override first.
    if let override = floatArrayOverrides[id] { return override }
    if staticFirst {
      if var result = document.floatLists[id]?.map({
        NativeSwiftFloatExpression.resolve($0, values: values)
      }) {
        for update in document.floatListUpdates[id] ?? [] {
          let index = nativeSwiftClampedInt(NativeSwiftFloatExpression.resolve(update.index, values: values))
          if result.indices.contains(index) {
            result[index] = NativeSwiftFloatExpression.resolve(update.value, values: values)
          }
        }
        return result
      }
      // The corpus calls both backing forms "data" lists. Fall through to the dynamic allocation
      // form when no literal DataListFloat with this id exists.
    }
    guard let list = document.dynamicFloatLists[id] else { return nil }
    let length = nativeSwiftClampedInt(NativeSwiftFloatExpression.resolve(list.lengthWord, values: values))
    guard (0...NativeSwiftDocumentDecoder.maximumFloatListValues).contains(length) else {
      return nil
    }
    var result = Array(repeating: Float(0), count: length)
    for update in list.updates {
      let index = nativeSwiftClampedInt(NativeSwiftFloatExpression.resolve(update.index, values: values))
      if result.indices.contains(index) {
        result[index] = NativeSwiftFloatExpression.resolve(update.value, values: values)
      }
    }
    return result
  }

  /// Returns a matrix in the exact shape the wire declares (nine values for a 3x3 constant,
  /// sixteen for a 4x4 constant or expression).
  @_spi(Conformance)
  public func probeMatrix(id: Int, timeSeconds: TimeInterval) throws -> [Float]? {
    stateLock.lock()
    defer { stateLock.unlock() }
    try resolveUnlessResolved(at: timeSeconds)
    if let constant = document.matrixConstants[id] { return constant.values }
    return document.matrixExpressions[id].flatMap {
      NativeSwiftMatrixExpression.evaluate4x4($0, values: floats)
    }
  }

  /// The slot a document's named variable occupies, or nil when it declared no such name.
  ///
  /// A probe that names a variable the document never declared is genuinely unobservable; one that
  /// addresses a numeric slot the document left empty is an observation, and the caller has to keep
  /// the two apart.
  @_spi(Conformance)
  public func namedVariableID(_ name: String) -> Int? { namedVariable(for: name)?.id }

  /// The value of each named variable a write has set since this session opened — the host's,
  /// or one of the document's own actions — by the name the document declares it under, sorted by
  /// name. A variable only the document's computations fill (a `TextFromFloat` output, an integer
  /// expression) is left out, as is one whose type no host can write; one written back to its
  /// initial value is reported.
  ///
  /// It is what a host carries into a new session over the same document, with
  /// ``restoreNamedValue(_:forDeclaredName:)``, so the new session starts from the newest value
  /// either side wrote rather than from the document's initial ones. An integer carries the float
  /// view a float write gave the same id, which the integer view holds only truncated.
  @_spi(RemoteComposeController)
  public func writtenNamedValues() -> [(name: String, value: NativeSwiftNamedValue)] {
    stateLock.lock()
    defer { stateLock.unlock() }
    var written: [(name: String, value: NativeSwiftNamedValue)] = []
    for (name, variable) in namedVariableDeclarations.variables.sorted(by: { $0.key < $1.key }) {
      let id = variable.id
      switch variable.type {
      case NativeSwiftNamedVariableType.int:
        if writtenIntegerAndTextIDs.contains(id) || writtenFloatIDs.contains(id),
          let value = integers[id]
        {
          let float = writtenFloatIDs.contains(id) ? floats[id] : nil
          written.append((name, .integer(value, float: float)))
        }
      case NativeSwiftNamedVariableType.float:
        if writtenFloatIDs.contains(id), let value = floats[id] {
          written.append((name, .float(value)))
        }
      case NativeSwiftNamedVariableType.string:
        if writtenIntegerAndTextIDs.contains(id), let value = texts[id] {
          written.append((name, .text(value)))
        }
      case NativeSwiftNamedVariableType.color:
        // Only a host writes a colour by name; the document's own are restored by its bytes.
        if hostSetColors.contains(id), let value = colors[id] {
          written.append((name, .color(value)))
        }
      case NativeSwiftNamedVariableType.long:
        if let value = longOverrides[id] { written.append((name, .long(value))) }
      case NativeSwiftNamedVariableType.floatArray:
        if let value = floatArrayOverrides[id] { written.append((name, .floatArray(value))) }
      default:
        break
      }
    }
    return written
  }

  /// Writes `value` into the named variable the document declares as exactly `name` — no
  /// `USER:` resolution, so a value read by ``writtenNamedValues()`` lands in the variable it came
  /// from even where the document declares both `foo` and `USER:foo`. The value must fit the
  /// variable as a host write must; returns whether it was written.
  @_spi(RemoteComposeController)
  @discardableResult
  public func restoreNamedValue(_ value: NativeSwiftNamedValue, forDeclaredName name: String)
    -> Bool
  {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard let variable = namedVariableDeclarations.variables[name] else { return false }
    return write(value, to: variable)
  }

  /// Writes a host's or a carried value into `variable`, once the declarations accept it.
  private func write(_ value: NativeSwiftNamedValue, to variable: ParsedNamedVariable) -> Bool {
    guard NativeSwiftNamedVariableDeclarations.accepts(value, by: variable) else { return false }
    let id = variable.id
    // `RcPlayerState.setNamedValue`: the value holds until the document writes the id again, and
    // a write to a system variable claims it from the player's clock.
    switch value {
    case .float(let value):
      setFloat(id, value)
      writtenFloatIDs.insert(id)
    case .text(let value):
      setText(id, value)
    case .color(let argb):
      colors[id] = argb
      hostSetColors.insert(id)
    case .integer(let value, let float):
      writtenIntegerAndTextIDs.insert(id)
      claimIfSystem(id)
      if let float {
        // A carried value restores both views exactly as the previous session left them.
        integers[id] = value
        floats[id] = float
        writtenFloatIDs.insert(id)
      } else if setInteger(id, value) {
        writtenFloatIDs.remove(id)
      }
    case .long(let value):
      longOverrides[id] = value
    case .floatArray(let values):
      floatArrayOverrides[id] = values
    }
    invalidateResolution()
    return true
  }

  /// The authoring API addresses user values without the wire format's `USER:` prefix. Keep the
  /// wire spelling available too, so hosts can use either form when a document names it explicitly.
  private func namedVariable(for name: String) -> ParsedNamedVariable? {
    namedVariableDeclarations.variable(for: name)
  }

  /// Writes one float slot by id, for a gesture that moves a document's own value — a scroll's
  /// offset is addressed by id rather than by name.
  @discardableResult
  public func setFloat(_ value: Float, forID id: Int) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard value.isFinite else { return false }
    setFloat(id, value)
    writtenFloatIDs.insert(id)
    invalidateResolution()
    return true
  }

  public func setFloat(_ value: Float, for name: String) -> Bool {
    set(.float(value), for: name)
  }

  public func setString(_ value: String, for name: String) -> Bool {
    set(.text(value), for: name)
  }

  public func setColor(_ value: UInt32, for name: String) -> Bool {
    set(.color(value), for: name)
  }

  /// Updates a named RemoteInt. RemoteBoolean uses this same wire type, with `0` and `1` standing
  /// for false and true respectively.
  public func setInteger(_ value: Int, for name: String) -> Bool {
    set(.integer(value), for: name)
  }

  /// Updates a named long — an instant in epoch milliseconds, which a time attribute reads.
  public func setLong(_ value: Int64, for name: String) -> Bool {
    set(.long(value), for: name)
  }

  /// Replaces the list a named float array holds. The values must be finite, and no more than a
  /// document's float list may hold.
  public func setFloatArray(_ values: [Float], for name: String) -> Bool {
    set(.floatArray(values), for: name)
  }

  /// Restores the named variable `name` to the value the document recorded, discarding the
  /// host's override — the inverse of the `set*` methods, as the Kotlin player's
  /// `clearNamedValue` is. The recorded value is the document's own, never one a host seeded when
  /// the session opened (0 where it recorded none). A named system variable goes back to the
  /// player's clock. A document action's override at the id stays, as Kotlin's clear keeps it.
  ///
  /// Returns whether `name` is a variable a host can write; a name the document does not declare
  /// (or declares as an image) is ignored, and clearing twice changes nothing.
  @discardableResult
  public func clearNamedValue(_ name: String) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard let variable = namedVariable(for: name) else { return false }
    let id = variable.id
    switch variable.type {
    case NativeSwiftNamedVariableType.float, NativeSwiftNamedVariableType.int:
      // `RcPlayerState.clearNamedValue`: dropping the claim lets the next resolution load the
      // clock; any other id gets the recorded value through the host's write path.
      if NativeSwiftSystemVariables.isSystem(id), !documentClaimedSystemIDs.contains(id) {
        claimedSystemIDs.remove(id)
      } else if variable.type == NativeSwiftNamedVariableType.float {
        setFloat(id, recordedFloats[id] ?? 0)
      } else {
        setInteger(id, recordedIntegers[id] ?? 0)
      }
      writtenFloatIDs.remove(id)
      writtenIntegerAndTextIDs.remove(id)
    case NativeSwiftNamedVariableType.string:
      // Removing the override, not writing the document's text back: a written-back text would be
      // a fresh override the document could never change again.
      textOverrides[id] = nil
      texts[id] = document.texts[id]
      writtenIntegerAndTextIDs.remove(id)
    case NativeSwiftNamedVariableType.color:
      // No longer the host's, so the document's dark palette applies to it again.
      colors[id] = document.colors[id]
      hostSetColors.remove(id)
    case NativeSwiftNamedVariableType.long:
      longOverrides[id] = nil
    case NativeSwiftNamedVariableType.floatArray:
      floatArrayOverrides[id] = nil
    default:
      return false
    }
    invalidateResolution()
    return true
  }

  /// A host write by the name a host addresses it with; see `namedVariable(for:)`.
  private func set(_ value: NativeSwiftNamedValue, for name: String) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard let variable = namedVariable(for: name) else { return false }
    return write(value, to: variable)
  }

  public func returnCustomText(_ value: String, componentID: Int, propertyID: Int) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard value.utf8.count <= NativeSwiftDocumentDecoder.maximumStringBytes,
      let node = document.nodes[componentID], node.kind == .custom,
      let property = node.custom?.properties.first(where: {
        $0.type == propertyID && $0.dataType == NativeSwiftCustomPropertyType.textReturn
      })
    else { return false }
    setText(property.valueBits, value)
    invalidateResolution()
    return true
  }

  public func returnCustomFloat(_ value: Float, componentID: Int, propertyID: Int) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard value.isFinite, let node = document.nodes[componentID], node.kind == .custom,
      let property = node.custom?.properties.first(where: {
        $0.type == propertyID && $0.dataType == NativeSwiftCustomPropertyType.floatReturn
      }),
      let targetID = NativeSwiftFloatExpression.referenceID(
        UInt32(bitPattern: Int32(property.valueBits)))
    else { return false }
    setFloat(targetID, value)
    writtenFloatIDs.insert(targetID)
    invalidateResolution()
    return true
  }

  private func canReuseStaticSnapshot(
    timeSeconds: TimeInterval, wallClock: NativeSwiftWallClock?
  ) -> Bool {
    (!document.needsWallClockRefresh || wallClock == nil)
      && (wallClock == nil || document.timeAttributes.isEmpty)
      && !document.needsContinuousFrames
      && !document.hasMarquee
      && document.impulses.isEmpty
      && document.particleOperations.isEmpty
      && document.runActions.isEmpty
      && document.frameEffects.isEmpty
      && !visibilityTracker.hasActiveTransition
      && !floatAnimationRuntimes.contains {
        !overriddenFloats.contains($0.key) && $0.value.isAnimating(at: Float(timeSeconds))
      }
  }

  private func resolve(
    _ node: ParsedNode, values: [Int: Float], colors resolvedColors: [Int: UInt32],
    timeSeconds: TimeInterval, visibilityOverride: Int? = nil, stateBranchActive: Int? = nil
  ) throws -> NativeSwiftNodeSnapshot {
    let text: NativeSwiftTextSnapshot?
    if let source = node.text {
      // `size > 0` used to be a parse-time guard. It still holds, but a computed size has no value
      // to check until here, so the check moved with it rather than being dropped.
      let size = try resolvedFloat(
        source.sizeWord, NativeSwiftWireField.textSize, values: values, positive: true)
      let weight = resolveOptionalFloat(source.weightWord, values: values) ?? 400
      text = NativeSwiftTextSnapshot(
        value: texts[source.textID] ?? "",
        colorARGB: source.colorID.flatMap { resolvedColors[$0] } ?? source.colorARGB,
        size: size,
        style: source.style,
        weight: min(max(weight, 1), 1_000),
        familyID: source.familyID,
        familyName: texts[source.familyID],
        alignment: source.alignment,
        overflow: source.overflow,
        maximumLines: source.maximumLines,
        autosize: try source.autosize.map { range in
          // An unset bound is -1 on the wire (or absent). The Compose player's defaults: 400 for
          // the maximum, 4 for the minimum, and the minimum never above the maximum.
          var minimum: Float = -1
          if let word = range.minimumWord {
            minimum = try resolvedFloat(word, "autosize minimum", values: values)
          }
          var maximum: Float = -1
          if let word = range.maximumWord {
            maximum = try resolvedFloat(word, "autosize maximum", values: values)
          }
          let resolvedMaximum = maximum > 0 ? maximum : 400
          return NativeSwiftTextAutosize(
            minimumFontSize: min(minimum > 0 ? minimum : 4, resolvedMaximum),
            maximumFontSize: resolvedMaximum)
        },
        fontSettings: fontSettings(source, values: values),
        sizeIsDensityTyped: NativeSwiftTextSnapshot.isDensityTypedFontSize(
          source.sizeWord, densityBehavior: document.densityBehavior))
    } else {
      text = nil
    }

    let custom: NativeSwiftCustomSnapshot?
    if let source = node.custom {
      guard let config = texts[source.configID] else {
        throw NativeSwiftCoreError.malformed(
          offset: source.offset,
          reason: "Custom component \(node.componentID) has no config text")
      }
      let properties = source.properties.map { property in
        let floatValue =
          property.dataType == NativeSwiftCustomPropertyType.floatProperty
          ? NativeSwiftFloatExpression.resolve(
            UInt32(bitPattern: Int32(property.valueBits)), values: values)
          : 0
        let integerValue: Int
        let textValue: String?
        switch property.dataType {
        case NativeSwiftCustomPropertyType.stringProperty:
          integerValue = property.valueBits
          textValue = texts[property.valueBits]
        case NativeSwiftCustomPropertyType.colorIDProperty:
          integerValue = Int(Int32(bitPattern: resolvedColors[property.valueBits] ?? 0))
          textValue = nil
        default:
          integerValue = property.valueBits
          textValue = nil
        }
        return NativeSwiftCustomPropertySnapshot(
          id: property.type, dataType: property.dataType, floatValue: floatValue,
          integerValue: integerValue, textValue: textValue)
      }
      custom = NativeSwiftCustomSnapshot(config: config, properties: properties)
    } else {
      custom = nil
    }

    // A state layout's branches take their visibility from the layout, not a transition.
    var visibility =
      visibilityOverride ?? node.visibilityID.map { resolvedVisibility(of: $0) }
      ?? NativeSwiftVisibility.visible
    var visibilityTransition: NativeSwiftVisibilityTransitionSnapshot?
    if visibilityOverride == nil, node.visibilityID != nil,
      let (timeline, state) = visibilityTracker.observe(
        id: node.componentID, visibility: visibility, spec: node.animationSpec,
        specID: node.animationSpecID, timeSeconds: timeSeconds)
    {
      visibility = state.layoutVisibility
      let functionID =
        timeline.isEntering ? timeline.spec.enterFunctionID : timeline.spec.exitFunctionID
      visibilityTransition = NativeSwiftVisibilityTransitionSnapshot(
        from: timeline.from, to: timeline.to, phase: state.phase, progress: state.progress,
        functionID: functionID,
        function: document.functions[functionID].map {
          NativeSwiftVisibilityFunction(
            function: $0, values: values, integers: integers, colors: resolvedColors,
            texts: texts, matrices: document.matrixExpressions, progress: state.progress,
            componentID: node.componentID)
        })
    }

    let maximumWidth = try resolvedFloat(
      node.maximumWidthWord, NativeSwiftWireField.maximumWidth, values: values)
    let maximumHeight = try resolvedFloat(
      node.maximumHeightWord, NativeSwiftWireField.maximumHeight, values: values)
    let cornerRadii = try node.cornerRadiusWords.map {
      try resolvedFloat($0, NativeSwiftWireField.cornerRadius, values: values)
    }
    let cornerRadius = cornerRadii.max() ?? 0

    let resolvedWidth = try resolvedDimension(
      node.widthWord, type: stateLayoutDimension(node, isWidth: true), NativeSwiftWireField.width,
      values: values)
    let resolvedHeight = try resolvedDimension(
      node.heightWord, type: stateLayoutDimension(node, isWidth: false),
      NativeSwiftWireField.height,
      values: values)

    return NativeSwiftNodeSnapshot(
      kind: node.kind,
      componentKind: node.componentKind,
      isCanvasContent: node.isCanvasContent,
      componentID: node.componentID,
      children: try resolvedChildren(
        of: node, values: values, colors: resolvedColors, timeSeconds: timeSeconds,
        stateBranchActive: stateBranchActive),
      commands: try node.commands.compactMap { command -> NativeSwiftDrawCommandSnapshot? in
        guard impulseAllows(command.impulseGate) else { return nil }
        return try command.resolve(
          values: values, integers: integers, colors: resolvedColors, texts: texts,
          matrices: document.matrixExpressions)
      },
      isClickable: node.isClickable,
      supportedGestures: node.actions.keys.sorted { $0.rawValue < $1.rawValue },
      accessibility: node.accessibility.map {
        NativeSwiftAccessibilitySnapshot(
          contentDescriptionID: $0.contentDescriptionID, role: $0.role, textID: $0.textID,
          stateDescriptionID: $0.stateDescriptionID, mode: $0.mode,
          contentDescription: texts[$0.contentDescriptionID], text: texts[$0.textID],
          stateDescription: texts[$0.stateDescriptionID], isEnabled: $0.isEnabled,
          isClickable: $0.isClickable)
      },
      // A state layout takes the active child's size whatever the document asks for, matching the
      // reference: a fill modifier on the container itself is dropped rather than honoured, which
      // is what makes the container's own background and border cover the branch and not the
      // parent.
      widthType: resolvedWidth.type,
      widthValue: resolvedWidth.value,
      heightType: resolvedHeight.type,
      heightValue: resolvedHeight.value,
      // A state layout takes the active child's size, so its own padding is dropped with its fill:
      // the reference reports an 80x80 container for an 80x80 child behind a 20pt padding modifier,
      // not 120x120, and the child sits at the container's origin. Keeping the padding made the
      // container's background and border cover 40 points more than the branch.
      padding: node.stateIndexID != nil
        ? NativeSwiftInsets()
        : NativeSwiftInsets(
          left: try resolvedFloat(
            node.paddingWords.left, NativeSwiftWireField.paddingLeft, values: values),
          top: try resolvedFloat(
            node.paddingWords.top, NativeSwiftWireField.paddingTop, values: values),
          right: try resolvedFloat(
            node.paddingWords.right, NativeSwiftWireField.paddingRight, values: values),
          bottom: try resolvedFloat(
            node.paddingWords.bottom, NativeSwiftWireField.paddingBottom, values: values)),
      minimumWidth: try resolvedFloat(
        node.minimumWidthWord, NativeSwiftWireField.minimumWidth, values: values),
      maximumWidth: maximumWidth > 1_000_000 ? -1 : maximumWidth,
      minimumHeight: try resolvedFloat(
        node.minimumHeightWord, NativeSwiftWireField.minimumHeight, values: values),
      maximumHeight: maximumHeight > 1_000_000 ? -1 : maximumHeight,
      cornerRadius: cornerRadius,
      clipsToBounds: node.clipsToBounds,
      graphicsLayer: node.graphicsLayer.isEmpty
        ? nil
        : NativeSwiftGraphicsLayerSnapshot(
          // AndroidX's `GraphicsLayerModifierOperation` ids (#423): 5/6 are the transform origin,
          // 7/8 the translation, 11 the alpha, and 13 the compositing strategy. An absent origin
          // is the declared 0, the top-left, as AndroidX's embedded player and
          // `RcGraphicsLayerValues` in `rc-player-runtime` read it.
          scaleX: node.graphicsLayer[NativeSwiftGraphicsLayerAttribute.scaleX] ?? 1,
          scaleY: node.graphicsLayer[NativeSwiftGraphicsLayerAttribute.scaleY] ?? 1,
          translationX: node.graphicsLayer[NativeSwiftGraphicsLayerAttribute.translationX] ?? 0,
          translationY: node.graphicsLayer[NativeSwiftGraphicsLayerAttribute.translationY] ?? 0,
          rotationZ: node.graphicsLayer[NativeSwiftGraphicsLayerAttribute.rotationZ] ?? 0,
          alpha: node.graphicsLayer[NativeSwiftGraphicsLayerAttribute.alpha] ?? 1,
          transformOriginX: node.graphicsLayer[NativeSwiftGraphicsLayerAttribute.transformOriginX]
            ?? 0,
          transformOriginY: node.graphicsLayer[NativeSwiftGraphicsLayerAttribute.transformOriginY]
            ?? 0,
          compositingStrategy: node.graphicsLayer[NativeSwiftGraphicsLayerAttribute.compositingStrategy]
            .map { value in
              value.isFinite ? nativeSwiftClampedInt(value) : NativeSwiftCompositingStrategy.auto
            } ?? NativeSwiftCompositingStrategy.auto),
      offsetX: node.offsetXWord.map { NativeSwiftFloatExpression.resolve($0, values: values) } ?? 0,
      offsetY: node.offsetYWord.map { NativeSwiftFloatExpression.resolve($0, values: values) } ?? 0,
      zIndex: node.zIndexWord.map { NativeSwiftFloatExpression.resolve($0, values: values) } ?? 0,
      visibility: visibility,
      backgroundARGB: node.backgroundColorID.flatMap { resolvedColors[$0] } ?? node.backgroundARGB,
      borderARGB: node.borderColorID.flatMap { resolvedColors[$0] } ?? node.borderARGB,
      borderWidth: try resolvedFloat(
        node.borderWidthWord, NativeSwiftWireField.borderWidth, values: values),
      horizontalPositioning: node.horizontalPositioning,
      verticalPositioning: node.verticalPositioning,
      animationID: node.animationID,
      animationSpecID: node.animationSpecID,
      animationSpec: node.animationSpec,
      spacing: try resolvedFloat(node.spacingWord, "spacing", values: values),
      stateIndex: node.stateIndexID.flatMap { indexID in
        // Clamped against the *branches*, not the wrapper: the normal shape wraps every
        // alternative in one content node, and clamping against that would always report 0.
        let branches = stateBranches(of: node)
        return branches.isEmpty
          ? nil : min(max(integerVariable(indexID), 0), branches.count - 1)
      },
      flowMaximumItems: node.flowMaximumItems,
      flowMaximumLines: node.flowMaximumLines,
      isCollapsible: node.isCollapsible,
      collapsiblePriority: try node.collapsiblePriorityWord.map {
        try resolvedFloat($0, NativeSwiftWireField.collapsiblePriority, values: values)
      },
      collapsiblePriorityOrientation: node.collapsiblePriorityOrientation,
      scrollDirection: node.scrollDirection,
      scrollPositionID: node.scrollPositionWord.flatMap {
        NativeSwiftFloatExpression.referenceID($0)
      },
      scrollOffset: node.scrollPositionWord.map {
        NativeSwiftFloatExpression.resolve($0, values: values)
      } ?? 0,
      scrollMaximum: node.scrollMaximumWord.map {
        NativeSwiftFloatExpression.resolve($0, values: values)
      } ?? 0,
      // Refused as the Kotlin player's support check refuses it: every float finite and the
      // velocity positive. A zero velocity would hold the content still while the document kept
      // asking for frames.
      marquee: try node.marqueeVelocityWord.map {
        NativeSwiftMarqueeSnapshot(
          iterations: node.marqueeIterations, animationMode: node.marqueeAnimationMode,
          repeatDelayMillis: try resolvedFloat(
            node.marqueeRepeatDelayWord, NativeSwiftWireField.marqueeRepeatDelay, values: values),
          initialDelayMillis: try resolvedFloat(
            node.marqueeInitialDelayWord, NativeSwiftWireField.marqueeInitialDelay, values: values),
          spacing: try resolvedFloat(
            node.marqueeSpacingWord, NativeSwiftWireField.marqueeSpacing, values: values),
          velocity: try resolvedFloat(
            $0, NativeSwiftWireField.marqueeVelocity, values: values, positive: true))
      },
      text: text,
      custom: custom,
      layoutComputes: node.layoutComputes.map { resolvedLayoutCompute($0, values: values) },
      visibilityTransition: visibilityTransition)
  }

  /// A component's `LayoutComputeOperation` with the frame's values and lists its body reads, so a
  /// host's layout pass can run it without reaching back into the session.
  private func resolvedLayoutCompute(
    _ compute: ParsedLayoutCompute, values: [Int: Float]
  ) -> NativeSwiftLayoutComputeSnapshot {
    var readValues: [Int: Float] = [:]
    var listIDs: Set<Int> = [compute.boundsID]
    for step in compute.steps {
      for id in step.referencedIDs {
        if let value = values[id] { readValues[id] = value }
        if id & NativeSwiftIDRegion.mask == NativeSwiftIDRegion.array { listIDs.insert(id) }
      }
      if case .update(let listID, _, _) = step { listIDs.insert(listID) }
    }
    var lists: [Int: [Float]] = [:]
    for id in listIDs {
      if let list = floatList(id: id, staticFirst: true, values: values) { lists[id] = list }
    }
    // A list is dynamic when it is a DynamicFloatList and no static list of the same id shadows
    // it, as `floatList(staticFirst:)` reads it: the reference seeds the component's box into, and
    // applies `UpdateDynamicFloatList` to, only those.
    // A list a host overrides is not dynamic: the body reads the host's values, and an update to
    // the document's list underneath stays invisible while the override stands, as on the Kotlin
    // player.
    let dynamicListIDs = listIDs.filter {
      document.dynamicFloatLists[$0] != nil && document.floatLists[$0] == nil
        && floatArrayOverrides[$0] == nil
    }
    return NativeSwiftLayoutComputeSnapshot(
      type: compute.type, boundsID: compute.boundsID, animateChanges: compute.animateChanges,
      steps: compute.steps, dynamicListIDs: dynamicListIDs, lists: lists, values: readValues)
  }

  /// A state layout's branches, unwrapping the bare content node they usually share.
  private func stateBranches(of node: ParsedNode) -> [ParsedNode] {
    guard node.children.count == 1, node.children[0].kind == .content,
      !node.children[0].children.isEmpty
    else { return node.children }
    return node.children[0].children
  }

  /// The width or height type a state layout resolves with; every other node keeps its own.
  ///
  /// The reference's `StateLayout` adopts its active child's size, so **its own dimension is
  /// dropped whatever kind it is** — a `FILL` modifier made the container cover the whole parent and
  /// paint its background over the branch, and a fixed one held the container at a size the branch
  /// never had. `interaction_click_button` declares `height(100)` on a container whose branches are
  /// 40 and 80 tall, and the reference reports 40 and then 80. Bounds (`widthIn`/`heightIn`) still
  /// apply: they constrain the child's size rather than replacing it.
  /// A width or height modifier's value. A bare `fillMaxWidth()`/`fillMaxHeight()` writes the
  /// canonical NaN as its fraction, which the reference reads as 1 (`fillFraction()` in
  /// `RcNativeSnapshot.kt`); resolved as an expression reference it would become 0 and be
  /// indistinguishable from an explicit zero fraction, so the raw word is checked here, where it
  /// still exists.
  private func resolveOptionalFloat(_ word: UInt32, values: [Int: Float]) -> Float? {
    if let id = NativeSwiftFloatExpression.referenceID(word) {
      guard let value = values[id], value.isFinite else { return nil }
      return value
    }
    let value = Float(bitPattern: word)
    return value.isFinite ? value : nil
  }

  private func resolvedDimension(
    _ word: UInt32, type: Int, _ field: String, values: [Int: Float]
  ) throws -> (type: Int, value: Float) {
    if NativeSwiftDimensionType.isFill(type) && word == Float.nan.bitPattern {
      return (type, 1)
    }
    if type == NativeSwiftDimensionType.weight {
      guard let value = resolveOptionalFloat(word, values: values), value > 0 else {
        return (NativeSwiftDimensionType.wrap, 0)
      }
      return (type, value)
    }
    return (type, try resolvedFloat(word, field, values: values))
  }

  private func stateLayoutDimension(_ node: ParsedNode, isWidth: Bool) -> Int {
    guard node.stateIndexID != nil else { return isWidth ? node.widthType : node.heightType }
    return NativeSwiftDimensionType.wrap
  }

  /// A node's children, with a state layout's inactive branches marked GONE.
  ///
  /// A `StateLayout` shows one child — the one its index integer selects — and keeps the others
  /// GONE so they can take part in a transition. Laid out as a plain box it showed *every* branch
  /// stacked, which is the single largest remaining raster difference on the native lane.
  private func resolvedChildren(
    of node: ParsedNode, values: [Int: Float], colors resolvedColors: [Int: UInt32],
    timeSeconds: TimeInterval, stateBranchActive: Int? = nil
  ) throws -> [NativeSwiftNodeSnapshot] {
    // A state layout's own index decides which of *its* branches is shown, and the branches are
    // usually wrapped in the same bare content node every other container uses.
    if let indexID = node.stateIndexID, !node.children.isEmpty {
      let wrapper = node.children.count == 1 && node.children[0].kind == .content
        ? node.children[0] : nil
      let branches = stateBranches(of: node)
      guard !branches.isEmpty else {
        return try node.children.map {
          try resolve($0, values: values, colors: resolvedColors, timeSeconds: timeSeconds)
        }
      }
      let active = min(max(integerVariable(indexID), 0), branches.count - 1)
      if let wrapper {
        return [
          try resolve(
            wrapper, values: values, colors: resolvedColors, timeSeconds: timeSeconds,
            stateBranchActive: active)
        ]
      }
      return try node.children.enumerated().map { position, child in
        try resolve(
          child, values: values, colors: resolvedColors, timeSeconds: timeSeconds,
          visibilityOverride: position == active
            ? NativeSwiftVisibility.visible : NativeSwiftVisibility.gone)
      }
    }
    return try node.children.enumerated().map { position, child in
      try resolve(
        child, values: values, colors: resolvedColors, timeSeconds: timeSeconds,
        visibilityOverride: stateBranchActive.map {
          position == $0 ? NativeSwiftVisibility.visible : NativeSwiftVisibility.gone
        })
    }
  }

  /// Resolves a float field that a document may either state outright or compute.
  ///
  /// A literal word is its own bit pattern, so `resolve` is a strict generalisation of the eager
  /// `Float` these fields used to hold; a NaN-boxed word is a reference into `values`. Validation
  /// that used to run while parsing runs here, because a computed field has nothing to validate
  /// until it resolves — and failing here is what keeps a garbage value from reaching UIKit.
  /// A `CoreText`'s font settings with their tags and values resolved. A tag with no text, or a
  /// value that does not resolve to a number, is dropped, as the Compose player drops it.
  private func fontSettings(
    _ source: ParsedText, values: [Int: Float]
  ) -> [NativeSwiftFontSetting] {
    var settings: [NativeSwiftFontSetting] = []
    for (tagID, word) in zip(source.fontSettingTagIDs, source.fontSettingValueWords) {
      guard let tag = texts[tagID], !tag.isEmpty else { continue }
      let value = NativeSwiftFloatExpression.resolve(word, values: values)
      if value.isFinite { settings.append(NativeSwiftFontSetting(tag: tag, value: value)) }
    }
    return settings
  }

  private func resolvedFloat(
    _ word: UInt32, _ field: String, values: [Int: Float], positive: Bool = false
  ) throws -> Float {
    let value = NativeSwiftFloatExpression.resolve(word, values: values)
    guard value.isFinite else {
      throw NativeSwiftCoreError.malformed(offset: 0, reason: "\(field) resolved to \(value)")
    }
    guard !positive || value > 0 else {
      throw NativeSwiftCoreError.malformed(
        offset: 0, reason: "\(field) resolved to \(value), which is not positive")
    }
    return value
  }

  // MARK: - Writes (`RcPlayerState.storeFloat`, `setFloat`, `setInteger`, the overrides)

  /// A float write: the float view, and the integer view under the same id, truncated toward zero
  /// and clamped to 32 bits — `RcPlayerState.storeFloat`, as AndroidX
  /// `RemoteComposeState.updateFloat` publishes both. Integer expressions, a state layout's index
  /// and visibility read the integer view.
  private func storeFloat(_ id: Int, _ value: Float) {
    floats[id] = value
    integers[id] = nativeSwiftIntegerView(value)
  }

  /// `RcPlayerState.setFloat`: a float write that also claims a system id, so the player's clock
  /// no longer replaces what was written there.
  private func setFloat(_ id: Int, _ value: Float) {
    claimIfSystem(id)
    storeFloat(id, value)
  }

  private func claimIfSystem(_ id: Int) {
    if NativeSwiftSystemVariables.isSystem(id) { claimedSystemIDs.insert(id) }
  }

  /// An integer write — `RcPlayerState.setInteger`, as AndroidX `RemoteComposeState.updateInteger`:
  /// nothing for the integer the id already holds, else both views, the float being the integer.
  /// Returns whether the id changed.
  @discardableResult
  private func setInteger(_ id: Int, _ value: Int) -> Bool {
    guard integers[id] != value else { return false }
    integers[id] = value
    floats[id] = Float(value)
    return true
  }

  /// A document action's float write (`RcPlayerState.overrideFloat`): it sticks, as a float
  /// expression at the id no longer runs.
  private func overrideFloat(_ id: Int, _ value: Float) {
    overriddenFloats.insert(id)
    setFloat(id, value)
    writtenFloatIDs.insert(id)
  }

  /// A document action's integer write (`RcPlayerState.overrideInteger`): it sticks, as an integer
  /// expression at the id no longer runs. A float variable at a document float carries it as its
  /// float (`writtenNamedValues`).
  private func overrideInteger(_ id: Int, _ value: Int) {
    overriddenIntegers.insert(id)
    writtenIntegerAndTextIDs.insert(id)
    guard setInteger(id, value) else { return }
    if floatConstantIDs.contains(id) {
      writtenFloatIDs.insert(id)
    } else {
      writtenFloatIDs.remove(id)
    }
  }

  /// `RcPlayerState.setText`: a write that outlives the frame, put back over the document's text by
  /// every resolution.
  private func setText(_ id: Int, _ value: String) {
    textOverrides[id] = value
    texts[id] = value
    writtenIntegerAndTextIDs.insert(id)
  }

  /// `RcPlayerState.setColor`: a document write, ignored where a host set the colour by name.
  private func setColor(_ id: Int, _ argb: UInt32) {
    guard !hostSetColors.contains(id) else { return }
    colors[id] = argb
  }

  /// An integer expression's variable (`RcPlayerState.integerVariable`): the integer view, else an
  /// unclaimed system id's float truncated — the clock and the density are loaded as floats only —
  /// else 0.
  private func integerVariable(_ id: Int) -> Int {
    if let value = integers[id] { return value }
    guard NativeSwiftSystemVariables.isSystem(id), !claimedSystemIDs.contains(id),
      let value = floats[id]
    else { return 0 }
    return nativeSwiftIntegerView(value)
  }

  private func evaluateInteger(_ expression: ParsedIntegerExpression) throws -> Int {
    try NativeSwiftIntegerExpression.evaluate(
      mask: expression.mask, tokens: expression.tokens, offset: expression.offset,
      variable: integerVariable)
  }

  /// A data-map entry's integer value: a long entry reads the long (a host's included), truncated
  /// to 32 bits as the Kotlin player's `Long.toInt()` is; the others read the integer.
  private func dataMapInteger(type: Int, valueID: Int) -> Int {
    guard type == NativeSwiftDataMapType.long else { return integers[valueID] ?? 0 }
    return Int(Int32(truncatingIfNeeded: long(valueID) ?? 0))
  }

  /// The long at `id`: a host's, over the document's `LongConstant`.
  private func long(_ id: Int) -> Int64? {
    longOverrides[id] ?? document.longConstants[id]
  }

  /// Whether a `fromArgument` interval reads its argument as now — the host's long at it was
  /// cleared and the document gives it no `LongConstant` — while its instant is a stated one, so the
  /// value moves with the clock: the Kotlin player counts that a clock read
  /// (`RcPlayerState.applyTimeAttribute`). The decoder cannot know it, as a host's long decides it.
  private var measuresFromNowForAMissingArgument: Bool {
    typealias TimeType = NativeSwiftTimeAttributeType
    let fromArgument: Set<Int> = [
      TimeType.fromArgumentSeconds, TimeType.fromArgumentMinutes, TimeType.fromArgumentHours,
    ]
    return document.timeAttributes.contains { attribute in
      fromArgument.contains(attribute.type) && long(attribute.timeID) != nil
        && attribute.argumentIDs.first.map { long($0) == nil } == true
    }
  }

  /// AndroidX `TimeAttribute.paint`: one calendar field or interval, read from an instant.
  ///
  /// The instant is the `LongConstant` the operation names, or the host's wall clock when the
  /// document names none. Fields are read in the wall clock's zone, as the reference reads the
  /// system zone. Month and day of week are zero-based, as they are in the reference. A missing
  /// argument is read as now, as a missing instant is (`TimeAttribute.java:243-244`; the reference
  /// would cast a null and throw, `:259-260`), as the Kotlin player reads it. A value with nothing
  /// to measure from — no wall clock for a `NOW`, `LOAD` or argument-less interval — leaves the
  /// slot unwritten rather than inventing an epoch.
  private func timeAttribute(
    _ attribute: ParsedTimeAttribute, timeSeconds: TimeInterval,
    wallClock: NativeSwiftWallClock?
  ) -> Float? {
    guard let selectedMillis = long(attribute.timeID) ?? wallClock?.epochMillis
    else { return nil }
    let selected = NativeSwiftWallClock(
      epochMillis: selectedMillis,
      offsetSeconds: wallClock?.offsetSeconds(atEpochMillis: selectedMillis) ?? 0)
    let fields = selected.fields
    typealias TimeType = NativeSwiftTimeAttributeType
    // As the reference computes it (`TimeAttribute.java:254-288`): a `long` subtraction, which
    // wraps rather than traps for instants as far apart as Int64.max and Int64.min; seconds in
    // Float (`delta * 1E-3f`), minutes and hours in Double, as the Kotlin player does too.
    func interval(since start: Int64, unit: Double) -> Float {
      let delta = selectedMillis &- start
      return unit == 1 ? Float(delta) * 0.001 : Float(Double(delta) * 0.001 / unit)
    }
    switch attribute.type {
    case TimeType.fromNowSeconds, TimeType.fromNowMinutes, TimeType.fromNowHours:
      guard let now = wallClock?.epochMillis else { return nil }
      let unit: Double = attribute.type == TimeType.fromNowSeconds
        ? 1 : attribute.type == TimeType.fromNowMinutes ? 60 : 3600
      return interval(since: now, unit: unit)
    case TimeType.fromArgumentSeconds, TimeType.fromArgumentMinutes, TimeType.fromArgumentHours:
      guard let argumentID = attribute.argumentIDs.first,
        let argument = long(argumentID) ?? wallClock?.epochMillis
      else { return nil }
      let unit: Double = attribute.type == TimeType.fromArgumentSeconds
        ? 1 : attribute.type == TimeType.fromArgumentMinutes ? 60 : 3600
      return interval(since: argument, unit: unit)
    case TimeType.second: return Float(fields.second)
    case TimeType.minute: return Float(fields.minute)
    case TimeType.hour: return Float(fields.hour)
    case TimeType.dayOfMonth: return Float(fields.dayOfMonth)
    case TimeType.monthValue: return Float(fields.month - 1)
    case TimeType.dayOfWeek: return Float(fields.isoDayOfWeek - 1)
    case TimeType.year: return Float(fields.year)
    case TimeType.fromLoadSeconds:
      // The document loaded `timeSeconds` before the wall clock's instant.
      guard let now = wallClock?.epochMillis else { return nil }
      // In Double too: `Int64(_:)` traps on a non-finite or out-of-range elapsed time.
      let loadMillis = Double(now) - (timeSeconds * 1000).rounded()
      return Float((Double(selectedMillis) - loadMillis) * 0.001)
    case TimeType.dayOfYear: return Float(fields.dayOfYear)
    default: return nil
    }
  }

  // MARK: - Resolution (`RcPlayerState.beginFrame` + `applyLayoutContentStateOperations`)

  /// One resolution at `timeSeconds`: `beginFrame`, every step once in wire order against the live
  /// store, then the measured component values. No fixed point: a step that reads a later step's
  /// output reads the previous resolution's value, as in Kotlin.
  ///
  /// Cost: O(steps + the expression words they evaluate), plus the component-value estimates; the
  /// steps run once more when a component value moved or a step failed waiting for one.
  private func resolveFrame(
    timeSeconds: TimeInterval, wallClock: NativeSwiftWallClock?,
    measuredComponents: [Int: NativeSwiftMeasuredSize]
  ) throws {
    frameTimeSeconds = timeSeconds
    frameWallClock = wallClock
    // Only a resolution that finished counts for `resolveUnlessResolved`.
    resolvedFrameTime = nil
    beginFrame(timeSeconds: timeSeconds, wallClock: wallClock)
    // A step that reads a not-yet-measured component value or a later step's output can fail on a
    // zero divisor; it keeps its previous value and the second pass throws if it still fails.
    let bindsComponentValues = !document.componentValues.isEmpty
    let mayWait = bindsComponentValues || document.floatExpressionsReadForward
    var stepFailedWaiting = false
    for step in document.resolutionSteps {
      do {
        try applyStep(step)
      } catch {
        guard mayWait else { throw error }
        stepFailedWaiting = true
      }
    }
    if bindsComponentValues {
      // Kotlin's settle pass (`RcSettledLayout`) applies the operations again before drawing; here
      // it runs at once, and only when a measurement moved or a step failed waiting.
      if publishComponentValues(measuredComponents) || stepFailedWaiting {
        try reapplyResolutionSteps()
      }
    } else if stepFailedWaiting {
      try reapplyResolutionSteps()
    }
    resolvedFrameTime = timeSeconds
  }

  /// One resolution against the last measurements, then the `RUN_ACTION` bodies and particles,
  /// each followed by the steps once more so derived values are this frame's. With particles that
  /// is twice the steps' cost every frame, three times with run actions too.
  private func resolveFrameAndRunDocument(
    timeSeconds: TimeInterval, wallClock: NativeSwiftWallClock?
  ) throws {
    try resolveFrame(
      timeSeconds: timeSeconds, wallClock: wallClock, measuredComponents: lastMeasuredComponents)
    if try runFrameActions(timeSeconds: timeSeconds) { try reapplyResolutionSteps() }
    if advanceParticles(timeSeconds: timeSeconds) { try reapplyResolutionSteps() }
  }

  /// Every step once more at the same instant, without a new `beginFrame`, as Kotlin's settle and
  /// draw passes apply the operations again after an input moved.
  private func reapplyResolutionSteps() throws {
    for step in document.resolutionSteps { try applyStep(step) }
  }

  /// After a write the steps read (a host or action write, a theme, the density): the cached
  /// static frame is stale, and so is the last resolution for `resolveUnlessResolved`.
  private func invalidateResolution() {
    staticSnapshotCache = nil
    resolvedFrameTime = nil
  }

  /// Resolves at `timeSeconds` for a conformance read unless the last finished resolution ran
  /// there, reusing the last wall clock and measurements so the read does not disturb the document.
  private func resolveUnlessResolved(at timeSeconds: TimeInterval) throws {
    guard resolvedFrameTime != timeSeconds else { return }
    try resolveFrame(
      timeSeconds: timeSeconds, wallClock: frameWallClock,
      measuredComponents: lastMeasuredComponents)
    staticSnapshotCache = nil
  }

  /// `RcPlayerState.beginFrame`: texts reset to the document's plus the written ones, and the
  /// player's variables loaded. The first text write copies the table: O(the document's texts).
  private func beginFrame(timeSeconds: TimeInterval, wallClock: NativeSwiftWallClock?) {
    texts = document.texts
    if !textOverrides.isEmpty { texts.merge(textOverrides) { _, written in written } }
    loadSystemVariables(timeSeconds: timeSeconds, wallClock: wallClock)
  }

  /// `RcPlayerState.loadSystemVariables`: each unclaimed system value as a float only.
  ///
  /// The animation clock is the host's logical timeline, which a capture can hold still. Without a
  /// wall clock the calendar is unset and `CONTINUOUS_SEC` falls back to it, so a document that
  /// animates off it still moves.
  private func loadSystemVariables(timeSeconds: TimeInterval, wallClock: NativeSwiftWallClock?) {
    typealias System = NativeSwiftSystemVariables
    let animationTime = Float(timeSeconds)
    let fields = wallClock?.fields
    let secondsWithinHour = fields.map {
      Float($0.secondOfHour) + Float($0.millisOfSecond) * 0.001
    }
    loadSystem(System.continuousSeconds, secondsWithinHour ?? animationTime)
    loadSystem(System.timeInSeconds, fields.map { Float($0.secondOfHour) })
    loadSystem(System.timeInMinutes, fields.map { Float($0.hour * 60 + $0.minute) })
    loadSystem(System.timeInHours, fields.map { Float($0.hour) })
    loadSystem(System.calendarMonth, fields.map { Float($0.month) })
    loadSystem(System.offsetToUTC, wallClock.map { Float($0.offsetSeconds) })
    loadSystem(System.weekDay, fields.map { Float($0.isoDayOfWeek) })
    loadSystem(System.dayOfMonth, fields.map { Float($0.dayOfMonth) })
    loadSystem(System.dayOfYear, fields.map { Float($0.dayOfYear) })
    loadSystem(System.year, fields.map { Float($0.year) })
    loadSystem(System.animationTime, animationTime)
    loadHostDensity()
    // An integer the player owns, so both views; unset without a wall clock, like the calendar.
    if let wallClock {
      if !claimedSystemIDs.contains(System.epochSecond) {
        setInteger(
          System.epochSecond, Int(NativeSwiftWallClock.floorDiv(wallClock.epochMillis, 1000)))
      }
    } else {
      loadSystem(System.epochSecond, nil)
    }
  }

  /// `RcPlayerState.loadHostDensity`: the density and font size, which the player owes because an
  /// unset one reads 0 and a `RemoteDensity.Host` capture's `([33] 14.0 / [27] / 15.0 *)` would
  /// divide by zero.
  private func loadHostDensity() {
    typealias System = NativeSwiftSystemVariables
    loadSystem(System.density, hostDensity)
    loadSystem(System.fontSize, System.defaultFontSizeSp * hostFontScale * hostDensity)
  }

  /// `RcPlayerState.loadSystem`: a float only, its integer view removed, unless the id is claimed.
  private func loadSystem(_ id: Int, _ value: Float?) {
    guard !claimedSystemIDs.contains(id) else { return }
    floats[id] = value
    integers.removeValue(forKey: id)
  }

  /// One step, as `RcPlayerState.applyContentStateOperation` applies it, except that a lookup with
  /// a missing list, index, map or key keeps its output and a text lookup clamps its index (Kotlin
  /// refuses the document), and `THEME` markers scope nothing (see `setRequestedTheme`).
  private func applyStep(_ step: ParsedResolutionStep) throws {
    switch step {
    case .floatExpression(let expression):
      try applyFloatExpression(expression)
    case .integerExpression(let id, let expression):
      guard !overriddenIntegers.contains(id) else { return }
      setInteger(id, try evaluateInteger(expression))
    case .colorExpression(let expression):
      if let color = color(of: expression) { setColor(expression.outputID, color) }
    case .colorTheme(let id, let light, let dark):
      // Light unless dark is asked for. Kotlin's `applyColorTheme` picks dark for anything but
      // light; this core keeps an unspecified theme light, a decision `setRequestedTheme` records.
      setColor(id, requestedTheme == NativeSwiftTheme.dark ? dark : light)
    case .colorAttribute(let attribute):
      setFloat(
        attribute.outputID, colorAttribute(attribute.type, of: colors[attribute.colorID] ?? 0))
    case .imageSize(let id, let value):
      setFloat(id, value)
    case .idLookup(let lookup):
      // A list that does not exist, or an index outside it, leaves the slot as it was.
      guard let ids = document.idLists[lookup.listID] else { return }
      let position = NativeSwiftFloatExpression.resolve(lookup.index, values: floats)
      let index = nativeSwiftClampedInt(position)
      if ids.indices.contains(index) { setInteger(lookup.outputID, ids[index]) }
    case .dataMapLookup(let lookup):
      try applyDataMapLookup(lookup)
    case .text(let operation):
      applyTextOperation(operation)
    case .textLength(let length):
      // A text nothing produced reads as empty, as the reference's text operations read it.
      setFloat(length.outputID, Float(texts[length.textID]?.utf16.count ?? 0))
    case .timeAttribute(let attribute):
      applyTimeAttribute(attribute)
    case .matrixVectorMath(let operation):
      applyMatrixVectorMath(operation)
    }
  }

  /// A `TIME_ATTRIBUTE` step, never inlined into `applyStep`: the wall clock holds a `TimeZone`,
  /// whose size Apple's Foundation only knows at run time, so inlined it would make every step's
  /// stack frame dynamically sized.
  @inline(never)
  private func applyTimeAttribute(_ attribute: ParsedTimeAttribute) {
    if let value = timeAttribute(
      attribute, timeSeconds: frameTimeSeconds, wallClock: frameWallClock)
    {
      setFloat(attribute.outputID, value)
    } else if frameWallClock == nil {
      // Nothing to measure from without a wall clock: unset, as the calendar is then.
      floats[attribute.outputID] = nil
      integers[attribute.outputID] = nil
    }
  }

  /// `RcPlayerState.applyFloatExpression`: an id a document action wrote is left as written;
  /// otherwise the expression, eased by its animation when it has one, is the id's value.
  private func applyFloatExpression(_ expression: ParsedFloatExpression) throws {
    guard !overriddenFloats.contains(expression.id) else { return }
    setFloat(expression.id, try evaluatedFloat(expression))
  }

  /// The value `expression` gives now: its words over the live floats, eased by its animation at
  /// the resolution's instant when it has one.
  private func evaluatedFloat(_ expression: ParsedFloatExpression) throws -> Float {
    let target = try NativeSwiftFloatExpression.evaluate(
      expression.words, values: floats, opcode: expression.opcode, offset: expression.offset)
    guard expression.animationWords != nil else { return target }
    return try animationRuntime(for: expression).evaluate(
      target: target, at: Float(frameTimeSeconds))
  }

  /// `RcPlayerState.applyDataOperation` for a data-map lookup: the entry the key text names, in its
  /// own type. A key or map that is missing leaves the output as it was.
  private func applyDataMapLookup(_ lookup: ParsedDataMapLookup) throws {
    guard let key = texts[lookup.keyTextID], let entry = document.dataMaps[lookup.mapID]?[key]
    else { return }
    switch entry.type {
    case NativeSwiftDataMapType.string:
      if let value = texts[entry.valueID] { texts[lookup.outputID] = value }
    case NativeSwiftDataMapType.int, NativeSwiftDataMapType.long, NativeSwiftDataMapType.boolean:
      setInteger(lookup.outputID, dataMapInteger(type: entry.type, valueID: entry.valueID))
    case NativeSwiftDataMapType.float:
      storeFloat(lookup.outputID, floats[entry.valueID] ?? 0)
    default:
      throw NativeSwiftCoreError.malformed(offset: lookup.offset, reason: "Unknown data-map type")
    }
  }

  /// `RcPlayerState.applyMatrixVectorMath`. A perspective divide by zero leaves the outputs as
  /// they were. Four small arrays per step and resolution, at most four values each.
  private func applyMatrixVectorMath(_ operation: ParsedMatrixVectorMath) {
    guard let matrix = resolvedMatrix(operation.matrixID, values: floats) else { return }
    // `matrix` is a row-major 4x4.
    func entry(_ row: Int, _ column: Int) -> Float { matrix[row * 4 + column] }
    let input = operation.inputWords.map { NativeSwiftFloatExpression.resolve($0, values: floats) }
    var output = [Float](repeating: 0, count: operation.outputIDs.count)
    if operation.type == NativeSwiftMatrixVectorMathType.multiply {
      for row in output.indices {
        var value = entry(row, 3)
        for column in input.indices { value += entry(row, column) * input[column] }
        output[row] = value
      }
    } else {
      var input4 = [Float](repeating: 0, count: 4)
      input4[3] = 1
      for index in input.indices { input4[index] = input[index] }
      var output4 = [Float](repeating: 0, count: 4)
      for row in 0..<4 {
        for column in 0..<4 { output4[row] += entry(row, column) * input4[column] }
      }
      guard output4[3] != 0 else { return }
      for index in output.indices { output[index] = output4[index] / output4[3] }
    }
    for (outputID, value) in zip(operation.outputIDs, output) { setFloat(outputID, value) }
  }

  /// Publishes each component value from the host's measurement, or this core's own estimate of
  /// the component when there is none, as `RcPlayerState.publishComponentValues` does: stored only
  /// when it moved. Returns whether any moved.
  private func publishComponentValues(
    _ measuredComponents: [Int: NativeSwiftMeasuredSize]
  ) -> Bool {
    var changed = false
    // Subtree estimates are pure in (node, dimension) for one `floats` table, so they are shared
    // across bindings -- a parent and child both bound, or a width and height binding on one node,
    // walk the same subtree. A binding writes `floats`, though, so when any layout word reads a
    // bound value the table is dropped before each binding's estimate instead.
    var estimates: [NativeSwiftEstimateKey: Float] = [:]
    for binding in document.componentValues {
      // Width and height are the only two types the decoder accepts, and the two a host reports.
      let isWidth = binding.type == NativeSwiftComponentValueType.width
      let documentSize = Float(isWidth ? document.width : document.height)
      let value: Float
      let measuredSize = measuredComponents[binding.componentID].map {
        isWidth ? $0.width : $0.height
      }
      if let measuredSize, measuredSize.isFinite, measuredSize >= 0 {
        // A real measurement wins over any estimate; a non-finite or negative one would stick in
        // the live store, so it is ignored.
        value = measuredSize
      } else if let node = document.nodes[binding.componentID] {
        if document.layoutReadsComponentValues { estimates.removeAll(keepingCapacity: true) }
        value = estimatedDimension(
          of: node.parent ?? node, type: binding.type, available: documentSize, values: floats,
          estimates: &estimates)
      } else {
        // Matching the reference player: a binding to a component this document does not describe
        // resolves to the document's own size, rather than leaving the id unset and taking every
        // expression built on it down with it.
        value = documentSize
      }
      guard floats[binding.valueID]?.bitPattern != value.bitPattern else { continue }
      storeFloat(binding.valueID, value)
      changed = true
    }
    return changed
  }

  private func resolvedMatrix(_ id: Int, values: [Int: Float]) -> [Float]? {
    if let constant = document.matrixConstants[id] {
      if constant.values.count == 16 { return constant.values }
      guard constant.values.count == 9 else { return nil }
      let v = constant.values
      return [v[0], v[1], 0, v[2], v[3], v[4], 0, v[5], v[6], v[7], v[8], 0, 0, 0, 0, 1]
    }
    return document.matrixExpressions[id].flatMap {
      NativeSwiftMatrixExpression.evaluate4x4($0, values: values)
    }
  }

  /// The retained runtime for an expression that carries animation words.
  private func animationRuntime(
    for expression: ParsedFloatExpression
  ) throws -> NativeSwiftFloatAnimationRuntime {
    if let existing = floatAnimationRuntimes[expression.id] { return existing }
    let runtime = try NativeSwiftFloatAnimationRuntime(
      animationWords: expression.animationWords ?? [], offset: expression.offset)
    floatAnimationRuntimes[expression.id] = runtime
    return runtime
  }

  /// Returns whether the systems advanced, which they do once per frame instant.
  @discardableResult
  private func advanceParticles(timeSeconds: TimeInterval) -> Bool {
    guard !document.particleOperations.isEmpty, lastParticleFrameTime != timeSeconds else {
      return false
    }
    lastParticleFrameTime = timeSeconds
    for definition in document.particleDefinitions where particleSystems[definition.id] == nil {
      particleSystems[definition.id] = NativeSwiftParticleSystemRuntime(
        definition: definition, values: floats)
    }
    particleCompareFired = false
    // Loops and comparisons run in wire order, each seeing what the ones before it left. A
    // particle register is published through `setFloat`, as the reference's runtime does: both
    // numeric views, over whatever an earlier write left there.
    for operation in document.particleOperations {
      switch operation {
      case .loop(let loop):
        guard let system = particleSystems[loop.id] else { continue }
        system.advance(loop: loop, baseValues: floats)
        // The ordinary resolver sees the latest particle while drawing a loop body. UIKit's loop
        // renderer replaces these for each child; publishing the last value is still the
        // reference's externally observable register state when no loop child is painted.
        for (index, variableID) in system.variableIDs.enumerated() {
          setFloat(variableID, system.particles.last?[index] ?? 0)
        }
      case .compare(let compare):
        guard let system = particleSystems[compare.id] else { continue }
        let result = system.compare(compare, baseValues: floats)
        particleCompareFired = particleCompareFired || result.fired
        // As with a loop, the registers keep the last particle the comparison loaded. Its body is
        // drawn once, against them, whether or not anything passed; the reference draws it once
        // per particle (or pair) that passes.
        guard let published = result.published else { continue }
        for (index, variableID) in system.variableIDs.enumerated() {
          setFloat(variableID, published[index])
        }
      }
    }
    staticSnapshotCache = nil
    return true
  }

  /// A `TextSubtext` length that takes the rest of the text (`TextSubtext.java:141`).
  private static let subtextToEnd = -1

  /// `RcPlayerState.applyTextOperation`: one text producer against the live store. A text not
  /// (yet) produced reads as empty.
  private func applyTextOperation(_ operation: ParsedTextOperation) {
    switch operation {
    case .fromFloat(let conversion):
      let value = NativeSwiftFloatExpression.resolve(conversion.value, values: floats)
      texts[conversion.outputID] = NativeSwiftTextFormatter.format(
        value, digitsBefore: conversion.digitsBefore, digitsAfter: conversion.digitsAfter,
        flags: conversion.flags)
    case .merge(let merge):
      texts[merge.outputID] = (texts[merge.leftID] ?? "") + (texts[merge.rightID] ?? "")
    case .lookupInt(let lookup):
      guard let ids = document.idLists[lookup.listID], !ids.isEmpty else { return }
      let index = (integers[lookup.indexID] ?? 0).clamped(to: ids.indices)
      texts[lookup.outputID] = texts[ids[index]] ?? ""
    case .lookup(let lookup):
      guard let ids = document.idLists[lookup.listID], !ids.isEmpty else { return }
      let position = NativeSwiftFloatExpression.resolve(lookup.index, values: floats)
      let index = nativeSwiftClampedInt(position).clamped(to: ids.indices)
      texts[lookup.outputID] = texts[ids[index]] ?? ""
    case .transform(let transform):
      resolveTextTransform(transform, values: floats)
    case .subtext(let subtext):
      // O(the text's length) per resolution, as the text itself is rebuilt each one.
      let units = Array((texts[subtext.textID] ?? "").utf16)
      let startPosition = NativeSwiftFloatExpression.resolve(subtext.start, values: floats)
      let start = nativeSwiftClampedInt(startPosition).clamped(to: 0...units.count)
      let length = nativeSwiftClampedInt(
        NativeSwiftFloatExpression.resolve(subtext.length, values: floats))
      // Clamp against the remaining units before adding, so a saturated length cannot overflow.
      let end =
        length == Self.subtextToEnd
        ? units.count : start + length.clamped(to: 0...(units.count - start))
      texts[subtext.outputID] = String(decoding: units[start..<end], as: UTF16.self)
    }
  }

  /// The protocol's slicing coordinates are UTF-16 code-unit offsets, as in Android's String.
  /// Decode the selected units directly instead of stepping Swift character indices, which would
  /// move differently for emoji and combining sequences.
  private func resolveTextTransform(_ transform: ParsedTextTransform, values: [Int: Float]) {
    let source = texts[transform.textID] ?? ""
    let units = Array(source.utf16)
    let start = max(0, nativeSwiftClampedInt(NativeSwiftFloatExpression.resolve(transform.start, values: values)))
    let requestedLength = nativeSwiftClampedInt(NativeSwiftFloatExpression.resolve(transform.length, values: values))
    let startOffset = min(start, units.count)
    let remaining = units.count - startOffset
    let length = requestedLength <= 0 ? remaining : min(requestedLength, remaining)
    let selected = String(decoding: units[startOffset..<(startOffset + length)], as: UTF16.self)
    switch transform.operation {
    case NativeSwiftTextTransformOperation.lowercase: texts[transform.outputID] = selected.lowercased()
    case NativeSwiftTextTransformOperation.uppercase: texts[transform.outputID] = selected.uppercased()
    case NativeSwiftTextTransformOperation.trim:
      texts[transform.outputID] = selected.trimmingCharacters(in: .whitespacesAndNewlines)
    case NativeSwiftTextTransformOperation.capitalizeWords:
      var startsWord = true
      texts[transform.outputID] = selected.reduce(into: "") { result, character in
        result += startsWord ? String(character).uppercased() : String(character)
        startsWord = character.isWhitespace
      }
    case NativeSwiftTextTransformOperation.capitalizeFirst:
      var result = ""
      var capitalized = false
      for character in selected {
        if !capitalized && !character.isWhitespace {
          result += String(character).uppercased()
          capitalized = true
        } else {
          result.append(character)
        }
      }
      texts[transform.outputID] = result
    default: texts[transform.outputID] = selected
    }
  }

  /// Visibility as the protocol encodes it, including its override bits.
  ///
  /// Above 15 the value is a mask -- OVERRIDE_GONE 16, OVERRIDE_VISIBLE 32, OVERRIDE_INVISIBLE 64 --
  /// and the plain 0/1/2 meanings apply only below that. The order matters and is the reference's:
  /// visible wins over gone, gone over invisible, and anything unrecognised is gone rather than
  /// visible, so an unknown state hides a component instead of drawing it in an undefined one.
  private func resolvedVisibility(of id: Int) -> Int {
    // An unset integer reads 0, and 0 is GONE -- not visible. That is the reference's behaviour and
    // the corpus asserts it: `column_child_visibility` binds three children to integers the document
    // never assigns, and expects all three GONE while their unmodified ancestors stay VISIBLE.
    // Defaulting to visible instead looks safer and is wrong; a component whose visibility nobody
    // has decided is hidden, not shown.
    let value = integers[id] ?? NativeSwiftVisibility.gone
    if value >= NativeSwiftVisibility.overrideGone {
      if value & NativeSwiftVisibility.overrideVisible == NativeSwiftVisibility.overrideVisible {
        return NativeSwiftVisibility.visible
      }
      if value & NativeSwiftVisibility.overrideGone == NativeSwiftVisibility.overrideGone {
        return NativeSwiftVisibility.gone
      }
      if value & NativeSwiftVisibility.overrideInvisible == NativeSwiftVisibility.overrideInvisible {
        return NativeSwiftVisibility.invisible
      }
      return NativeSwiftVisibility.gone
    }
    switch value {
    case NativeSwiftVisibility.visible: return NativeSwiftVisibility.visible
    case NativeSwiftVisibility.gone: return NativeSwiftVisibility.gone
    case NativeSwiftVisibility.invisible: return NativeSwiftVisibility.invisible
    default: return NativeSwiftVisibility.gone
    }
  }

  private func colorAttribute(_ type: Int, of color: UInt32) -> Float {
    let red = Float((color >> 16) & 0xff) / AndroidXColorMath.maximum
    let green = Float((color >> 8) & 0xff) / AndroidXColorMath.maximum
    let blue = Float(color & 0xff) / AndroidXColorMath.maximum
    let maximum = max(red, green, blue)
    let minimum = min(red, green, blue)
    let delta = maximum - minimum
    switch type {
    case NativeSwiftColorAttributeType.hue:
      let sector: Float
      if maximum == minimum { sector = 0 }
      else if maximum == red { sector = (green - blue) / delta }
      else if maximum == green { sector = (blue - red) / delta + 2 }
      else { sector = (red - green) / delta + 4 }
      var hue = (sector * 60).truncatingRemainder(dividingBy: 360)
      if hue < 0 { hue += 360 }
      return hue / 360
    case NativeSwiftColorAttributeType.saturation: return maximum == minimum ? 0 : delta / maximum
    case NativeSwiftColorAttributeType.brightness: return maximum
    case NativeSwiftColorAttributeType.red: return red
    case NativeSwiftColorAttributeType.green: return green
    case NativeSwiftColorAttributeType.blue: return blue
    default: return Float((color >> 24) & 0xff) / AndroidXColorMath.maximum
    }
  }

  /// `RcPlayerState.applyColorExpression`: the colour an expression computes from the live
  /// colours and floats, or nil for a mode the decoder would have refused.
  private func color(of expression: ParsedColorExpression) -> UInt32? {
    typealias Mode = NativeSwiftColorExpressionMode
    let mode = expression.modeAndAlpha & 0xff
    func float(_ word: Int) -> Float {
      NativeSwiftFloatExpression.resolve(UInt32(bitPattern: Int32(word)), values: floats)
    }
    switch mode {
    case Mode.colorColorInterpolate...Mode.idIDInterpolate:
      // The interpolation modes are two bits: `idColorInterpolate` marks the first colour an id,
      // `colorIDInterpolate` the second, and `idIDInterpolate` both.
      /// The live colour at `word` when `isID`, else `word` as a literal ARGB colour.
      func colorOperand(_ word: Int, isID: Bool) -> UInt32 {
        isID ? colors[word] ?? 0 : UInt32(bitPattern: Int32(word))
      }
      let first = colorOperand(expression.first, isID: mode & Mode.idColorInterpolate != 0)
      let second = colorOperand(expression.second, isID: mode & Mode.colorIDInterpolate != 0)
      return interpolateColor(first, second, tween: float(expression.third))
    case Mode.hsv...Mode.idARGB:
      let alpha: Float =
        switch mode {
        case Mode.hsv: Float(expression.alphaField) / AndroidXColorMath.maximum
        case Mode.argb: Float(expression.alphaField) / AndroidXColorMath.argbAlphaScale
        default: NativeSwiftFloatExpression.resolve(expression.alphaReferenceWord, values: floats)
        }
      let (first, second, third) =
        (float(expression.first), float(expression.second), float(expression.third))
      return mode == Mode.hsv
        ? hsvColor(alpha: alpha, hue: first, saturation: second, brightness: third)
        : argbColor(alpha: alpha, red: first, green: second, blue: third)
    default: return nil
    }
  }

  /// AndroidX `Utils.interpolateColor`, as the Kotlin player's `RcColorEvaluator.interpolate`
  /// computes it: each colour channel mixed in linear light (gamma 2.2, in Double), alpha mixed
  /// straight, and every result truncated to a byte, not rounded.
  private func interpolateColor(_ first: UInt32, _ second: UInt32, tween: Float) -> UInt32 {
    if tween.isNaN || tween == 0 { return first }
    if tween == 1 { return second }
    func linearChannel(_ color: UInt32, shift: UInt32) -> Float {
      let channel = Float((color >> shift) & 0xff) / AndroidXColorMath.maximum
      return Float(pow(Double(channel), AndroidXColorMath.gamma))
    }
    func truncatedByte(_ value: Float) -> UInt32 {
      // `Float.toInt()`: NaN is 0, and the clamp bounds the rest.
      guard !value.isNaN else { return 0 }
      return UInt32(value.clamped(to: 0...AndroidXColorMath.maximum))
    }
    /// `from` moved `tween` of the way to `to`.
    func mix(_ from: Float, _ to: Float) -> Float { from + tween * (to - from) }
    func mixedChannel(_ shift: UInt32) -> UInt32 {
      let mixed = mix(linearChannel(first, shift: shift), linearChannel(second, shift: shift))
      let encoded = Float(pow(Double(mixed), 1 / AndroidXColorMath.gamma))
      return truncatedByte(encoded * AndroidXColorMath.maximum)
    }
    let firstAlpha = Float(first >> 24) / AndroidXColorMath.maximum
    let secondAlpha = Float(second >> 24) / AndroidXColorMath.maximum
    let alpha = truncatedByte(mix(firstAlpha, secondAlpha) * AndroidXColorMath.maximum)
    return alpha << 24 | mixedChannel(16) << 16 | mixedChannel(8) << 8 | mixedChannel(0)
  }

  /// A colour byte, clamped rather than converted.
  ///
  /// `Int(value)` traps for a non-finite or out-of-range float, and a document is free to compute a
  /// channel from expressions this player cannot bound — a structure-aware mutant found exactly
  /// that. A colour is not worth failing a frame over, so a non-finite channel saturates instead.
  private func argbColor(alpha: Float, red: Float, green: Float, blue: Float) -> UInt32 {
    func byte(_ value: Float) -> UInt32 {
      guard value.isFinite else { return value > 0 ? UInt32(AndroidXColorMath.maximum) : 0 }
      return UInt32((value.clamped(to: 0...1) * AndroidXColorMath.maximum).rounded())
    }
    return byte(alpha) << 24 | byte(red) << 16 | byte(green) << 8 | byte(blue)
  }

  private func hsvColor(
    alpha: Float, hue: Float, saturation: Float, brightness: Float
  ) -> UInt32 {
    guard hue.isFinite, saturation.isFinite, brightness.isFinite else {
      return argbColor(alpha: alpha, red: 0, green: 0, blue: 0)
    }
    // Wrapped into [0, 1) before the sector is taken, because `Int(hue * 6)` traps on a hue a
    // document computed beyond Float's integral range.
    let wrapped = hue - floorf(hue)
    let section = Int(wrapped * 6)
    let fraction = wrapped * 6 - Float(section)
    let p = brightness * (1 - saturation)
    let q = brightness * (1 - fraction * saturation)
    let t = brightness * (1 - (1 - fraction) * saturation)
    let rgb: (Float, Float, Float)
    switch section {
    case 0: rgb = (brightness, t, p)
    case 1: rgb = (q, brightness, p)
    case 2: rgb = (p, brightness, t)
    case 3: rgb = (p, q, brightness)
    case 4: rgb = (t, p, brightness)
    case 5: rgb = (brightness, p, q)
    default: rgb = (0, 0, 0)
    }
    return argbColor(alpha: alpha, red: rgb.0, green: rgb.1, blue: rgb.2)
  }

  /// A node's estimated width or height, memoised in `estimates`.
  ///
  /// The estimate is a pure function of the node, the dimension, `available` (fixed per dimension)
  /// and `values`, so a caller may keep `estimates` for as long as `values` does not change.
  private func estimatedDimension(
    of node: ParsedNode, type: Int, available: Float, values: [Int: Float],
    estimates: inout [NativeSwiftEstimateKey: Float]
  ) -> Float {
    let key = NativeSwiftEstimateKey(node: ObjectIdentifier(node), type: type)
    if let cached = estimates[key] { return cached }
    let estimate = uncachedEstimatedDimension(
      of: node, type: type, available: available, values: values, estimates: &estimates)
    estimates[key] = estimate
    return estimate
  }

  private func uncachedEstimatedDimension(
    of node: ParsedNode, type: Int, available: Float, values: [Int: Float],
    estimates: inout [NativeSwiftEstimateKey: Float]
  ) -> Float {
    // Measurement runs before the final resolution pass and must not throw: an unresolvable field
    // reads as zero here and is rejected properly by `resolvedFloat` when the snapshot is built.
    func float(_ word: UInt32) -> Float {
      let value = NativeSwiftFloatExpression.resolve(word, values: values)
      return value.isFinite ? value : 0
    }
    let dimensionType = type == NativeSwiftComponentValueType.width ? node.widthType : node.heightType
    let dimensionWord = type == NativeSwiftComponentValueType.width ? node.widthWord : node.heightWord
    let dimensionValue = float(dimensionWord)
    if dimensionType == NativeSwiftDimensionType.exact || dimensionType == NativeSwiftDimensionType.exactDp {
      return max(dimensionValue, 0)
    }
    if NativeSwiftDimensionType.isFill(dimensionType) {
      // A bare fill writes the canonical NaN, which `float` would resolve to 0; the reference
      // reads it as a fraction of 1.
      let fraction = dimensionWord == Float.nan.bitPattern ? 1 : max(dimensionValue, 0)
      return ancestorDimension(
        of: node, type: type, available: available, values: values, estimates: &estimates)
        * fraction
    }
    // A fill child contributes nothing to a wrapping parent's intrinsic size: the parent decides
    // the child's size, not the other way round. Including one used to make a wrap box that
    // contains a fill canvas measure the whole document, because the fill's own estimate resolved
    // to `available`.
    let children = flattenedChildren(of: node, values: values).filter {
      !NativeSwiftDimensionType.isFill(
        type == NativeSwiftComponentValueType.width ? $0.widthType : $0.heightType)
    }
    var childDimensions: [Float] = []
    childDimensions.reserveCapacity(children.count)
    for child in children {
      childDimensions.append(
        estimatedDimension(
          of: child, type: type, available: available, values: values, estimates: &estimates))
    }
    let intrinsic: Float
    if let text = node.text {
      if type == NativeSwiftComponentValueType.width {
        intrinsic = Float(texts[text.textID]?.count ?? 0) * float(text.sizeWord) * 0.6
      } else {
        intrinsic = float(text.sizeWord) * 1.2
      }
    } else if type == NativeSwiftComponentValueType.width {
      intrinsic = node.kind == .row ? childDimensions.reduce(0, +) : childDimensions.max() ?? 0
    } else {
      intrinsic =
        node.kind == .column
        ? childDimensions.reduce(0, +)
          + float(node.spacingWord) * Float(max(childDimensions.count - 1, 0))
        : childDimensions.max() ?? 0
    }
    let padding =
      type == NativeSwiftComponentValueType.width
      ? float(node.paddingWords.left) + float(node.paddingWords.right)
      : float(node.paddingWords.top) + float(node.paddingWords.bottom)
    let minimum = type == NativeSwiftComponentValueType.height ? float(node.minimumHeightWord) : 0
    return max(intrinsic + padding, minimum)
  }

  /// The size a fill resolves to: the nearest ancestor that has one, not the document.
  ///
  /// A fill's size is its parent's, so a chain of transparent wrappers and fills has to be walked
  /// up until something determinate is found. Returning `available` at the first fill is what made
  /// an icon inside a 52-unit button measure the 454-unit canvas; the reference measures the
  /// component the layout actually gave it. Falls back to the document when no ancestor decides.
  private func ancestorDimension(
    of node: ParsedNode, type: Int, available: Float, values: [Int: Float],
    estimates: inout [NativeSwiftEstimateKey: Float]
  ) -> Float {
    func float(_ word: UInt32) -> Float {
      let value = NativeSwiftFloatExpression.resolve(word, values: values)
      return value.isFinite ? value : 0
    }
    var current = node.parent
    var depth = 0
    while let candidate = current, depth < 64 {
      let dimensionType =
        type == NativeSwiftComponentValueType.width ? candidate.widthType : candidate.heightType
      let dimensionValue = float(
        type == NativeSwiftComponentValueType.width ? candidate.widthWord : candidate.heightWord)
      if dimensionType == NativeSwiftDimensionType.exact || dimensionType == NativeSwiftDimensionType.exactDp {
        return max(dimensionValue, 0)
      }
      if !NativeSwiftDimensionType.isFill(dimensionType) {
        let intrinsic = estimatedDimension(
          of: candidate, type: type, available: available, values: values,
          estimates: &estimates)
        if intrinsic > 0 { return intrinsic }
      }
      current = candidate.parent
      depth += 1
    }
    return available
  }

  /// Flattens a bare content wrapper into its parent for measurement.
  ///
  /// The padding test runs on resolved values, not on words: a wrapper whose padding is computed
  /// and comes out zero is just as bare as one that says `0`, and comparing the encoded words
  /// would keep it — and so measure a row's grandchildren as one child's maximum rather than
  /// their sum.
  private func flattenedChildren(of node: ParsedNode, values: [Int: Float]) -> [ParsedNode] {
    func isZero(_ word: UInt32) -> Bool {
      NativeSwiftFloatExpression.resolve(word, values: values) == 0
    }
    return node.children.flatMap { child in
      if child.kind == .content, child.widthType == NativeSwiftDimensionType.wrap, child.heightType == NativeSwiftDimensionType.wrap,
        isZero(child.paddingWords.left), isZero(child.paddingWords.top),
        isZero(child.paddingWords.right), isZero(child.paddingWords.bottom)
      {
        return flattenedChildren(of: child, values: values)
      }
      return [child]
    }
  }
}

/// Memo key for `estimatedDimension`: one parsed node's width or height estimate.
struct NativeSwiftEstimateKey: Hashable {
  let node: ObjectIdentifier
  let type: Int
}

extension Comparable {
  /// The value, or the nearer end of `range` when it lies outside.
  fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}

extension Int {
  /// The index nearest to the value within non-empty `indices`.
  fileprivate func clamped(to indices: Range<Int>) -> Int {
    precondition(!indices.isEmpty, "no index to clamp to")
    return clamped(to: indices.lowerBound...(indices.upperBound - 1))
  }
}

/// The colour arithmetic constants AndroidX's `Utils` and `ColorExpression` use.
private enum AndroidXColorMath {
  /// A channel's largest byte, which a normalised channel is scaled by (`Utils.java:253`).
  static let maximum: Float = 255
  /// The display gamma an interpolation mixes in linear light under (`Utils.java:253`).
  static let gamma = 2.2
  /// The fixed-point scale of `ARGB` mode's alpha, in the mode word's high half
  /// (`ColorExpression.java:464`).
  static let argbAlphaScale: Float = 1024
}
