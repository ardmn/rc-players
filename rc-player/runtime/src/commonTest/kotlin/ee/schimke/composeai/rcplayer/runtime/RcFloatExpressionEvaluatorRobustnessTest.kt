package ee.schimke.composeai.rcplayer.runtime

import ee.schimke.composeai.rcplayer.protocol.RcFloatWord
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertSame

/** Malformed expressions degrade to 0 instead of throwing out of the draw pass. */
class RcFloatExpressionEvaluatorRobustnessTest {
  private val evaluator = RcFloatExpressionEvaluator()

  private fun op(id: Int) =
    RcFloatWord(0xff800000.toInt() or (RcFloatExpressionEvaluator.OFFSET + id))

  private fun word(value: Float) = RcFloatWord.literal(value)

  @Test
  fun meshVariablesWithoutBindingsReadZero() {
    // VAR1 * 2 + 1, evaluated as a plain float with no u/v supplied: what a hoisted mesh
    // sub-expression looks like to the document's float runtime.
    val expression = listOf(op(70), word(2f), op(3), word(1f), op(1))
    assertEquals(1f, evaluator.evaluate(expression))
    assertEquals(0f, evaluator.evaluate(listOf(op(72)), FloatArray(2)))
    assertEquals(7f, evaluator.evaluate(listOf(op(71)), floatArrayOf(3f, 7f)))
  }

  @Test
  fun anOperatorWithTooFewOperandsReadsZero() {
    assertEquals(0f, evaluator.evaluate(listOf(op(1))))
    assertEquals(0f, evaluator.evaluate(listOf(word(1f), op(25))))
  }

  @Test
  fun anEmptyExpressionReadsZero() {
    assertEquals(0f, evaluator.evaluate(emptyList()))
  }

  @Test
  fun aLongExpressionDoesNotOverflowTheStack() {
    val expression = List(200) { word(1f) } + List(199) { op(1) }
    assertEquals(200f, evaluator.evaluate(expression))
  }

  private val list = RcFloatWord(0xff800000.toInt() or LIST_ID)

  /**
   * AndroidX throws past `Limits.MAX_SUM_TILL_ITERATIONS` (Limits.java:105), which a host's
   * infinity reaches.
   */
  @Test
  fun aSumPastTheIterationLimitReadsZero() {
    val evaluator = RcFloatExpressionEvaluator { id ->
      if (id == LIST_ID) floatArrayOf(1f, 2f) else null
    }
    assertEquals(3f, evaluator.evaluate(listOf(list, word(1f), op(A_SUM_TILL))))
    assertEquals(
      0f,
      evaluator.evaluate(listOf(list, word(Float.POSITIVE_INFINITY), op(A_SUM_TILL))),
    )
  }

  /** Only the sum's own limit reads 0: a failure in the caller's resolver still reaches it. */
  @Test
  fun aFailureOutsideTheSumsLimitIsNotSwallowed() {
    val failure = IllegalArgumentException("resolver")
    val variable = RcFloatWord(0x7fc00000 or 12)
    val thrown =
      assertFailsWith<IllegalArgumentException> {
        evaluator.evaluate(listOf(variable, word(1f), op(1))) { throw failure }
      }
    assertSame(failure, thrown)
  }

  /** `A_LERP` reads `array[array.length - 1]` (AnimatedFloatExpression.java:1261): 0 when empty. */
  @Test
  fun aLerpOverAnEmptyListReadsZero() {
    val evaluator = RcFloatExpressionEvaluator { id -> if (id == LIST_ID) FloatArray(0) else null }
    assertEquals(0f, evaluator.evaluate(listOf(list, word(0.5f), op(A_LERP))))
    assertEquals(0f, evaluator.evaluate(listOf(list, word(2f), op(A_LERP))))
  }

  private companion object {
    /** The float list the expressions read. */
    const val LIST_ID = 0x200005

    /** AndroidX `OP_A_SUM_TILL` less `OFFSET` (AnimatedFloatExpression.java:862). */
    const val A_SUM_TILL = 76

    /** AndroidX `OP_A_LERP` less `OFFSET` (AnimatedFloatExpression.java:865). */
    const val A_LERP = 79
  }
}
