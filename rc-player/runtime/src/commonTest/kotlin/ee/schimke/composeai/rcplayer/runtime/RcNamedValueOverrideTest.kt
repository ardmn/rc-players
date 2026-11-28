package ee.schimke.composeai.rcplayer.runtime

import ee.schimke.composeai.rcplayer.protocol.RcColorConstant
import ee.schimke.composeai.rcplayer.protocol.RcColorExpression
import ee.schimke.composeai.rcplayer.protocol.RcDocument
import ee.schimke.composeai.rcplayer.protocol.RcDynamicFloatList
import ee.schimke.composeai.rcplayer.protocol.RcFloatConstant
import ee.schimke.composeai.rcplayer.protocol.RcFloatExpression
import ee.schimke.composeai.rcplayer.protocol.RcFloatList
import ee.schimke.composeai.rcplayer.protocol.RcFloatWord
import ee.schimke.composeai.rcplayer.protocol.RcHeader
import ee.schimke.composeai.rcplayer.protocol.RcNamedVariable
import ee.schimke.composeai.rcplayer.protocol.RcVersion
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

/**
 * The host overrides the embedded AndroidX player grew beyond the scalar ones: booleans (an integer
 * name holding 1 or 0), float arrays, and the `USER:` namespace an unqualified name resolves into.
 */
class RcNamedValueOverrideTest {

  private fun document() =
    RcDocument(
      RcHeader(RcVersion(0, 1, 0)),
      listOf(
        RcNamedVariable(50, RcNamedVariable.INT_TYPE, "USER:enabled"),
        RcFloatList(51, listOf(RcFloatWord.literal(1f), RcFloatWord.literal(2f))),
        RcNamedVariable(51, RcNamedVariable.FLOAT_ARRAY_TYPE, "USER:series"),
        RcFloatConstant(52, RcFloatWord.literal(3f)),
        RcNamedVariable(52, RcNamedVariable.FLOAT_TYPE, "plain"),
        RcFloatConstant(53, RcFloatWord.literal(4f)),
        RcNamedVariable(53, RcNamedVariable.FLOAT_TYPE, "OTHER:plain"),
      ),
    )

  /**
   * A host float over an id an expression drives sticks when it differs from the value there and is
   * no write when equal, as AndroidX's `overrideFloat` pins only what it writes
   * (RemoteComposeState.java:314-324; `updateFloat` skips a pinned id, 294-305). Clearing unpins.
   */
  @Test
  fun aHostFloatPinsAnExpressionsIdOnlyWhenItDiffers() {
    val sum =
      RcFloatExpression(
        61,
        listOf(
          RcFloatWord(0x7fc00000 or 60),
          RcFloatWord.literal(1f),
          RcFloatExpressionEvaluator.operatorWord(RcFloatExpressionEvaluator.OFFSET + 1),
        ),
        null,
      )
    val state =
      RcPlayerState(
        RcDocument(
          RcHeader(RcVersion(0, 1, 0)),
          listOf(
            RcFloatConstant(60, RcFloatWord.literal(2f)),
            RcNamedVariable(60, RcNamedVariable.FLOAT_TYPE, "USER:y"),
            sum,
            RcNamedVariable(61, RcNamedVariable.FLOAT_TYPE, "USER:x"),
          ),
        ),
      )
    fun frame(y: Float): Float? {
      state.setNamedValue("USER:y", RcNamedValue.FloatValue(y))
      state.applyFloatExpression(sum)
      return state.float(61)
    }
    assertEquals(3f, frame(2f))

    state.setNamedValue("USER:x", RcNamedValue.FloatValue(3f))
    assertEquals(6f, frame(5f), "an equal write pins nothing")

    state.setNamedValue("USER:x", RcNamedValue.FloatValue(10f))
    assertEquals(10f, frame(7f), "a different write pins the id")

    state.clearNamedValue("USER:x")
    assertEquals(9f, frame(8f), "clearing unpins it")
  }

  @Test
  fun aBooleanOverrideWritesOneOrZeroToAnIntegerName() {
    val state = RcPlayerState(document())

    state.setNamedValue("USER:enabled", RcNamedValue.BooleanValue(true))
    assertEquals(1, state.integer(50))

    state.setNamedValue("USER:enabled", RcNamedValue.BooleanValue(false))
    assertEquals(0, state.integer(50))
  }

  @Test
  fun aFloatArrayOverrideReplacesTheListAndClearingRestoresTheAuthoredOne() {
    val state = RcPlayerState(document())
    assertEquals(RcNamedValue.FloatArrayValue(listOf(1f, 2f)), state.namedValue("USER:series"))

    state.setNamedValue("USER:series", RcNamedValue.FloatArrayValue(listOf(5f, 6f, 7f)))
    assertEquals(listOf(5f, 6f, 7f), state.floatValues(51)?.toList())

    state.clearNamedValue("USER:series")
    assertEquals(listOf(1f, 2f), state.floatValues(51)?.toList())
  }

  /**
   * A float array no float list could hold — more values than [RcFloatList.MAX_VALUES] — is
   * ignored, and the list stays as it was: the native Swift player and the iOS controller refuse
   * the same arrays. It must not throw, because a host's map reaches here from inside composition
   * (`RcComposePlayer`'s `applyHostValues`), where a throw crashes the app; AndroidX holds every
   * float list to the same size (DataListFloat.java:115).
   */
  @Test
  fun aFloatArrayNoFloatListCouldHoldIsIgnored() {
    val state = RcPlayerState(document())
    for (values in invalidFloatArrays) {
      state.setNamedValue("USER:series", RcNamedValue.FloatArrayValue(values))
      assertEquals(listOf(1f, 2f), state.floatValues(51)?.toList())
    }
    state.setNamedValue(
      "USER:series",
      RcNamedValue.FloatArrayValue(List(RcFloatList.MAX_VALUES) { 1f }),
    )
    assertEquals(RcFloatList.MAX_VALUES, state.floatValues(51)?.size)
  }

  /** A host's map seeded at construction is read the same way: an invalid array is ignored. */
  @Test
  fun anInvalidFloatArrayInTheSeededMapIsIgnored() {
    for (values in invalidFloatArrays) {
      val state =
        RcPlayerState(
          document(),
          namedValues = mapOf("USER:series" to RcNamedValue.FloatArrayValue(values)),
        )
      assertEquals(listOf(1f, 2f), state.floatValues(51)?.toList())
    }
  }

  /** A value of another type is still the caller's error, as before float arrays existed. */
  @Test
  fun aValueOfAnotherTypeStillThrows() {
    val state = RcPlayerState(document())
    assertFailsWith<IllegalArgumentException> {
      state.setNamedValue("USER:series", RcNamedValue.FloatValue(1f))
    }
  }

  private val invalidFloatArrays = listOf(List(RcFloatList.MAX_VALUES + 1) { 1f })

  /**
   * Any value is one a float list holds: AndroidX's `UpdateDynamicFloatList` writes NaN or an
   * infinity into a list as given, so a host's array may carry them too.
   */
  @Test
  fun aFloatArrayOfNonFiniteValuesReplacesTheList() {
    val state = RcPlayerState(document())
    val values = listOf(Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY, -0f)
    state.setNamedValue("USER:series", RcNamedValue.FloatArrayValue(values))
    assertEquals(values.map(Float::toRawBits), state.floatValues(51)?.map(Float::toRawBits))
  }

  @Test
  fun anUnqualifiedNameResolvesIntoTheUserNamespaceFirst() {
    val state = RcPlayerState(document())

    state.setNamedValue("enabled", RcNamedValue.BooleanValue(true))
    state.setNamedValue("series", RcNamedValue.FloatArrayValue(listOf(9f)))

    assertEquals(1, state.integer(50))
    assertEquals(listOf(9f), state.floatValues(51)?.toList())
    assertEquals(RcNamedValue.Integer(1), state.namedValue("enabled"))
  }

  @Test
  fun anUndeclaredUserNameFallsBackToThePlainOneAndAColonIsUsedAsIs() {
    val state = RcPlayerState(document())

    state.setNamedValue("plain", RcNamedValue.FloatValue(8f))
    state.setNamedValue("OTHER:plain", RcNamedValue.FloatValue(9f))

    assertEquals(RcNamedValue.FloatValue(8f), state.namedValue("plain"))
    assertEquals(RcNamedValue.FloatValue(9f), state.namedValue("OTHER:plain"))
  }

  @Test
  fun anOverrideOfADynamicListSurvivesTheDocumentReplayingItsDeclaration() {
    // The document owns a 2-slot dynamic list; the host overrides it with three values. Replaying
    // the declaration each frame resizes the document's list, and must not resize the override.
    val declaration = RcDynamicFloatList(60, RcFloatWord.literal(2f))
    val state =
      RcPlayerState(
        RcDocument(
          RcHeader(RcVersion(0, 1, 0)),
          listOf(declaration, RcNamedVariable(60, RcNamedVariable.FLOAT_ARRAY_TYPE, "USER:dyn")),
        ),
        mapOf("USER:dyn" to RcNamedValue.FloatArrayValue(listOf(1f, 2f, 3f))),
      )

    state.applyDataOperation(declaration)
    assertEquals(listOf(1f, 2f, 3f), state.floatValues(60)?.toList())

    state.clearNamedValue("dyn")
    state.applyDataOperation(declaration)
    assertEquals(listOf(0f, 0f), state.floatValues(60)?.toList())
  }

  /**
   * A named colour whose default is not a constant is the output of a colour expression. The
   * expression runs again whenever content state is replayed, and must not replace a host override:
   * AndroidX's `RemoteComposeState.updateColor` returns early for an overridden id.
   */
  @Test
  fun aColourOverrideSurvivesTheExpressionThatDefaultsItAndClearingHandsItBack() {
    val red = 0xffff0000.toInt()
    val blue = 0xff0000ff.toInt()
    val expression =
      RcColorExpression(
        61,
        RcColorExpression.ID_ID_INTERPOLATE,
        60,
        60,
        RcFloatWord.literal(0f).bits,
      )
    val state =
      RcPlayerState(
        RcDocument(
          RcHeader(RcVersion(0, 1, 0)),
          listOf(
            RcColorConstant(60, red),
            expression,
            RcNamedVariable(61, RcNamedVariable.COLOR_TYPE, "USER:accent"),
          ),
        ),
      )
    state.applyColorExpression(expression)
    assertEquals(red, state.color(61))

    state.setNamedValue("USER:accent", RcNamedValue.Color(blue))
    state.applyColorExpression(expression)
    assertEquals(blue, state.color(61))

    state.clearNamedValue("USER:accent")
    state.applyColorExpression(expression)
    assertEquals(red, state.color(61))
  }
}
