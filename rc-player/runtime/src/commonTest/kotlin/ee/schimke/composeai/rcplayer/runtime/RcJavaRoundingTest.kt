package ee.schimke.composeai.rcplayer.runtime

import ee.schimke.composeai.rcplayer.protocol.RcFloatWord
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Java's `Math.round(float)`, which AndroidX rounds with (`OP_ROUND`,
 * AnimatedFloatExpression.java:928; StringUtils.java:91): the closest int, ties up, computed
 * exactly (Java 7 and later), NaN 0, past `Int` saturated.
 */
class RcJavaRoundingTest {
  @Test
  fun javaRoundToIntRoundsAsJavasMathRound() {
    for ((value, expected) in JAVA_ROUNDED) {
      assertEquals(expected, value.javaRoundToInt(), "$value")
    }
  }

  @Test
  fun theExpressionRoundOperatorRoundsAsJavasMathRound() {
    val evaluator = RcFloatExpressionEvaluator()
    for ((value, expected) in JAVA_ROUNDED) {
      val rounded = evaluator.evaluate(listOf(RcFloatWord.literal(value), ROUND))
      assertEquals(expected.toFloat(), rounded, "$value")
    }
  }

  private companion object {
    /** AndroidX `OP_ROUND` (AnimatedFloatExpression.java:798). */
    val ROUND = RcFloatExpressionEvaluator.operatorWord(RcFloatExpressionEvaluator.OFFSET + 17)

    /**
     * Each value and Java's `Math.round` of it. `0.49999997f + 0.5f` rounds to 1f in float, and
     * `8388609f + 0.5f` to 8388610f: only an exact sum gives Java's 0 and 8388609.
     */
    val JAVA_ROUNDED =
      listOf(
        0.49999997f to 0,
        8_388_609f to 8_388_609,
        0.5f to 1,
        -0.5f to 0,
        -2.5f to -2,
        2.5f to 3,
        Float.NaN to 0,
        Float.POSITIVE_INFINITY to Int.MAX_VALUE,
        Float.NEGATIVE_INFINITY to Int.MIN_VALUE,
        3e9f to Int.MAX_VALUE,
        -3e9f to Int.MIN_VALUE,
      )
  }
}
