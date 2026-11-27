@file:Suppress("RestrictedApiAndroidX")

package ee.schimke.composeai.rcplayer.compat

import androidx.compose.remote.core.RemoteComposeState
import androidx.compose.remote.core.RemoteContext
import androidx.compose.remote.core.VariableSupport
import androidx.compose.remote.core.operations.DataDynamicListFloat
import androidx.compose.remote.core.operations.FloatExpression
import androidx.compose.remote.core.operations.ShaderData
import androidx.compose.remote.core.operations.TextFromFloat
import androidx.compose.remote.core.operations.TextLength
import androidx.compose.remote.core.operations.TextMerge
import androidx.compose.remote.core.operations.UpdateDynamicFloatList
import androidx.compose.remote.core.operations.Utils
import androidx.compose.remote.core.operations.utilities.AnimatedFloatExpression
import androidx.compose.remote.core.operations.utilities.ArrayAccess
import androidx.compose.remote.core.operations.utilities.DataMap
import ee.schimke.composeai.rcplayer.protocol.RcDocument
import ee.schimke.composeai.rcplayer.protocol.RcDynamicFloatList
import ee.schimke.composeai.rcplayer.protocol.RcFloatConstant
import ee.schimke.composeai.rcplayer.protocol.RcFloatList
import ee.schimke.composeai.rcplayer.protocol.RcFloatWord
import ee.schimke.composeai.rcplayer.protocol.RcHeader
import ee.schimke.composeai.rcplayer.protocol.RcNamedVariable
import ee.schimke.composeai.rcplayer.protocol.RcTextData
import ee.schimke.composeai.rcplayer.protocol.RcTextFromFloat
import ee.schimke.composeai.rcplayer.protocol.RcTextLength
import ee.schimke.composeai.rcplayer.protocol.RcTextMerge
import ee.schimke.composeai.rcplayer.protocol.RcUpdateDynamicFloatList
import ee.schimke.composeai.rcplayer.protocol.RcVersion
import ee.schimke.composeai.rcplayer.runtime.RcFloatExpressionEvaluator
import ee.schimke.composeai.rcplayer.runtime.RcNamedValue
import ee.schimke.composeai.rcplayer.runtime.RcPlayerState
import java.io.File
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import org.junit.Test

/**
 * The host values AndroidX accepts, run through AndroidX remote-core itself, and the Kotlin player
 * held to the same answers. AndroidX is the arbiter: its `setNamed*Override` take any float (NaN
 * and infinities included), any string and any integer, and store them as `RemoteComposeState`
 * does.
 *
 * Where AndroidX throws on a value a host may send, the players must not crash, and each test pins
 * what they do instead:
 * - a float expression that reads a NaN from a variable takes it for an operator and underflows its
 *   stack (`AnimatedFloatExpression.eval`); the players treat it as the value it is, which is what
 *   AndroidX does with a NaN the expression computes itself;
 * - a `TextMerge` longer than 16K throws; the players leave the merged text as it was;
 * - a dynamic float list sized outside 0..2000 throws; the players have no list at that id.
 *
 * The operator and text tables also go to `HOST_VALUE_FIXTURE` for the native Swift player's
 * `NativeSwiftHostValueParityTests`. Run with `-Prc.hostValueParity.update=true` to rewrite it; it
 * fails when the committed fixture differs from what AndroidX computes now.
 */
class AndroidxHostValueParityTest {

  @Test
  fun aHostFloatIsStoredWithJavasIntegerView() {
    for (value in EDGE_FLOATS) {
      val androidx = RemoteComposeState().apply { overrideFloat(ID, value) }
      val kotlin = RcPlayerState(floatDocument())
      kotlin.setNamedValue("USER:x", RcNamedValue.FloatValue(value))
      assertSameFloat(androidx.getFloat(ID), kotlin.float(ID)!!, "float $value")
      assertEquals(androidx.getInteger(ID), kotlin.integer(ID), "integer view of $value")
    }
  }

  /**
   * AndroidX's `!=` notifies a variable's listeners on every NaN write (NaN is never equal to
   * itself) and on no write of -0.0 over 0.0. Stored values are unaffected either way.
   */
  @Test
  fun androidxNotifiesOnEveryNaNWriteAndOnNoSignedZeroWrite() {
    val state = RemoteComposeState()
    state.setContext(StateContext(state))
    var notified = 0
    state.listenToVar(ID, CountingListener { notified += 1 })
    state.overrideFloat(ID, Float.NaN)
    state.overrideFloat(ID, Float.NaN)
    assertEquals(2, notified)
    state.overrideFloat(ID, 0f)
    notified = 0
    state.overrideFloat(ID, -0f)
    assertEquals(0, notified)
    assertEquals(0f.toRawBits(), state.getFloat(ID).toRawBits())
  }

  /** The AndroidX defect the players do not copy: a NaN operand read from a variable. */
  @Test
  fun androidxTakesAVariablesNaNForAnOperator() {
    val state = RemoteComposeState().apply { overrideFloat(ID, Float.NaN) }
    val context = StateContext(state)
    val expression =
      FloatExpression(OUT, floatArrayOf(Utils.asNan(ID), 1f, AnimatedFloatExpression.ADD), null)
    expression.registerListening(context)
    expression.updateVariables(context)
    assertFailsWith<RuntimeException> { expression.apply(context) }
    // Kotlin: the value it is.
    val words = listOf(reference(1), RcFloatWord.literal(1f), operator(1))
    assertTrue(RcFloatExpressionEvaluator().evaluate(words) { Float.NaN }.isNaN())
  }

  /**
   * Every operator over every combination of three edge operands. AndroidX gets each operand
   * computed on its stack (`0 0 /` for NaN, `1 0 /` for +inf), where a NaN is a value; the Kotlin
   * evaluator reads each from a variable, as a host value reaches it. Operators AndroidX throws on
   * for these operands (the array operators, with no array; `A_SUM_TILL` past its limit) must not
   * throw in Kotlin, which reads 0 there.
   */
  @Test
  fun everyOperatorTreatsNonFiniteOperandsAsAndroidXDoes() {
    val table = operatorTable()
    var compared = 0
    for ((operator, results) in table) {
      for ((index, operands) in OPERAND_TRIPLES.withIndex()) {
        val kotlin = evaluateInKotlin(operator, operands)
        val androidx = results[index] ?: continue
        assertSameFloat(androidx, kotlin, "operator $operator over ${operands.toList()}")
        compared += 1
      }
    }
    assertTrue(compared > 10_000, "compared $compared")
  }

  @Test
  fun textFromFloatFormatsNonFiniteValuesAsAndroidXDoes() {
    for (row in textFromFloatTable()) {
      val kotlin = RcPlayerState(floatDocument())
      kotlin.setNamedValue("USER:x", RcNamedValue.FloatValue(row.value))
      kotlin.applyTextOperation(
        RcTextFromFloat(OUT, reference(ID), row.before, row.after, row.flags),
      )
      val label = "format ${row.value} ${row.before}.${row.after} ${row.flags}"
      assertEquals(row.text, kotlin.text(OUT), label)
    }
  }

  /** `TextLength` counts UTF-16 units (Java's `String.length`), however long the host's string. */
  @Test
  fun textLengthOfALongHostStringIsItsUtf16Length() {
    for (text in LONG_TEXTS) {
      val state = RemoteComposeState()
      val context = StateContext(state)
      context.loadText(ID, text)
      TextLength(OUT, ID).apply(context)
      val kotlin = RcPlayerState(textDocument())
      kotlin.setNamedValue("USER:s", RcNamedValue.Text(text))
      kotlin.applyTextOperation(RcTextLength(OUT, ID))
      assertEquals(state.getFloat(OUT), kotlin.float(OUT), "length of ${text.length}")
    }
  }

  /**
   * A merge within 16K is the concatenation on both; a longer one throws in AndroidX
   * (`TextMerge.MAX_TEXT_LENGTH`) and leaves the merged text as it was in the Kotlin player.
   */
  @Test
  fun aMergeOverAndroidXsLimitThrowsThereAndChangesNothingHere() {
    for (text in LONG_TEXTS) {
      val state = RemoteComposeState()
      val context = StateContext(state)
      context.loadText(ID, text)
      context.loadText(ID + 1, "!")
      val merge = TextMerge(OUT, ID, ID + 1)
      val kotlin = RcPlayerState(textDocument())
      kotlin.setNamedValue("USER:s", RcNamedValue.Text(text))
      kotlin.applyTextOperation(RcTextMerge(OUT, ID, ID + 1))
      if (text.length + 1 <= RcTextMerge.MAX_LENGTH) {
        merge.apply(context)
        assertEquals(context.getText(OUT), kotlin.text(OUT))
      } else {
        assertFailsWith<RuntimeException> { merge.apply(context) }
        assertEquals(TEXT_BEFORE_MERGE, kotlin.text(OUT))
      }
    }
  }

  /**
   * A dynamic list sized by a host float: NaN is a zero-length list (`(int) NaN`), and a size
   * outside 0..2000 (an infinity, a negative) throws in AndroidX and leaves the Kotlin player with
   * no list at that id.
   */
  @Test
  fun aDynamicListSizedByANonFiniteHostFloat() {
    for (length in EDGE_FLOATS) {
      val state = RemoteComposeState().apply { overrideFloat(ID, length) }
      val context = StateContext(state)
      val list = DataDynamicListFloat(LIST, Utils.asNan(ID))
      val androidx = runCatching {
        list.registerListening(context)
        list.updateVariables(context)
        state.getDynamicFloats(LIST)!!.size
      }
      val kotlin = RcPlayerState(dynamicListDocument())
      kotlin.setNamedValue("USER:x", RcNamedValue.FloatValue(length))
      kotlin.applyDataOperation(RcDynamicFloatList(LIST, reference(ID)))
      assertEquals(androidx.getOrNull(), kotlin.floatValues(LIST)?.size, "length $length")
    }
  }

  /** A list element may be any float: AndroidX's `UpdateDynamicFloatList` writes it as given. */
  @Test
  fun aDynamicListElementTakesANonFiniteHostFloat() {
    for (value in EDGE_FLOATS) {
      val state = RemoteComposeState().apply { overrideFloat(ID, value) }
      val context = StateContext(state)
      DataDynamicListFloat(LIST, 2f).apply {
        registerListening(context)
        updateVariables(context)
      }
      UpdateDynamicFloatList(LIST, 1f, Utils.asNan(ID)).apply {
        updateVariables(context)
        apply(context)
      }
      val kotlin = RcPlayerState(dynamicListDocument())
      kotlin.setNamedValue("USER:x", RcNamedValue.FloatValue(value))
      kotlin.applyDataOperation(RcDynamicFloatList(LIST, RcFloatWord.literal(2f)))
      kotlin.applyDataOperation(
        RcUpdateDynamicFloatList(LIST, RcFloatWord.literal(1f), reference(ID)),
      )
      assertContentEquals(
        state.getDynamicFloats(LIST)!!.map(Float::toRawBits),
        kotlin.floatValues(LIST)!!.map(Float::toRawBits),
        "element $value",
      )
    }
  }

  /** A host float array may hold any float, up to the 2000 every float list is capped at. */
  @Test
  fun aHostFloatArrayHoldsNonFiniteValuesUpToTheListCap() {
    val state = RcPlayerState(floatArrayDocument())
    val values = EDGE_FLOATS.toList()
    state.setNamedValue("USER:series", RcNamedValue.FloatArrayValue(values))
    assertContentEquals(
      values.map(Float::toRawBits),
      state.floatValues(LIST)!!.map(Float::toRawBits),
    )
    state.setNamedValue(
      "USER:series",
      RcNamedValue.FloatArrayValue(List(RcFloatList.MAX_VALUES + 1) { 1f }),
    )
    assertEquals(values.size, state.floatValues(LIST)!!.size)
  }

  @Test
  fun theSwiftFixtureMatchesWhatAndroidXComputes() {
    val path = File(requireNotNull(System.getProperty(FIXTURE_PROPERTY)) { FIXTURE_PROPERTY })
    val expected = fixture()
    if (System.getProperty(UPDATE_PROPERTY) == "true") path.writeText(expected)
    assertEquals(expected, path.readText(), "regenerate with -P$UPDATE_PROPERTY=true")
  }

  // --- AndroidX tables ---

  /** Each operator's AndroidX result for each of [OPERAND_TRIPLES]; null where AndroidX threw. */
  private fun operatorTable(): List<Pair<Int, List<Float?>>> =
    (RcFloatExpressionEvaluator.OFFSET + 1..RcFloatExpressionEvaluator.LAST_OP).mapNotNull { id ->
      val operator = Float.fromBits(id or NAN_SIGN)
      val results = OPERAND_TRIPLES.map { operands ->
        val words = operands.flatMap(::produce) + operator
        runCatching { evaluateOnStack(words) }.getOrNull()
      }
      // Random operators are not a function of their operands; nothing to compare.
      val again = OPERAND_TRIPLES.map { operands ->
        runCatching { evaluateOnStack(operands.flatMap(::produce) + operator) }.getOrNull()
      }
      if (
        results.zip(again).any { (a, b) ->
          a?.toRawBits() != b?.toRawBits() && !(a!!.isNaN() && b!!.isNaN())
        }
      ) {
        null
      } else {
        id to results
      }
    }

  /** [operator] over [operands], each read from a variable as a host value reaches it. */
  private fun evaluateInKotlin(operator: Int, operands: FloatArray): Float =
    RcFloatExpressionEvaluator().evaluate(
      listOf(reference(1), reference(2), reference(3), operator(operator)),
    ) {
      operands[(it.bits and 0xffff) - 1]
    }

  private fun evaluateOnStack(words: List<Float>): Float {
    val state = RemoteComposeState()
    return AnimatedFloatExpression().eval(state, words.toFloatArray(), words.size)
  }

  /** The words that leave [value] on AndroidX's stack as a value, not an operator. */
  private fun produce(value: Float): List<Float> =
    when {
      value.isNaN() -> listOf(0f, 0f, AnimatedFloatExpression.DIV)
      value == Float.POSITIVE_INFINITY -> listOf(1f, 0f, AnimatedFloatExpression.DIV)
      value == Float.NEGATIVE_INFINITY -> listOf(-1f, 0f, AnimatedFloatExpression.DIV)
      else -> listOf(value)
    }

  /** [value] is what the host wrote; [stored] what AndroidX's state then holds and formats. */
  private data class TextRow(
    val value: Float,
    val stored: Float,
    val before: Int,
    val after: Int,
    val flags: Int,
    val text: String,
  )

  private fun textFromFloatTable(): List<TextRow> = EDGE_FLOATS.flatMap { value ->
    TEXT_FORMATS.mapNotNull { (before, after, flags) ->
      val state = RemoteComposeState().apply { overrideFloat(ID, value) }
      val context = StateContext(state)
      runCatching {
        TextFromFloat(OUT, Utils.asNan(ID), before.toShort(), after.toShort(), flags).apply {
          registerListening(context)
          apply(context)
        }
        context.getText(OUT)
      }
        .getOrNull()
        ?.let { TextRow(value, state.getFloat(ID), before, after, flags, it) }
    }
  }

  private fun fixture(): String = buildString {
    appendLine("# Generated by AndroidxHostValueParityTest from AndroidX remote-core. Do not edit.")
    appendLine("format\t$FIXTURE_FORMAT")
    appendLine("mergeLimit\t${RcTextMerge.MAX_LENGTH}")
    appendLine("operands\t" + EDGE_OPERANDS.joinToString("\t") { hex(it) })
    // Each result is AndroidX's; where AndroidX throws, the Kotlin player's, marked `k`.
    for ((operator, results) in operatorTable()) {
      append("operator\t").append(operator - RcFloatExpressionEvaluator.OFFSET)
      results.forEachIndexed { index, result ->
        append('\t')
        append(result?.let(::hex) ?: "k" + hex(evaluateInKotlin(operator, OPERAND_TRIPLES[index])))
      }
      appendLine()
    }
    for (row in textFromFloatTable()) {
      appendLine("text\t${hex(row.stored)}\t${row.before}\t${row.after}\t${row.flags}\t${row.text}")
    }
  }

  // --- Kotlin documents ---

  private fun floatDocument() =
    document(
      RcFloatConstant(ID, RcFloatWord.literal(0f)),
      RcNamedVariable(ID, RcNamedVariable.FLOAT_TYPE, "USER:x"),
    )

  private fun dynamicListDocument() = floatDocument()

  private fun textDocument() =
    document(
      RcTextData(ID, ""),
      RcNamedVariable(ID, RcNamedVariable.STRING_TYPE, "USER:s"),
      RcTextData(ID + 1, "!"),
      RcTextData(OUT, TEXT_BEFORE_MERGE),
    )

  private fun floatArrayDocument() =
    document(
      RcFloatList(LIST, listOf(RcFloatWord.literal(1f))),
      RcNamedVariable(LIST, RcNamedVariable.FLOAT_ARRAY_TYPE, "USER:series"),
    )

  private fun document(vararg operations: ee.schimke.composeai.rcplayer.protocol.RcOperation) =
    RcDocument(RcHeader(RcVersion(0, 1, 0)), operations.toList())

  private fun assertSameFloat(expected: Float, actual: Float, message: String) {
    if (expected.isNaN()) assertTrue(actual.isNaN(), "$message: expected NaN, got $actual")
    else assertEquals(expected.toRawBits(), actual.toRawBits(), "$message: $expected vs $actual")
  }

  private fun reference(id: Int) = RcFloatWord(id or NAN_SIGN)

  private fun operator(id: Int) = RcFloatWord(id or NAN_SIGN)

  private fun interface CountingListener : VariableSupport {
    fun changed()

    override fun registerListening(context: RemoteContext) = Unit

    override fun updateVariables(context: RemoteContext) = Unit

    override fun markDirty() = changed()
  }

  companion object {
    private const val ID = 42
    private const val OUT = 60
    private const val LIST = 70
    private const val NAN_SIGN = 0xff800000.toInt()
    private const val FIXTURE_FORMAT = "host-value-parity-v1"
    const val FIXTURE_PROPERTY: String = "rc.hostValueParity.fixture"
    const val UPDATE_PROPERTY: String = "rc.hostValueParity.update"

    private const val TEXT_BEFORE_MERGE = "before"

    private val EDGE_FLOATS =
      floatArrayOf(
        Float.NaN,
        Float.POSITIVE_INFINITY,
        Float.NEGATIVE_INFINITY,
        -0f,
        1.75f,
        -2.75f,
        3e9f,
        -3e9f,
        Float.MAX_VALUE,
        Float.MIN_VALUE,
      )

    private val EDGE_OPERANDS =
      floatArrayOf(Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY, 0f, -0f, 1.5f)

    private val OPERAND_TRIPLES: List<FloatArray> = EDGE_OPERANDS.flatMap { a ->
      EDGE_OPERANDS.flatMap { b -> EDGE_OPERANDS.map { c -> floatArrayOf(a, b, c) } }
    }

    private val TEXT_FORMATS: List<Triple<Int, Int, Int>> =
      listOf(0, 5, 15, 16, 256, 512, 1024, 1024 or 5, 4096).flatMap { flags ->
        listOf(Triple(2, 2, flags), Triple(6, 3, flags))
      }

    private val LONG_TEXTS: List<String> =
      listOf(
        "x".repeat(4_001),
        "x".repeat(RcTextMerge.MAX_LENGTH - 1),
        "x".repeat(RcTextMerge.MAX_LENGTH),
        "x".repeat(1_000_000),
        // Four bytes of UTF-8 and two UTF-16 units each.
        "😀".repeat(10_000),
      )

    private fun hex(value: Float): String =
      (if (value.isNaN()) Float.NaN else value).toRawBits().toUInt().toString(16).padStart(8, '0')
  }
}

/** Just enough of a `RemoteContext` to run data operations against a `RemoteComposeState`. */
private class StateContext(state: RemoteComposeState) : RemoteContext() {
  init {
    mRemoteComposeState = state
  }

  private val state: RemoteComposeState
    get() = mRemoteComposeState

  override fun loadPathData(id: Int, winding: Int, data: FloatArray) = Unit

  override fun getPathData(id: Int): FloatArray? = null

  override fun loadVariableName(name: String, id: Int, type: Int) = Unit

  override fun loadColor(id: Int, color: Int) = state.updateColor(id, color)

  override fun setNamedColorOverride(name: String, color: Int) = Unit

  override fun setNamedStringOverride(name: String, value: String) = Unit

  override fun clearNamedStringOverride(name: String) = Unit

  override fun setNamedBooleanOverride(name: String, value: Boolean) = Unit

  override fun clearNamedBooleanOverride(name: String) = Unit

  override fun setNamedIntegerOverride(name: String, value: Int) = Unit

  override fun clearNamedIntegerOverride(name: String) = Unit

  override fun setNamedFloatOverride(name: String, value: Float) = Unit

  override fun clearNamedFloatOverride(name: String) = Unit

  override fun setNamedLong(name: String, value: Long) = Unit

  override fun setNamedDataOverride(name: String, value: Any) = Unit

  override fun clearNamedDataOverride(name: String) = Unit

  override fun addCollection(id: Int, collection: ArrayAccess) = state.addCollection(id, collection)

  override fun putDataMap(id: Int, map: DataMap) = state.putDataMap(id, map)

  override fun getDataMap(id: Int): DataMap? = state.getDataMap(id)

  override fun runAction(id: Int, metadata: String) = Unit

  override fun runNamedAction(id: Int, value: Any?) = Unit

  override fun putObject(id: Int, value: Any) = state.updateObject(id, value)

  override fun getObject(id: Int): Any? = state.getObject(id)

  override fun hapticEffect(type: Int) = Unit

  override fun loadBitmap(
    imageId: Int,
    encoding: Short,
    type: Short,
    width: Int,
    height: Int,
    bitmap: ByteArray,
  ) = Unit

  override fun loadText(id: Int, text: String) = state.updateData(id, text)

  override fun getText(id: Int): String? = state.getFromId(id) as String?

  override fun loadFloat(id: Int, value: Float) = state.updateFloat(id, value)

  override fun overrideFloat(id: Int, value: Float) = state.overrideFloat(id, value)

  override fun loadInteger(id: Int, value: Int) = state.updateInteger(id, value)

  override fun overrideInteger(id: Int, value: Int) = state.overrideInteger(id, value)

  override fun overrideText(id: Int, valueId: Int) = Unit

  override fun loadAnimatedFloat(id: Int, animatedFloat: FloatExpression) = Unit

  override fun loadShader(id: Int, value: ShaderData) = Unit

  override fun getFloat(id: Int): Float = state.getFloat(id)

  override fun getInteger(id: Int): Int = state.getInteger(id)

  override fun getLong(id: Int): Long = 0L

  override fun getColor(id: Int): Int = state.getColor(id)

  override fun listensTo(id: Int, variableSupport: VariableSupport) =
    state.listenToVar(id, variableSupport)

  override fun updateOps(): Int = 0

  override fun getShader(id: Int): ShaderData? = null

  override fun addClickArea(
    id: Int,
    contentDescription: Int,
    left: Float,
    top: Float,
    right: Float,
    bottom: Float,
    metadataId: Int,
  ) = Unit
}
