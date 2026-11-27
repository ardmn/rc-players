package ee.schimke.composeai.rcplayer.runtime

import ee.schimke.composeai.rcplayer.protocol.RcColorConstant
import ee.schimke.composeai.rcplayer.protocol.RcColorExpression
import ee.schimke.composeai.rcplayer.protocol.RcComponentValue
import ee.schimke.composeai.rcplayer.protocol.RcConditionalOperations
import ee.schimke.composeai.rcplayer.protocol.RcDocument
import ee.schimke.composeai.rcplayer.protocol.RcFloatConstant
import ee.schimke.composeai.rcplayer.protocol.RcFloatExpression
import ee.schimke.composeai.rcplayer.protocol.RcFloatWord
import ee.schimke.composeai.rcplayer.protocol.RcHeader
import ee.schimke.composeai.rcplayer.protocol.RcIdList
import ee.schimke.composeai.rcplayer.protocol.RcIntegerConstant
import ee.schimke.composeai.rcplayer.protocol.RcIntegerExpression
import ee.schimke.composeai.rcplayer.protocol.RcLoopOperation
import ee.schimke.composeai.rcplayer.protocol.RcNamedVariable
import ee.schimke.composeai.rcplayer.protocol.RcOperation
import ee.schimke.composeai.rcplayer.protocol.RcTextData
import ee.schimke.composeai.rcplayer.protocol.RcTextLength
import ee.schimke.composeai.rcplayer.protocol.RcTextLookupInt
import ee.schimke.composeai.rcplayer.protocol.RcTextMerge
import ee.schimke.composeai.rcplayer.protocol.RcValueFloatExpressionChangeAction
import ee.schimke.composeai.rcplayer.protocol.RcValueIntegerExpressionChangeAction
import ee.schimke.composeai.rcplayer.protocol.RcVersion
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Kotlin's answers for the Swift `NativeSwiftValueOrderTests` and
 * `NativeSwiftSinglePassResolutionTests` cases that no other Kotlin test pins: one wire-order pass
 * per frame, as the player runs it. The AndroidX-derived cases name their AndroidX test; the value
 * asserted is Kotlin's. A case the document plays through a measure pass or a draw-pass loop is
 * driven through the entry point the Kotlin player uses for it (`publishComponentGeometry`,
 * `forEachLoopValue`).
 */
class RcValueOrderReferenceTest {
  private fun ref(id: Int) = RcFloatWord(0x7fc00000 or id)

  private val add = RcFloatExpressionEvaluator.operatorWord(RcFloatExpressionEvaluator.OFFSET + 1)
  private val mul = RcFloatExpressionEvaluator.operatorWord(RcFloatExpressionEvaluator.OFFSET + 3)
  private val div = RcFloatExpressionEvaluator.operatorWord(RcFloatExpressionEvaluator.OFFSET + 4)

  private fun document(vararg operations: RcOperation) =
    RcDocument(RcHeader(RcVersion(0, 1, 0)), operations.toList())

  private fun RcPlayerState.applyAll(vararg operations: RcOperation) =
    applyContentStateOperations(operations.map { RcLinkedNode.Operation(it) })

  private fun pass(declarations: List<RcOperation>, operations: List<RcOperation>): RcPlayerState {
    val state = RcPlayerState(document(*(declarations + operations).toTypedArray()))
    state.beginFrame()
    state.applyContentStateOperations(operations.map { RcLinkedNode.Operation(it) })
    return state
  }

  @Test
  fun aCycleThroughBothViewsAdvancesOncePerPass() {
    val operations =
      listOf(
        RcIntegerExpression(60, 0b101, listOf(70, 1, RcIntegerExpression.ADD)),
        RcFloatExpression(70, listOf(ref(60), RcFloatWord.literal(1f), add), null),
      )
    val state = pass(emptyList(), operations)
    assertEquals(1, state.integer(60))
    assertEquals(2f, state.float(70))
    state.beginFrame()
    state.applyContentStateOperations(operations.map { RcLinkedNode.Operation(it) })
    assertEquals(3, state.integer(60))
    assertEquals(4f, state.float(70))
  }

  @Test
  fun aForwardChainThroughBothViewsResolvesInOnePass() {
    val operations = mutableListOf<RcOperation>()
    operations += RcFloatExpression(100, listOf(RcFloatWord.literal(1.5f)), null)
    for (step in 0 until 5) {
      val floatIn = 100 + step * 2
      operations +=
        RcIntegerExpression(floatIn + 1, 0b101, listOf(floatIn, 1, RcIntegerExpression.ADD))
      operations +=
        RcFloatExpression(
          floatIn + 2,
          listOf(ref(floatIn + 1), RcFloatWord.literal(0.5f), add),
          null,
        )
    }
    val state = pass(emptyList(), operations)
    assertEquals(listOf(2, 3, 4, 5, 6), listOf(101, 103, 105, 107, 109).map { state.integer(it) })
    assertEquals(
      listOf(2.5f, 3.5f, 4.5f, 5.5f, 6.5f),
      listOf(102, 104, 106, 108, 110).map { state.float(it) },
    )
  }

  @Test
  fun integerAndFloatExpressionAtOneId() {
    val floatExpression = RcFloatExpression(60, listOf(RcFloatWord.literal(7.5f)), null)
    val integerExpression = RcIntegerExpression(60, 1, listOf(52))
    val declarations = listOf(RcIntegerConstant(52, 4))
    val floatFirst = pass(declarations, listOf(floatExpression, integerExpression))
    assertEquals(4, floatFirst.integer(60))
    assertEquals(4f, floatFirst.float(60))
    val integerFirst = pass(declarations, listOf(integerExpression, floatExpression))
    assertEquals(7, integerFirst.integer(60))
    assertEquals(7.5f, integerFirst.float(60))
  }

  @Test
  fun floatConstantAndIntegerExpressionAtOneId() {
    val integerExpression = RcIntegerExpression(60, 1, listOf(52))
    for (constantFirst in listOf(true, false)) {
      val constant = RcFloatConstant(60, RcFloatWord.literal(7.5f))
      val declarations =
        if (constantFirst) listOf(RcIntegerConstant(52, 4), constant)
        else listOf(RcIntegerConstant(52, 4))
      val state =
        RcPlayerState(
          document(
            *(declarations +
                integerExpression +
                (if (constantFirst) emptyList() else listOf(constant)))
              .toTypedArray(),
          ),
        )
      state.beginFrame()
      state.applyContentStateOperations(listOf(RcLinkedNode.Operation(integerExpression)))
      assertEquals(4, state.integer(60), "constantFirst=$constantFirst")
      assertEquals(4f, state.float(60), "constantFirst=$constantFirst")
    }
  }

  @Test
  fun constantsReplayInWireOrder() {
    // The Swift test also reads 51 through an integer expression, I53 = [51], after the load.
    val reader = RcIntegerExpression(53, 1, listOf(51))
    fun load(vararg operations: RcOperation): RcPlayerState =
      RcPlayerState(document(*operations, reader)).apply {
        beginFrame()
        applyAll(reader)
      }
    fun f(v: Float) = RcFloatConstant(51, RcFloatWord.literal(v))
    fun i(v: Int) = RcIntegerConstant(51, v)
    val cases =
      listOf(
        load(f(1.5f), f(2.5f)) to (2 to 2.5f),
        load(i(7), i(9)) to (9 to 9f),
        load(i(7), f(2.75f), i(7)) to (7 to 7f),
        load(f(2.75f), i(2)) to (2 to 2.75f),
        load(f(2.75f), i(2), f(3.25f)) to (3 to 3.25f),
        load(i(2), f(2.75f), i(2), i(5)) to (5 to 5f),
      )
    cases.forEachIndexed { index, (state, expected) ->
      assertEquals(expected.first, state.integer(51), "case $index")
      assertEquals(expected.second, state.float(51), "case $index")
      assertEquals(expected.first, state.integer(53), "case $index")
    }
  }

  /** Float 50 = 4; int 60 = [50]; float 52 = 8 / [60]: 2. */
  @Test
  fun divisionByAnIntegerViewOfAFloat() {
    val operations =
      arrayOf<RcOperation>(
        RcFloatExpression(50, listOf(RcFloatWord.literal(4f)), null),
        RcIntegerExpression(60, 1, listOf(50)),
        RcFloatExpression(52, listOf(RcFloatWord.literal(8f), ref(60), div), null),
      )
    val state = RcPlayerState(document(*operations))
    state.beginFrame()
    state.applyAll(*operations)
    assertEquals(2f, state.float(52))
  }

  /** A float expression, then a float constant at its id: the expression wins both views. */
  @Test
  fun floatConstantAfterAFloatExpressionAtOneId() {
    val expression = RcFloatExpression(60, listOf(RcFloatWord.literal(7.5f)), null)
    val reader = RcIntegerExpression(61, 1, listOf(60))
    val state =
      RcPlayerState(
        document(expression, RcFloatConstant(60, RcFloatWord.literal(2.25f)), reader),
      )
    state.beginFrame()
    state.applyAll(expression, reader)
    assertEquals(7.5f, state.float(60))
    assertEquals(7, state.integer(60))
    assertEquals(7, state.integer(61))
  }

  /** A host integer write by name onto an integer expression is replaced by the next pass. */
  @Test
  fun hostIntegerWriteOntoAnIntegerExpressionIsReplaced() {
    val expression = RcIntegerExpression(60, 1, listOf(52))
    val state =
      RcPlayerState(
        document(
          RcIntegerConstant(52, 4),
          expression,
          RcNamedVariable(60, RcNamedVariable.INT_TYPE, "derived"),
        ),
      )
    state.setNamedValue("derived", RcNamedValue.Integer(9))
    state.beginFrame()
    state.applyAll(expression)
    assertEquals(4, state.integer(60))
  }

  /**
   * AndroidX `IntegerExpressionEvaluatorTest.divisionByZero_doesNotThrow`: 5 / 0 and 5 % 0 are 0.
   */
  @Test
  fun integerDivisionByZeroIsZero() {
    val divide = RcIntegerExpression(60, 0b100, listOf(5, 0, RcIntegerExpression.DIV))
    val remainder = RcIntegerExpression(61, 0b100, listOf(5, 0, RcIntegerExpression.MOD))
    val state = RcPlayerState(document(divide, remainder))
    state.beginFrame()
    state.applyAll(divide, remainder)
    assertEquals(0, state.integer(60))
    assertEquals(0, state.integer(61))
  }

  /** AndroidX `ValueFloatExpressionChangeActionOperationTest`: 4, [50] + 2.5, two clicks: 9. */
  @Test
  fun aFloatExpressionActionReadsTheValueTheLastClickWrote() {
    val expression = RcFloatExpression(51, listOf(ref(50), RcFloatWord.literal(2.5f), add), null)
    val state = RcPlayerState(document(RcFloatConstant(50, RcFloatWord.literal(4f)), expression))
    val click =
      RcClickActionBlock(listOf(RcLinkedNode.Operation(RcValueFloatExpressionChangeAction(50, 51))))
    repeat(2) {
      state.beginFrame()
      state.applyAll(expression)
      state.executeClick(click)
    }
    assertEquals(9f, state.float(50))
  }

  /** AndroidX `ValueIntegerExpressionChangeActionOperationTest.testIncrementMultipleTimes`. */
  @Test
  fun anIntegerExpressionActionIncrementsOnEachClick() {
    val expression = RcIntegerExpression(60, 0b101, listOf(42, 1, RcIntegerExpression.ADD))
    val state = RcPlayerState(document(RcIntegerConstant(42, 0), expression))
    val click =
      RcClickActionBlock(
        listOf(RcLinkedNode.Operation(RcValueIntegerExpressionChangeAction(42L, 60L))),
      )
    val seen =
      List(3) {
        state.beginFrame()
        state.applyAll(expression)
        state.executeClick(click)
        state.integer(42)
      }
    assertEquals(listOf(1, 2, 3), seen)
  }

  /** AndroidX `RcPlayerDerivedDataTest.textLookupFollowsItsIndex`: 10, then 30. */
  @Test
  fun aLengthFollowsTheTextALookupPicks() {
    val operations =
      arrayOf<RcOperation>(
        RcTextLookupInt(20, 10, 11),
        RcTextLength(21, 20),
        RcFloatExpression(22, listOf(ref(21), RcFloatWord.literal(10f), mul), null),
      )
    val state =
      RcPlayerState(
        document(
          RcTextData(1, "a"),
          RcTextData(2, "bb"),
          RcTextData(3, "ccc"),
          RcIdList(10, listOf(1, 2, 3)),
          RcIntegerConstant(11, 0),
          RcNamedVariable(11, RcNamedVariable.INT_TYPE, "index"),
          *operations,
        ),
      )
    state.beginFrame()
    state.applyAll(*operations)
    assertEquals(10f, state.float(22))
    state.setNamedValue("index", RcNamedValue.Integer(2))
    state.beginFrame()
    state.applyAll(*operations)
    assertEquals(30f, state.float(22))
  }

  /**
   * AndroidX `RcPlayerImperativeExpressionTest.loopAccumulator_readsTheValueAfterTheLoop`: F70 = 0,
   * a four-pass loop writing F70 = [70] + 20, as the draw pass runs a loop body: 80.
   */
  @Test
  fun aLoopAccumulatorReadsTheValueAfterTheLoop() {
    val step = RcFloatExpression(70, listOf(ref(70), RcFloatWord.literal(20f), add), null)
    val state = RcPlayerState(document(RcFloatConstant(70, RcFloatWord.literal(0f))))
    state.beginFrame()
    state.forEachLoopValue(
      RcLoopOperation(0, RcFloatWord.literal(0f), RcFloatWord.literal(1f), RcFloatWord.literal(4f)),
    ) {
      state.applyFloatExpression(step)
    }
    assertEquals(80f, state.float(70))
  }

  /**
   * AndroidX `GraphContextComponentValueTest.componentValueTakesPrecedenceOverStoreFloatOverride`:
   * a host write of 999 to a component value's id, then the measurement is published again.
   */
  @Test
  fun aComponentValueAgainstAHostWriteToItsId() {
    val state =
      RcPlayerState(
        document(
          RcComponentValue(RcComponentValue.WIDTH, componentId = 5, valueId = 90),
          RcNamedVariable(90, RcNamedVariable.FLOAT_TYPE, "compWidth"),
        ),
      )
    val geometry = RcComponentGeometry(100f, 100f, 0f, 0f, 0f, 0f)
    state.publishComponentGeometry(5, geometry)
    state.setNamedValue("compWidth", RcNamedValue.FloatValue(999f))
    state.publishComponentGeometry(5, geometry)
    assertEquals(100f, state.float(90))
  }

  /** A conditional over a computed float: F50 = 1 + 1, then `[50] == 2` holds. */
  @Test
  fun aConditionalReadsAComputedFloat() {
    val expression =
      RcFloatExpression(50, listOf(RcFloatWord.literal(1f), RcFloatWord.literal(1f), add), null)
    val state = RcPlayerState(document(expression))
    state.beginFrame()
    state.applyAll(expression)
    assertEquals(
      true,
      state.evaluateConditional(
        RcConditionalOperations(RcConditionalOperations.EQUAL, ref(50), RcFloatWord.literal(2f)),
      ),
    )
  }

  /** A host write by name onto F43 = 2 + 3 is replaced by the next evaluation: 5. */
  @Test
  fun aNamedWriteToAnExpressionsOutputIsReplacedByTheNextEvaluation() {
    val expression =
      RcFloatExpression(43, listOf(RcFloatWord.literal(2f), RcFloatWord.literal(3f), add), null)
    val state =
      RcPlayerState(
        document(expression, RcNamedVariable(43, RcNamedVariable.FLOAT_TYPE, "sum")),
      )
    state.beginFrame()
    state.applyAll(expression)
    state.setNamedValue("sum", RcNamedValue.FloatValue(42f))
    state.beginFrame()
    state.applyAll(expression)
    assertEquals(5f, state.float(43))
  }

  /** T5 = T5 + T3 appends once per frame: "ab" on the first frame and on the next. */
  @Test
  fun aMergeOntoItsOwnOutputAppendsOncePerFrame() {
    val merge = RcTextMerge(5, 5, 3)
    val state = RcPlayerState(document(RcTextData(3, "b"), RcTextData(5, "a"), merge))
    val drawn =
      List(2) {
        state.beginFrame()
        state.applyAll(merge)
        state.text(5)
      }
    assertEquals(listOf("ab", "ab"), drawn)
  }

  /**
   * A colour interpolation truncates each channel to a byte, as AndroidX `Utils.interpolateColor`
   * does: half-alpha black to white at 0.25 is 0x9F878787 (159.75 and 135.79 truncated).
   */
  @Test
  fun aColourInterpolationTruncatesEachChannel() {
    val expression =
      RcColorExpression(
        30,
        RcColorExpression.ID_ID_INTERPOLATE,
        7,
        8,
        RcFloatWord.literal(0.25f).bits,
      )
    val state =
      RcPlayerState(
        document(
          RcColorConstant(7, 0x80000000.toInt()),
          RcColorConstant(8, 0xffffffff.toInt()),
          expression,
        ),
      )
    state.beginFrame()
    state.applyAll(expression)
    assertEquals(0x9f878787.toInt(), state.color(30))
  }
}
