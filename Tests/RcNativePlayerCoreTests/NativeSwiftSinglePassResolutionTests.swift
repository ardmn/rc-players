import Foundation
import Testing

@testable @_spi(Conformance) @_spi(RemoteComposeController) import RcNativePlayerCore

/// Value-resolution tests of the Kotlin player and AndroidX that had no Swift counterpart, ported
/// to the session ahead of a resolver that runs one wire-order pass as `RcPlayerState` does. Each
/// test names the test it ports; the value asserted is Kotlin's, from that Kotlin test or, for an
/// AndroidX case or an extension of a Kotlin one, from `RcValueOrderReferenceTest`. Where the
/// session gives something else today the assertion sits in a `withKnownIssue` that says what
/// differs. Values a frame produces are read from what the snapshot drew, not from
/// `probeValues`, which resolves again on its own.
///
/// The cases `NativeSwiftValueOrderTests`, `NativeSwiftKotlinParityTests`,
/// `NativeSwiftFloatIntegerViewTests` and `NativeSwiftIntegerWriteTests` already port are not
/// repeated here.
@Suite struct NativeSwiftSinglePassResolutionTests {
  private typealias Op = NativeSwiftWireOpcode
  private typealias Named = NativeSwiftNamedVariableType
  private typealias System = NativeSwiftSystemVariables

  private static let add = Writer.floatOperator(NativeSwiftFloatOperator.add)
  private static let mul = Writer.floatOperator(NativeSwiftFloatOperator.mul)

  /// A data-only session over the operations `build` writes after a 100x100 header.
  private static func open(_ build: (Writer) -> Void) throws -> NativeSwiftDocumentSession {
    let document = Writer()
    document.header(width: 100, height: 100)
    build(document)
    return try NativeSwiftDocumentSession.open(data: document.data, toleratingRootlessData: true)
  }

  /// A session over a document with an empty root after the operations `build` writes.
  private static func openWithRoot(_ build: (Writer) -> Void) throws -> NativeSwiftDocumentSession {
    let document = Writer()
    document.header(width: 100, height: 100)
    build(document)
    document.u8(Op.layoutRoot).int(1).u8(Op.containerEnd)
    return try NativeSwiftDocumentSession.open(data: document.data)
  }

  private static func argb(_ value: UInt32) -> Int { Int(Int32(bitPattern: value)) }

  /// Integer-expression masks: bit n marks token n as a variable id (the low bits) or an operator.
  private static let variableThenOperator = 0b101
  private static let operatorAtThirdToken = 0b100

  /// `TextFromFloat`'s digits word: digits before the point in the high half, after it in the low.
  private static func digits(before: Int, after: Int) -> Int { (before << 16) | after }

  /// A root-level `DrawTextRun` of the whole of text `id`.
  private static func drawText(_ document: Writer, id: Int) {
    document.u8(Op.drawText).int(id).int(0).int(-1).int(0).int(0).float(0).float(0).u8(0)
  }

  /// A root-level rect whose width is `[id]`, so a snapshot shows what the frame resolved there.
  private static func drawWidth(_ document: Writer, of id: Int) {
    document.u8(Op.drawRect).float(0).float(0).int(Writer.nanReference(id)).float(10)
  }

  private static func allCommands(_ node: NativeSwiftNodeSnapshot)
    -> [NativeSwiftDrawCommandSnapshot]
  {
    node.commands + node.children.flatMap(allCommands)
  }

  /// The texts and rect widths `snapshot` drew, in draw order.
  private static func drawnTexts(_ snapshot: NativeSwiftDocumentSnapshot) -> [String?] {
    allCommands(snapshot.root).filter { $0.kind == NativeSwiftDrawKind.text }.map(\.text)
  }

  private static func drawnWidths(_ snapshot: NativeSwiftDocumentSnapshot) -> [Float] {
    allCommands(snapshot.root).filter { $0.kind == NativeSwiftDrawKind.rect }.map { $0.values[2] }
  }

  /// A known issue that is the session refusing the document with `reason`, not any other error.
  private static func isRefusal(_ issue: Issue, _ reason: String) -> Bool {
    "\(issue)".contains(reason)
  }

  // MARK: - RcPlayerStateTest: loops and conditionals

  /// `RcPlayerStateTest.loopRefreshesHoistedExpressionsThatReadItsIndex` (and the compose
  /// module's `RcControlFlowRenderTest.loopReevaluatesHoistedIndexExpressions`): F43 = [42],
  /// F44 = [43] * 20, F45 = [44] * 2 at the top, then a loop writing index 42 over 0, 1, 2. Each
  /// pass reads 45 again: 0, 40, 80.
  @Test func aLoopRefreshesTheExpressionsThatReadItsIndex() throws {
    let document = Writer()
    document.header(width: 100, height: 100)
    document.u8(Op.animatedFloat).int(43).int(1).int(Writer.nanReference(42))
    document.u8(Op.animatedFloat).int(44).int(3).int(Writer.nanReference(43))
      .int(Writer.literal(20)).int(Self.mul)
    document.u8(Op.animatedFloat).int(45).int(3).int(Writer.nanReference(44))
      .int(Writer.literal(2)).int(Self.mul)
    document.u8(Op.loopStart).int(42).float(0).float(1).float(3)
    document.u8(Op.drawRect).int(Writer.nanReference(45)).float(0).float(10).float(10)
    document.u8(Op.containerEnd)
    let commands = try NativeSwiftDocumentSession.open(data: document.data).snapshot().root.commands
    let xs = commands.filter { $0.kind == NativeSwiftDrawKind.rect }.map { $0.values[0] }
    withKnownIssue("an expression outside a loop is not evaluated again for each pass") {
      #expect(xs == [0, 40, 80], "Kotlin [0, 40, 80]; Swift \(xs)")
    }
  }

  /// `RcPlayerStateTest.evaluatesEveryAndroidXConditionalTypeIncludingChangedState`, the literal
  /// half: 2 against 3 for each comparison type, plus 3 against 3 so `<` and `<=` differ. The
  /// branch's box is drawn when it holds. Not ported: CHANGED, whose state this core's
  /// decode-time conditionals do not keep (see `aConditionalReadsAComputedFloat`).
  @Test(arguments: [
    (NativeSwiftConditionalType.equal, 2, false), (NativeSwiftConditionalType.equal, 3, true),
    (NativeSwiftConditionalType.notEqual, 2, true), (NativeSwiftConditionalType.notEqual, 3, false),
    (NativeSwiftConditionalType.lessThan, 2, true), (NativeSwiftConditionalType.lessThan, 3, false),
    (NativeSwiftConditionalType.lessThanOrEqual, 2, true),
    (NativeSwiftConditionalType.lessThanOrEqual, 3, true),
    (NativeSwiftConditionalType.greaterThan, 2, false),
    (NativeSwiftConditionalType.greaterThan, 3, false),
    (NativeSwiftConditionalType.greaterThanOrEqual, 2, false),
    (NativeSwiftConditionalType.greaterThanOrEqual, 3, true),
  ])
  func eachConditionalTypeComparesAsKotlinDoes(type: Int, left: Float, holds: Bool) throws {
    let document = Writer()
    document.header(width: 100, height: 100)
    document.u8(Op.layoutRoot).int(1)
    document.u8(Op.conditionalOperations).u8(type).float(left).float(3)
    document.u8(Op.layoutBox).int(5).int(-1).int(1).int(1)
    document.u8(Op.containerEnd).u8(Op.containerEnd).u8(Op.containerEnd)
    let root = try NativeSwiftDocumentSession.open(data: document.data).snapshot().root
    #expect((root.node(withComponentID: 5) != nil) == holds, "type \(type), \(left) vs 3")
  }

  /// An extension of the test above (Kotlin's answer: `RcValueOrderReferenceTest`): over a computed
  /// float, F50 = 1 + 1, `[50] == 2` holds once the expression has run.
  @Test func aConditionalReadsAComputedFloat() throws {
    let document = Writer()
    document.header(width: 100, height: 100)
    document.u8(Op.animatedFloat).int(50).int(3).int(Writer.literal(1)).int(Writer.literal(1))
      .int(Self.add)
    document.u8(Op.layoutRoot).int(1)
    document.u8(Op.conditionalOperations).u8(NativeSwiftConditionalType.equal)
      .int(Writer.nanReference(50)).float(2)
    document.u8(Op.layoutBox).int(5).int(-1).int(1).int(1)
    document.u8(Op.containerEnd).u8(Op.containerEnd).u8(Op.containerEnd)
    let result = Result { try NativeSwiftDocumentSession.open(data: document.data).snapshot() }
    withKnownIssue("a conditional is decided at decode, before any expression has run") {
      let root = try result.get().root
      #expect(root.node(withComponentID: 5) != nil, "Kotlin draws the branch")
    }
  }

  // MARK: - RcPlayerStateTest: text operations

  /// `RcPlayerStateTest.anActionSendsTheTextItsOpsComputeFromCurrentValues`: T4 formats F2, T5 =
  /// "ticks=" + T4; after a frame the host moves F2 from 30 to 50, and a click with no frame in
  /// between computes T5 again: "ticks=50".
  @Test func anActionSendsTheTextComputedFromTheCurrentValues() throws {
    let document = Writer()
    document.header(width: 100, height: 100)
    document.text(id: 1, "ha")
    document.u8(Op.dataFloat).int(2).float(30)
    document.text(id: 3, "ticks=")
    // Kotlin's `RcTextFromFloat(4, [2], 255, 0, 517)`.
    document.u8(Op.textFromFloat).int(4).int(Writer.nanReference(2))
      .int(Self.digits(before: 255, after: 0)).int(517)
    document.u8(Op.textMerge).int(5).int(3).int(4)
    document.u8(Op.layoutRoot).int(1)
    document.u8(Op.layoutBox).int(3).int(-1).int(1).int(4)
    document.u8(Op.modifierClick)
      .u8(Op.hostNamedAction).int(1).int(NativeSwiftHostActionValueType.string).int(5)
      .u8(Op.containerEnd)
    document.u8(Op.containerEnd).u8(Op.containerEnd)
    let session = try NativeSwiftDocumentSession.open(data: document.data)
    _ = try session.snapshot(timeSeconds: 0)
    #expect(session.setFloat(50, forID: 2))
    let events = try session.click(componentID: 3, timeSeconds: 0)
    withKnownIssue("an action sends a derived text as the last frame left it") {
      #expect(events == [.namedAction(name: "ha", value: .text("ticks=50"))], "\(events as Any)")
    }
  }

  /// `RcPlayerStateTest.aTextNotYetProducedReadsAsEmptyAndAnEmptyPathExpressionDrawsNothing`, the
  /// text half: a merge, length or substring over a text nothing produced reads it as "", and a
  /// range past the text selects what there is.
  @Test func aTextNothingProducedReadsAsEmpty() throws {
    let values = try Self.open { document in
      document.text(id: 1, "abc")
      document.u8(Op.textMerge).int(10).int(1).int(99)
      document.u8(Op.textLength).int(11).int(99)
      document.u8(Op.textSubtext).int(12).int(99).float(0).float(2)
      document.u8(Op.textSubtext).int(13).int(1).float(1).float(10)
      document.u8(Op.textSubtext).int(14).int(1).float(5).float(-1)
    }.probeValues(timeSeconds: 0)
    #expect(values.texts[10] == "abc", "\(values.texts[10] as Any)")
    withKnownIssue("a length over a text nothing produced is left unset") {
      #expect(values.floats[11] == 0, "\(values.floats[11] as Any)")
    }
    #expect(values.texts[12] == "", "\(values.texts[12] as Any)")
    #expect(values.texts[13] == "bc", "\(values.texts[13] as Any)")
    #expect(values.texts[14] == "", "\(values.texts[14] as Any)")
  }

  /// `RcPlayerStateTest.anActionLeavesATextAnOpAppendsToAsTheLastFrameLeftIt`: T5 = T5 + T3
  /// appends to its own output. Kotlin's `beginFrame` resets derived text, so each frame draws
  /// "ab" and a click sends it (the second frame is pinned in `RcValueOrderReferenceTest`).
  @Test func aMergeOntoItsOwnOutputAppendsOncePerFrame() throws {
    let document = Writer()
    document.header(width: 100, height: 100)
    document.text(id: 1, "ha")
    document.text(id: 3, "b")
    document.text(id: 5, "a")
    document.u8(Op.textMerge).int(5).int(5).int(3)
    document.u8(Op.layoutRoot).int(1)
    Self.drawText(document, id: 5)
    document.u8(Op.layoutBox).int(3).int(-1).int(1).int(4)
    document.u8(Op.modifierClick)
      .u8(Op.hostNamedAction).int(1).int(NativeSwiftHostActionValueType.string).int(5)
      .u8(Op.containerEnd)
    document.u8(Op.containerEnd).u8(Op.containerEnd)
    let session = try NativeSwiftDocumentSession.open(data: document.data)
    var drawn: [String?] = []
    var sent: [[NativeSwiftEvent]?] = []
    for time in [0.0, 1.0] {
      drawn += Self.drawnTexts(try session.snapshot(timeSeconds: time))
      sent.append(try session.click(componentID: 3, timeSeconds: time))
    }
    withKnownIssue("a derived text is not reset before each resolution") {
      #expect(drawn == ["ab", "ab"], "\(drawn)")
      #expect(
        sent == [
          [.namedAction(name: "ha", value: .text("ab"))],
          [.namedAction(name: "ha", value: .text("ab"))],
        ],
        "\(sent)")
    }
  }

  /// `RcPlayerStateTest.evaluatesTextOperationsInWireOrder`: T3 = merge, T4 = its tail, F5 = the
  /// tail's length, T6 = T3 upper-cased.
  @Test func textOperationsRunInWireOrder() throws {
    let values = try Self.open { document in
      document.text(id: 1, "Remote")
      document.text(id: 2, " Compose")
      document.u8(Op.textMerge).int(3).int(1).int(2)
      document.u8(Op.textSubtext).int(4).int(3).float(7).float(-1)
      document.u8(Op.textLength).int(5).int(4)
      document.u8(Op.textTransform).int(6).int(3).float(0).float(-1)
        .int(NativeSwiftTextTransformOperation.uppercase)
    }.probeValues(timeSeconds: 0)
    #expect(values.texts[4] == "Compose", "\(values.texts[4] as Any)")
    #expect(values.floats[5] == 7, "\(values.floats[5] as Any)")
    #expect(values.texts[6] == "REMOTE COMPOSE", "\(values.texts[6] as Any)")
  }

  /// `RcPlayerStateTest.replaysLayoutContentDataOperationsAfterEveryFrameReset`: I69 = 1 and
  /// T70 = the list's entry at [69], inside the layout content, on every frame.
  @Test func aTextLookupByAnIntegerExpressionResolvesEveryFrame() throws {
    let document = Writer()
    document.header(width: 100, height: 100)
    document.text(id: 66, "Morning run (0)")
    document.text(id: 67, "Morning run")
    let titles = 2_097_194  // the list id the WatchScreenRemote capture uses
    document.u8(Op.idList).int(titles).int(2).int(66).int(67)
    document.u8(Op.layoutRoot).int(1)
    document.u8(Op.layoutContent).int(2)
    document.u8(Op.integerExpression).int(69).int(0).int(1).int(1)
    document.u8(Op.textLookupInt).int(70).int(titles).int(69)
    document.u8(Op.containerEnd)
    Self.drawText(document, id: 70)
    document.u8(Op.containerEnd)
    let session = try NativeSwiftDocumentSession.open(data: document.data)
    for time in [0.0, 1.0] {
      let drawn = Self.drawnTexts(try session.snapshot(timeSeconds: time))
      #expect(drawn == ["Morning run"], "t=\(time) \(drawn)")
    }
  }

  /// `RcPlayerStateTest.replaysFloatProducersBeforeTheTextOperationsThatReadThem`: the host writes
  /// F10 = 2; F11 = [10] * 3; T12 formats F11 with one digit: "6".
  @Test func aFloatProducerRunsBeforeTheTextThatFormatsIt() throws {
    let session = try Self.openWithRoot { document in
      document.u8(Op.dataFloat).int(10).float(0)
      document.u8(Op.animatedFloat).int(11).int(3).int(Writer.nanReference(10))
        .int(Writer.literal(3)).int(Self.mul)
      document.u8(Op.textFromFloat).int(12).int(Writer.nanReference(11))
        .int(Self.digits(before: 1, after: 0)).int(0)
      Self.drawText(document, id: 12)
    }
    #expect(session.setFloat(2, forID: 10))
    let drawn = Self.drawnTexts(try session.snapshot(timeSeconds: 0))
    #expect(drawn == ["6"], "\(drawn)")
  }

  /// `RcPlayerStateTest.evaluatesAndroidXCollectionLookupsIntoTypedStores`: TextLookup by a
  /// literal index, TextLookupInt by an integer constant, IdLookup, and a float data-map entry.
  @Test func collectionLookupsFillTheirTypedViews() throws {
    let key = Array("temperature".utf8)
    let values = try Self.openWithRoot { document in
      document.text(id: 1, "zero")
      document.text(id: 2, "one")
      document.text(id: 3, "temperature")
      document.u8(Op.dataInt).int(4).int(1)
      document.u8(Op.dataFloat).int(5).float(21.5)
      document.u8(Op.idList).int(10).int(2).int(1).int(2)
      document.u8(Op.idMap).int(11).int(1).int(key.count).raw(Data(key))
        .u8(NativeSwiftDataMapType.float).int(5)
      document.u8(Op.textLookup).int(20).int(10).float(1)
      document.u8(Op.textLookupInt).int(21).int(10).int(4)
      document.u8(Op.idLookup).int(22).int(10).float(0)
      document.u8(Op.dataMapLookup).int(23).int(11).int(3)
    }.probeValues(timeSeconds: 0)
    #expect(values.texts[20] == "one", "\(values.texts[20] as Any)")
    #expect(values.texts[21] == "one", "\(values.texts[21] as Any)")
    #expect(values.integers[22] == 1, "\(values.integers[22] as Any)")
    #expect(values.floats[23] == 21.5, "\(values.floats[23] as Any)")
  }

  // MARK: - RcPlayerStateTest: colours, matrices and canvas scopes

  /// `RcPlayerStateTest.colorExpressionsCoverInterpolationHsvArgbAndDynamicAlpha`.
  @Test func colourExpressionsInterpolateAndBuildFromChannels() throws {
    typealias Mode = NativeSwiftColorExpressionMode
    let colors = try Self.open { document in
      document.u8(Op.colorConstant).int(7).int(Self.argb(0xFF00_0000))
      document.u8(Op.colorConstant).int(8).int(Self.argb(0xFFFF_FFFF))
      document.u8(Op.dataFloat).int(20).float(0.25)
      document.u8(Op.colorExpressions).int(30).int(Mode.idIDInterpolate).int(7).int(8).float(0.5)
      document.u8(Op.colorExpressions).int(31).int((128 << 16) | Mode.hsv)
        .float(0.5).float(1).float(1)
      document.u8(Op.colorExpressions).int(32).int((512 << 16) | Mode.argb)
        .float(0.25).float(0.5).float(0.75)
      document.u8(Op.colorExpressions).int(33).int((20 << 16) | Mode.idARGB)
        .float(1).float(0).float(0)
    }.probeValues(timeSeconds: 0).colors
    #expect(colors[30] == 0xFFBA_BABA, "\(colors[30].map { String($0, radix: 16) } as Any)")
    #expect(colors[31] == 0x8000_FFFF, "\(colors[31].map { String($0, radix: 16) } as Any)")
    #expect(colors[32] == 0x8040_80BF, "\(colors[32].map { String($0, radix: 16) } as Any)")
    #expect(colors[33] == 0x40FF_0000, "\(colors[33].map { String($0, radix: 16) } as Any)")
  }

  /// `RcPlayerStateTest.colorAttributesMatchAndroidXNormalizedComponents`: every channel of
  /// 0x804080C0, normalised.
  @Test func colourAttributesReadEveryNormalisedChannel() throws {
    typealias Channel = NativeSwiftColorAttributeType
    let expected: [(type: Int, value: Float)] = [
      (Channel.hue, 7 / 12), (Channel.saturation, 2 / 3), (Channel.brightness, 192 / 255),
      (Channel.red, 64 / 255), (Channel.green, 128 / 255), (Channel.blue, 192 / 255),
      (Channel.alpha, 128 / 255),
    ]
    let values = try Self.open { document in
      document.u8(Op.colorConstant).int(7).int(Self.argb(0x8040_80C0))
      for (type, _) in expected { document.u8(Op.attributeColor).int(20 + type).int(7).u16(type) }
    }.probeValues(timeSeconds: 0)
    for (type, value) in expected {
      let resolved = values.floats[20 + type] ?? .nan
      #expect(
        abs(resolved - value) <= 0.000_001, "type \(type): Kotlin \(value); Swift \(resolved)")
    }
  }

  /// `RcPlayerStateTest.replaysColorAttributesAfterTheColorExpressionsTheyRead`: C30 interpolates
  /// black and white at 0.5, F31 is its brightness.
  @Test func aColourAttributeReadsTheColourExpressionBeforeIt() throws {
    let values = try Self.open { document in
      document.u8(Op.colorConstant).int(7).int(Self.argb(0xFF00_0000))
      document.u8(Op.colorConstant).int(8).int(Self.argb(0xFFFF_FFFF))
      document.u8(Op.colorExpressions).int(30).int(NativeSwiftColorExpressionMode.idIDInterpolate)
        .int(7).int(8).float(0.5)
      document.u8(Op.attributeColor).int(31).int(30).u16(NativeSwiftColorAttributeType.brightness)
    }.probeValues(timeSeconds: 0)
    #expect(values.floats[31] == 0.729_411_8, "\(values.floats[31] as Any)")
  }

  /// `RcPlayerStateTest.replaysTheValuesACanvasOperationsBlockPublishesForItsLaterSiblings`: a
  /// canvas-operations block decomposes C7's alpha into F30; F31 = [30] after the block; a canvas
  /// after both draws a rect F31 wide.
  @Test func aCanvasOperationsBlockPublishesValuesForLaterSiblings() throws {
    let document = Writer()
    document.header(width: 100, height: 100)
    document.u8(Op.colorConstant).int(7).int(Self.argb(0x80FF_FFFF))
    document.u8(Op.layoutRoot).int(1)
    document.u8(Op.layoutContent).int(2)
    document.u8(Op.canvasOperations)
    document.u8(Op.attributeColor).int(30).int(7).u16(NativeSwiftColorAttributeType.alpha)
    document.u8(Op.containerEnd)
    document.u8(Op.animatedFloat).int(31).int(1).int(Writer.nanReference(30))
    document.u8(Op.layoutCanvas).int(3).int(-1)
    document.u8(Op.layoutContent).int(4)
    Self.drawWidth(document, of: 31)
    document.u8(Op.containerEnd).u8(Op.containerEnd)
    document.u8(Op.containerEnd).u8(Op.containerEnd)
    let widths = Self.drawnWidths(
      try NativeSwiftDocumentSession.open(data: document.data).snapshot(timeSeconds: 0))
    #expect(widths == [0.501_960_8], "\(widths)")
  }

  /// `RcPlayerStateTest.evaluatesAndroidXMatrixVectorMath`: translate (2, 3) applied to (4, 5).
  @Test func matrixVectorMathTransformsItsInputs() throws {
    let values = try Self.openWithRoot { document in
      let matrix: [Float] = [1, 0, 0, 2, 0, 1, 0, 3, 0, 0, 1, 0, 0, 0, 0, 1]
      document.u8(Op.matrixConstant).int(20).int(0).int(matrix.count)
      for value in matrix { document.float(value) }
      document.u8(Op.matrixVectorMath).u16(NativeSwiftMatrixVectorMathType.multiply).int(20)
        .int(2).int(30).int(31).int(2).float(4).float(5)
    }.probeValues(timeSeconds: 0)
    #expect(
      values.floats[30] == 6 && values.floats[31] == 8,
      "\(values.floats[30] as Any) \(values.floats[31] as Any)")
  }

  /// `RcPlayerStateTest.matrixExpressionResolvesVariablesBeforeVectorMath`: a translate by
  /// ([12] = 6, 7), then (1, 2) through it.
  @Test func aMatrixExpressionReadsVariablesBeforeVectorMath() throws {
    let values = try Self.openWithRoot { document in
      document.u8(Op.dataFloat).int(12).float(6)
      document.u8(Op.matrixExpression).int(20).int(0).int(3).int(Writer.nanReference(12)).float(7)
        .int(Writer.matrixOperator(NativeSwiftMatrixOperator.translate2))
      document.u8(Op.matrixVectorMath).u16(NativeSwiftMatrixVectorMathType.multiply).int(20)
        .int(2).int(30).int(31).int(2).float(1).float(2)
    }.probeValues(timeSeconds: 0)
    #expect(
      values.floats[30] == 7 && values.floats[31] == 9,
      "\(values.floats[30] as Any) \(values.floats[31] as Any)")
  }

  // MARK: - RcPlayerStateTest: run actions

  /// `RcPlayerStateTest.runActionExecutesInWireOrderWithoutSchedulingClickInvalidation`, the
  /// value half: a run action's integer write is visible to the frame that ran it. (Its host
  /// action half is a deliberate difference: `ParsedRunAction` runs no host action.)
  @Test func aRunActionsWriteIsVisibleInItsFrame() throws {
    let document = Writer()
    document.header(width: 100, height: 100)
    document.u8(Op.dataInt).int(20).int(0)
    document.u8(Op.layoutRoot).int(1)
    document.u8(Op.runAction)
    document.u8(Op.valueIntegerChangeAction).int(20).int(4)
    document.u8(Op.containerEnd)
    Self.drawWidth(document, of: 20)
    document.u8(Op.containerEnd)
    let widths = Self.drawnWidths(
      try NativeSwiftDocumentSession.open(data: document.data).snapshot(timeSeconds: 0))
    #expect(widths == [4], "\(widths)")
  }

  // MARK: - AndroidX actions and derived values

  /// AndroidX `ValueFloatExpressionChangeActionOperationTest` ("clicking Box evaluates expression
  /// and updates target"): target 4, expression [target] + 2.5, two clicks give 9 -- the
  /// expression is evaluated again on each click against the value the last one wrote.
  @Test func aFloatExpressionActionReadsTheValueTheLastClickWrote() throws {
    let document = Writer()
    document.header(width: 100, height: 100)
    document.u8(Op.dataFloat).int(50).float(4)
    document.u8(Op.animatedFloat).int(51).int(3).int(Writer.nanReference(50)).float(2.5)
      .int(Self.add)
    document.u8(Op.layoutRoot).int(1)
    document.u8(Op.layoutBox).int(3).int(-1).int(1).int(4)
    document.u8(Op.modifierClick).u8(Op.valueFloatExpressionChangeAction).int(50).int(51)
      .u8(Op.containerEnd)
    document.u8(Op.containerEnd).u8(Op.containerEnd)
    let session = try NativeSwiftDocumentSession.open(data: document.data)
    for _ in 0..<2 {
      _ = try session.snapshot(timeSeconds: 0)
      _ = try session.click(componentID: 3, timeSeconds: 0)
    }
    let value = try session.probeValues(timeSeconds: 0).floats[50]
    #expect(value == 9, "\(value as Any)")
  }

  /// AndroidX `ValueIntegerExpressionChangeActionOperationTest.testIncrementMultipleTimes`:
  /// I42 = 0, expression [42] + 1, three clicks give 1, 2, 3.
  @Test func anIntegerExpressionActionIncrementsOnEachClick() throws {
    let document = Writer()
    document.header(width: 100, height: 100)
    document.u8(Op.dataInt).int(42).int(0)
    document.u8(Op.integerExpression).int(60).int(Self.variableThenOperator).int(3).int(42).int(1)
      .int(Writer.integerOperator(NativeSwiftIntegerOperator.add))
    document.u8(Op.layoutRoot).int(1)
    document.u8(Op.layoutBox).int(3).int(-1).int(1).int(4)
    document.u8(Op.modifierClick).u8(Op.valueIntegerExpressionChangeAction).long(42).long(60)
      .u8(Op.containerEnd)
    document.u8(Op.containerEnd).u8(Op.containerEnd)
    let session = try NativeSwiftDocumentSession.open(data: document.data)
    var seen: [Int?] = []
    for _ in 0..<3 {
      _ = try session.snapshot(timeSeconds: 0)
      _ = try session.click(componentID: 3, timeSeconds: 0)
      seen.append(try session.probeValues(timeSeconds: 0).integers[42])
    }
    #expect(seen == [1, 2, 3], "\(seen)")
  }

  /// AndroidX `IntegerExpressionEvaluatorTest.divisionByZero_doesNotThrow`: 5 / 0 and 5 % 0 are 0.
  @Test func integerDivisionByZeroIsZero() throws {
    typealias Integer = NativeSwiftIntegerOperator
    let values = try Self.open { document in
      for (id, operation) in [(60, Integer.div), (61, Integer.mod)] {
        document.u8(Op.integerExpression).int(id).int(Self.operatorAtThirdToken).int(3).int(5)
          .int(0).int(Writer.integerOperator(operation))
      }
    }.probeValues(timeSeconds: 0)
    #expect(
      values.integers[60] == 0 && values.integers[61] == 0,
      "\(values.integers[60] as Any) \(values.integers[61] as Any)")
  }

  /// AndroidX `RcPlayerDerivedDataTest.textLookupFollowsItsIndex`: a list ["a", "bb", "ccc"], a
  /// named index 0 then 2, T = the entry at the index, F = its length * 10: 10, then 30.
  @Test func aLengthFollowsTheTextALookupPicks() throws {
    let session = try Self.openWithRoot { document in
      document.text(id: 1, "a")
      document.text(id: 2, "bb")
      document.text(id: 3, "ccc")
      document.u8(Op.idList).int(10).int(3).int(1).int(2).int(3)
      document.u8(Op.dataInt).int(11).int(0)
      document.namedVariable(id: 11, type: Named.int, name: "index")
      document.u8(Op.textLookupInt).int(20).int(10).int(11)
      document.u8(Op.textLength).int(21).int(20)
      document.u8(Op.animatedFloat).int(22).int(3).int(Writer.nanReference(21)).float(10)
        .int(Self.mul)
      Self.drawWidth(document, of: 22)
    }
    #expect(Self.drawnWidths(try session.snapshot(timeSeconds: 0)) == [10])
    #expect(session.setInteger(2, for: "index"))
    let widths = Self.drawnWidths(try session.snapshot(timeSeconds: 0))
    #expect(widths == [30], "\(widths)")
  }

  /// AndroidX `RcPlayerImperativeExpressionTest.loopAccumulator_readsTheValueAfterTheLoop`:
  /// F70 = 0, then a four-pass loop writing F70 = [70] + 20; a rect after the loop is 80 wide.
  @Test func aLoopAccumulatorReadsTheValueAfterTheLoop() throws {
    let document = Writer()
    document.header(width: 100, height: 100)
    document.u8(Op.dataFloat).int(70).float(0)
    document.u8(Op.loopStart).int(0).float(0).float(1).float(4)
    document.u8(Op.animatedFloat).int(70).int(3).int(Writer.nanReference(70)).float(20)
      .int(Self.add)
    document.u8(Op.containerEnd)
    document.u8(Op.drawRect).float(0).float(0).int(Writer.nanReference(70)).float(10)
    let result = Result { try NativeSwiftDocumentSession.open(data: document.data).snapshot() }
    try withKnownIssue("a float expression inside a loop body is refused at decode") {
      let widths = Self.drawnWidths(try result.get())
      #expect(widths == [80], "\(widths)")
    } matching: {
      Self.isRefusal($0, "not yet structurally migrated")
    }
  }

  /// AndroidX `GraphContextComponentValueTest.componentValueTakesPrecedenceOverStoreFloatOverride`:
  /// a host write to a component value's id is replaced by the measured width.
  @Test func aComponentValueReplacesAHostWriteToItsID() throws {
    let document = Writer()
    document.header(width: 400, height: 400)
    document.u8(Op.componentValue).int(NativeSwiftComponentValueType.width).int(5).int(90)
    document.namedVariable(id: 90, type: Named.float, name: "compWidth")
    document.u8(Op.layoutRoot).int(1)
    document.u8(Op.layoutBox).int(5).int(-1).int(1).int(1)
    document.u8(Op.modifierWidth).int(NativeSwiftDimensionType.exact).float(100)
    document.u8(Op.modifierHeight).int(NativeSwiftDimensionType.exact).float(100)
    document.u8(Op.layoutContent).int(-1).u8(Op.containerEnd)
    document.u8(Op.containerEnd).u8(Op.containerEnd)
    let session = try NativeSwiftDocumentSession.open(data: document.data)
    _ = try session.snapshot(timeSeconds: 0)
    #expect(session.setFloat(999, for: "compWidth"))
    _ = try session.snapshot(timeSeconds: 0)
    let value = try session.probeValues(timeSeconds: 0).floats[90]
    withKnownIssue("a host write to a component value's id is kept over the measurement") {
      #expect(value == 100, "\(value as Any)")
    }
  }

  // MARK: - Compose module: geometry and visibility

  /// The row the next two tests lay out: a 100x40 row holding canvas -6, which `content` fills,
  /// then canvas -8, `width` wide.
  private static func siblingGeometryDocument(
    content: (Writer) -> Void, width: (Writer) -> Void
  ) -> Data {
    let document = Writer()
    document.header(width: 100, height: 40)
    document.u8(Op.layoutRoot).int(-2)
    document.u8(Op.layoutContent).int(-3)
    document.u8(Op.layoutRow).int(-4).int(0).int(1).int(4).float(0)
    document.u8(Op.modifierWidth).int(NativeSwiftDimensionType.exact).float(100)
    document.u8(Op.modifierHeight).int(NativeSwiftDimensionType.exact).float(40)
    document.u8(Op.layoutContent).int(-5)
    document.u8(Op.layoutCanvas).int(-6).int(0)
    content(document)
    document.u8(Op.containerEnd)
    document.u8(Op.layoutCanvas).int(-8).int(0)
    width(document)
    document.u8(Op.containerEnd)
    document.u8(Op.containerEnd).u8(Op.containerEnd).u8(Op.containerEnd).u8(Op.containerEnd)
    return document.data
  }

  private static func rectWidths(_ data: Data) throws -> [Float] {
    drawnWidths(try NativeSwiftDocumentSession.open(data: data).snapshot())
  }

  /// `RcNativeSnapshotTest.settlesLaterSiblingGeometryBeforeResolvingEarlierCommands`: canvas -6
  /// draws the width of the later sibling -8, which is 30.
  @Test func anEarlierCanvasReadsALaterSiblingsWidth() throws {
    let widths = try Self.rectWidths(
      Self.siblingGeometryDocument(
        content: { document in
          document.u8(Op.layoutContent).int(-7)
          document.u8(Op.componentValue).int(NativeSwiftComponentValueType.width).int(-8).int(42)
          document.u8(Op.drawRect).float(0).float(0).int(Writer.nanReference(42)).float(10)
          document.u8(Op.containerEnd)
        },
        width: { $0.u8(Op.modifierWidth).int(NativeSwiftDimensionType.exact).float(30) }))
    #expect(widths == [30], "\(widths)")
  }

  /// `RcNativeSnapshotTest.settlesCurrentFrameSizeExpressionBeforePublishingSiblingGeometry`: the
  /// later sibling's width is F50 = 30, an expression.
  @Test func anEarlierCanvasReadsALaterSiblingsComputedWidth() throws {
    let widths = try Self.rectWidths(
      Self.siblingGeometryDocument(
        content: { document in
          document.u8(Op.layoutContent).int(-7)
          document.u8(Op.componentValue).int(NativeSwiftComponentValueType.width).int(-8).int(42)
          document.u8(Op.drawRect).float(0).float(0).int(Writer.nanReference(42)).float(10)
          document.u8(Op.containerEnd)
        },
        width: { document in
          document.u8(Op.animatedFloat).int(50).int(1).float(30)
          document.u8(Op.modifierWidth).int(NativeSwiftDimensionType.exact)
            .int(Writer.nanReference(50))
        }))
    #expect(widths == [30], "\(widths)")
  }

  /// `RcLayoutRenderTest.aVisibilityNamingTheLiteralVisibleIdShowsTheComponent`: a visibility
  /// modifier naming id 1, which nothing writes, reads 1 (VISIBLE): an unset id below 42 is its
  /// own value (`RcPlayerState.integer`). Passes today; pinned for the rewrite.
  @Test func aVisibilityNamingTheLiteralVisibleIDShowsTheComponent() throws {
    let document = Writer()
    document.header(width: 100, height: 100)
    document.u8(Op.layoutRoot).int(1)
    document.u8(Op.layoutBox).int(5).int(-1).int(1).int(1)
    document.u8(Op.modifierVisibility).int(NativeSwiftVisibility.visible)
    document.u8(Op.containerEnd).u8(Op.containerEnd)
    let node = try NativeSwiftDocumentSession.open(data: document.data).snapshot().root
      .node(withComponentID: 5)
    #expect(node != nil, "Kotlin shows the box")
  }

  /// `RcTimeSourceRenderTest.aHostClockDrivesANamedCalendarField` (with
  /// `RcSystemVariableTest.namingASystemVariableDoesNotClaimIt`): a `NamedVariable` on
  /// DAY_OF_MONTH or YEAR leaves it the clock's. (Kotlin's check that the name resolves to the
  /// system id is `NativeSwiftCoreTests.namedVariableDeclarationsAnswerAsTheSessionDoes`' kind.)
  @Test func namingASystemVariableDoesNotClaimIt() throws {
    let session = try Self.openWithRoot { document in
      document.namedVariable(id: System.dayOfMonth, type: Named.float, name: "cal_day")
      document.namedVariable(id: System.year, type: Named.float, name: "cal_year")
    }
    let clock = NativeSwiftWallClock(epochMillis: KotlinReference.epochMillis)
    let values = try session.probeValues(timeSeconds: 0, wallClock: clock)
    #expect(
      values.floats[System.dayOfMonth] == Float(clock.fields.dayOfMonth)
        && values.floats[System.year] == Float(clock.fields.year),
      "\(values.floats[System.dayOfMonth] as Any) \(values.floats[System.year] as Any)")
  }

  // MARK: - RcSystemVariableTest

  /// `RcSystemVariableTest.anExpressionOverTheContinuousClockEvaluatesToANumberAndMovesBetweenFrames`:
  /// F100 = [CONTINUOUS_SEC] * 2 at 30:45.250 into the hour is 3690.5, and 3691.5 half a second on.
  @Test func anExpressionOverTheContinuousClockMovesBetweenFrames() throws {
    let session = try Self.openWithRoot { document in
      document.u8(Op.animatedFloat).int(100).int(3).int(
        Writer.nanReference(System.continuousSeconds)
      )
      .float(2).int(Self.mul)
    }
    let first = try session.probeValues(
      timeSeconds: 0, wallClock: NativeSwiftWallClock(epochMillis: KotlinReference.epochMillis))
    let later = try session.probeValues(
      timeSeconds: 1,
      wallClock: NativeSwiftWallClock(epochMillis: KotlinReference.epochMillis + 500))
    #expect(first.floats[100] == 3690.5, "\(first.floats[100] as Any)")
    #expect(later.floats[100] == 3691.5, "\(later.floats[100] as Any)")
  }

  /// `RcSystemVariableTest.aHostWriteToASystemIdClaimsItForGood`: a host write to OFFSET_TO_UTC
  /// before the first frame survives the clock's load.
  @Test func aHostWriteToASystemIdClaimsIt() throws {
    let session = try Self.openWithRoot { _ in }
    #expect(session.setFloat(2, forID: System.offsetToUTC))
    let clock = NativeSwiftWallClock(epochMillis: KotlinReference.epochMillis)
    _ = try session.snapshot(timeSeconds: 0, wallClock: clock)
    let values = try session.probeValues(timeSeconds: 0, wallClock: clock)
    #expect(values.floats[System.offsetToUTC] == 2, "\(values.floats[System.offsetToUTC] as Any)")
    #expect(values.floats[System.continuousSeconds] == 1845.25)
  }

  /// `RcSystemVariableTest.theDensityBuiltInsAreLoadedAndDefaultToAnUnscaledHost`.
  @Test func theDensityBuiltInsDefaultToAnUnscaledHost() throws {
    let session = try Self.openWithRoot { _ in }
    var values = try session.probeValues(timeSeconds: 0)
    #expect(values.floats[System.density] == 1 && values.floats[System.fontSize] == 14)
    session.setHostDensity(2.2625, fontScale: 1.3)
    values = try session.probeValues(timeSeconds: 0)
    #expect(values.floats[System.density] == 2.2625)
    let (sp, scale, density): (Float, Float, Float) = (14, 1.3, 2.2625)
    #expect(values.floats[System.fontSize] == sp * scale * density)
  }

  /// `RcSystemVariableTest.aDensityThatWouldPoisonADocumentIsIgnoredRatherThanStored` and
  /// `eachHostDensityArgumentIsJudgedOnItsOwn`: a bad density or font scale is dropped on its own.
  @Test func eachHostDensityArgumentIsJudgedOnItsOwn() throws {
    let session = try Self.openWithRoot { _ in }
    session.setHostDensity(3, fontScale: 1.5)
    session.setHostDensity(.nan, fontScale: .nan)
    session.setHostDensity(-.infinity, fontScale: -2)
    var values = try session.probeValues(timeSeconds: 0)
    #expect(values.floats[System.density] == 3)
    let sp = NativeSwiftSystemVariables.defaultFontSizeSp
    #expect(values.floats[System.fontSize] == sp * 1.5 * 3)
    session.setHostDensity(0, fontScale: 2)
    values = try session.probeValues(timeSeconds: 0)
    let fontSize = values.floats[System.fontSize]
    #expect(values.floats[System.density] == 3, "\(values.floats[System.density] as Any)")
    #expect(fontSize == sp * 2 * 3, "\(fontSize.map { String($0.bitPattern, radix: 16) } as Any)")
  }

  // MARK: - RcExpressionMemoTest

  /// `RcExpressionMemoTest.anInputThatMovedIsEvaluatedAgain`: F43 = [42] * 2 follows a host
  /// write to 42.
  @Test func anExpressionFollowsAnInputThatMoved() throws {
    let session = try Self.open { document in
      document.u8(Op.dataFloat).int(42).float(3)
      document.u8(Op.animatedFloat).int(43).int(3).int(Writer.nanReference(42)).float(2)
        .int(Self.mul)
    }
    #expect(try session.probeValues(timeSeconds: 0).floats[43] == 6)
    #expect(session.setFloat(5, forID: 42))
    #expect(try session.probeValues(timeSeconds: 0).floats[43] == 10)
  }

  /// `RcExpressionMemoTest.aWriteToTheOutputIsReplacedByTheNextEvaluationAsBefore`: a host write
  /// to F43 = [42] * 2 lasts until the expression runs again, which gives 6.
  @Test func aWriteToAnExpressionsOutputIsReplacedByTheNextEvaluation() throws {
    let session = try Self.open { document in
      document.u8(Op.dataFloat).int(42).float(3)
      document.u8(Op.animatedFloat).int(43).int(3).int(Writer.nanReference(42)).float(2)
        .int(Self.mul)
    }
    _ = try session.probeValues(timeSeconds: 0)
    #expect(session.setFloat(1, forID: 43))
    let value = try session.probeValues(timeSeconds: 0).floats[43]
    withKnownIssue("a host write to an expression's output is kept over the expression") {
      #expect(value == 6, "Kotlin 6; Swift \(value as Any)")
    }
  }

  /// The same write by name: Kotlin's `setNamedValue` is `setFloat` too, so the next evaluation
  /// replaces it. (AndroidX `RcPlayerExpressionTest.testHostFloatOverrideBeatsAuthoredExpression`
  /// keeps a named override over the expression instead; Kotlin is the spec this suite follows.)
  @Test func aNamedWriteToAnExpressionsOutputIsReplacedByTheNextEvaluation() throws {
    let session = try Self.open { document in
      document.u8(Op.animatedFloat).int(43).int(3).float(2).float(3).int(Self.add)
      document.namedVariable(id: 43, type: Named.float, name: "sum")
    }
    #expect(try session.probeValues(timeSeconds: 0).floats[43] == 5)
    #expect(session.setFloat(42, for: "sum"))
    let value = try session.probeValues(timeSeconds: 0).floats[43]
    withKnownIssue("a host write to an expression's output is kept over the expression") {
      #expect(value == 5, "Kotlin 5; Swift \(value as Any)")
    }
  }

  // MARK: - RcFloatExpressionEvaluatorRobustnessTest

  /// `RcFloatExpressionEvaluatorRobustnessTest.anOperatorWithTooFewOperandsReadsZero` and
  /// `anEmptyExpressionReadsZero`: Kotlin reads both as 0. These and the stack limit below are the
  /// evaluator's rules, not resolution order.
  @Test func anOperatorWithTooFewOperandsReadsZero() throws {
    let result = Result {
      try Self.open { document in
        document.u8(Op.animatedFloat).int(50).int(1).int(Self.add)
      }.probeValues(timeSeconds: 0)
    }
    try withKnownIssue(
      "an expression with too few operands refuses the document (as AndroidX does)"
    ) {
      let value = try result.get().floats[50]
      #expect(value == 0, "\(value as Any)")
    } matching: {
      Self.isRefusal($0, "stack underflow")
    }
  }

  @Test func anEmptyExpressionReadsZero() throws {
    let result = Result {
      try Self.open { document in
        document.u8(Op.animatedFloat).int(51).int(0)
      }.probeValues(timeSeconds: 0)
    }
    try withKnownIssue("an expression with no words refuses the document") {
      let value = try result.get().floats[51]
      #expect(value == 0, "\(value as Any)")
    } matching: {
      Self.isRefusal($0, "Invalid float expression result")
    }
  }

  /// `RcFloatExpressionEvaluatorRobustnessTest.aLongExpressionDoesNotOverflowTheStack`: 200 ones
  /// and 199 additions give 200.
  @Test func aLongExpressionResolves() throws {
    let result = Result {
      try Self.open { document in
        document.u8(Op.animatedFloat).int(52).int(399)
        for _ in 0..<200 { document.float(1) }
        for _ in 0..<199 { document.int(Self.add) }
      }.probeValues(timeSeconds: 0)
    }
    try withKnownIssue(
      "the evaluator's stack stops at AndroidX's 128 entries; Kotlin's has no limit"
    ) {
      let values = try result.get()
      #expect(values.floats[52] == 200, "\(values.floats[52] as Any)")
    } matching: {
      Self.isRefusal($0, "stack overflow")
    }
  }

  // MARK: - RcFloatExpressionRuntimeTest

  /// An animated F59 over the named float 58 ("source"), with `animation` as its animation words.
  private static func animatedDocument(source: Float, animation: [Int]) -> Data {
    let document = Writer()
    document.header(width: 100, height: 100)
    document.u8(Op.dataFloat).int(58).float(source)
    document.namedVariable(id: 58, type: Named.float, name: "source")
    document.u8(Op.animatedFloat).int(59).int((animation.count << 16) | 1)
      .int(Writer.nanReference(58))
    for word in animation { document.int(word) }
    document.u8(Op.layoutRoot).int(1)
    drawWidth(document, of: 59)
    document.u8(Op.containerEnd)
    return document.data
  }

  /// The F59 a frame at `time` draws.
  private static func animated(_ session: NativeSwiftDocumentSession, at time: Double) throws
    -> Float?
  {
    drawnWidths(try session.snapshot(timeSeconds: time)).first
  }

  /// `RcFloatExpressionRuntimeTest.aTweenRetargetsFromItsCurrentValue`: a 1 s linear tween from 0
  /// toward 100 is halfway at 1.5 s; retargeted to 0 there, it heads down from 50. Animation
  /// runtime behaviour, not resolution order, like the spring tests below.
  @Test func aTweenRetargetsFromItsCurrentValue() throws {
    let session = try NativeSwiftDocumentSession.open(
      data: Self.animatedDocument(
        source: 0,
        animation: [Writer.literal(1), Int(NativeSwiftFloatEasingType.cubicLinear.rawValue)]))
    #expect(try Self.animated(session, at: 0) == 0)
    #expect(session.setFloat(100, for: "source"))
    _ = try Self.animated(session, at: 1)
    let middle = try #require(try Self.animated(session, at: 1.5))
    #expect(abs(middle - 50) <= 0.01, "\(middle)")
    #expect(session.setFloat(0, for: "source"))
    let retargeted = try #require(try Self.animated(session, at: 1.5))
    let quarter = try #require(try Self.animated(session, at: 2))
    withKnownIssue("a tween retargeted mid-flight starts again from its previous target") {
      #expect(abs(retargeted - middle) <= 0.01, "\(retargeted)")
      #expect(abs(quarter - 25) <= 0.01, "\(quarter)")
    }
    #expect(try Self.animated(session, at: 2.5) == 0)
  }

  /// The spring `remote-m3`'s selection controls record: stiffness 1400, critically damped, 0.001
  /// stop threshold.
  /// Kotlin `RcFloatExpressionRuntimeTest`'s words: the spring marker, stiffness, damping, stop
  /// threshold, and a zero final word.
  private static let spring = [
    Writer.literal(NativeSwiftFloatAnimationMetadata.springMarker), Writer.literal(1400),
    Writer.literal(74.833_15), Writer.literal(0.001), 0,
  ]

  /// `RcFloatExpressionRuntimeTest.aSpringStartsSettledAtItsFirstTarget`.
  @Test func aSpringStartsSettledAtItsFirstTarget() throws {
    let session = try NativeSwiftDocumentSession.open(
      data: Self.animatedDocument(source: 1, animation: Self.spring))
    let first = try Self.animated(session, at: 0)
    let snapshot = try session.snapshot(timeSeconds: 0)
    let later = try Self.animated(session, at: 5)
    withKnownIssue("a spring starts at 0 rather than at its first target") {
      #expect(first == 1, "Kotlin 1; Swift \(first as Any)")
      #expect(!snapshot.needsContinuousFrames)
    }
    withKnownIssue("a spring integrates a long frame gap in one unstable step") {
      #expect(later == 1, "\(later as Any)")
    }
  }

  /// `RcFloatExpressionRuntimeTest.aSpringConvergesAtCoarseFrameIntervals`: from 0 to 1 over
  /// twenty 100 ms frames the spring stays within [-0.01, 1.01] and ends settled at 1.
  @Test func aSpringConvergesAtCoarseFrameIntervals() throws {
    let session = try NativeSwiftDocumentSession.open(
      data: Self.animatedDocument(source: 0, animation: Self.spring))
    _ = try Self.animated(session, at: 0)
    #expect(session.setFloat(1, for: "source"))
    var samples: [Float] = []
    for frame in 1...20 {
      samples.append(try Self.animated(session, at: Double(frame) / 10) ?? .nan)
    }
    let settled = try session.snapshot(timeSeconds: 2)
    withKnownIssue("a spring integrates a long frame gap in one unstable step") {
      #expect(samples.allSatisfy { (-0.01...1.01).contains($0) }, "\(samples)")
      #expect(samples.last == 1 && !settled.needsContinuousFrames, "\(samples.last as Any)")
    }
  }

  /// `RcFloatExpressionRuntimeTest.aRetargetAfterIdleSpringsFromNowRatherThanJumping`.
  @Test func aRetargetAfterIdleSpringsFromNow() throws {
    let session = try NativeSwiftDocumentSession.open(
      data: Self.animatedDocument(source: 1, animation: Self.spring))
    _ = try Self.animated(session, at: 0)
    #expect(session.setFloat(0, for: "source"))
    let retargeted = try session.snapshot(timeSeconds: 10)
    let first = try #require(Self.drawnWidths(retargeted).first)
    let next = try #require(try Self.animated(session, at: 10.016))
    withKnownIssue("a spring starts at 0 rather than at its first target") {
      #expect(abs(first - 1) < 0.01, "the idle gap was integrated as one step: \(first)")
      #expect(retargeted.needsContinuousFrames, "a retargeted spring asks for frames")
      #expect(next < first && next > 0, "\(next)")
    }
  }

  // MARK: - RcParticleRuntimeTest

  /// `RcParticleRuntimeTest.initializationCanReadInjectedFrameClock`: a particle's first value is
  /// [CONTINUOUS_SEC] at the first frame, 4.5 s.
  @Test func aParticleInitialisesFromTheFrameClock() throws {
    let session = try Self.openWithRoot { document in
      document.u8(Op.particleDefine).int(9).int(1).int(1).int(70).int(1)
        .int(Writer.nanReference(System.continuousSeconds))
      document.u8(Op.particleLoop).int(9).int(1).float(0).int(1).int(1)
        .int(Writer.nanReference(70))
    }
    _ = try session.snapshot(timeSeconds: 4.5)
    let value = try session.probeValues(timeSeconds: 4.5).floats[70]
    #expect(value == 4.5, "\(value as Any)")
  }
}
