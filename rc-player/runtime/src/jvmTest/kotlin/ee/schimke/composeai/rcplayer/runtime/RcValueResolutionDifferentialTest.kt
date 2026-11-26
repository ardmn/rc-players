package ee.schimke.composeai.rcplayer.runtime

import ee.schimke.composeai.rcplayer.protocol.RcBoxLayout
import ee.schimke.composeai.rcplayer.protocol.RcClickModifier
import ee.schimke.composeai.rcplayer.protocol.RcColorAttribute
import ee.schimke.composeai.rcplayer.protocol.RcColorConstant
import ee.schimke.composeai.rcplayer.protocol.RcColorExpression
import ee.schimke.composeai.rcplayer.protocol.RcDataMapEntry
import ee.schimke.composeai.rcplayer.protocol.RcDataMapLookup
import ee.schimke.composeai.rcplayer.protocol.RcDocument
import ee.schimke.composeai.rcplayer.protocol.RcDocumentCodec
import ee.schimke.composeai.rcplayer.protocol.RcFloatConstant
import ee.schimke.composeai.rcplayer.protocol.RcFloatExpression
import ee.schimke.composeai.rcplayer.protocol.RcFloatWord
import ee.schimke.composeai.rcplayer.protocol.RcHeader
import ee.schimke.composeai.rcplayer.protocol.RcIdList
import ee.schimke.composeai.rcplayer.protocol.RcIdLookup
import ee.schimke.composeai.rcplayer.protocol.RcIdMap
import ee.schimke.composeai.rcplayer.protocol.RcIntegerConstant
import ee.schimke.composeai.rcplayer.protocol.RcIntegerExpression
import ee.schimke.composeai.rcplayer.protocol.RcLayoutContent
import ee.schimke.composeai.rcplayer.protocol.RcNamedVariable
import ee.schimke.composeai.rcplayer.protocol.RcNoArg
import ee.schimke.composeai.rcplayer.protocol.RcOpcodes
import ee.schimke.composeai.rcplayer.protocol.RcOperation
import ee.schimke.composeai.rcplayer.protocol.RcRootLayout
import ee.schimke.composeai.rcplayer.protocol.RcSystemVariables
import ee.schimke.composeai.rcplayer.protocol.RcTextData
import ee.schimke.composeai.rcplayer.protocol.RcTextFromFloat
import ee.schimke.composeai.rcplayer.protocol.RcTextLength
import ee.schimke.composeai.rcplayer.protocol.RcTextMerge
import ee.schimke.composeai.rcplayer.protocol.RcValueFloatChangeAction
import ee.schimke.composeai.rcplayer.protocol.RcValueFloatExpressionChangeAction
import ee.schimke.composeai.rcplayer.protocol.RcValueIntegerChangeAction
import ee.schimke.composeai.rcplayer.protocol.RcValueIntegerExpressionChangeAction
import ee.schimke.composeai.rcplayer.protocol.RcVersion
import java.io.File
import java.time.Instant
import java.time.ZoneOffset
import java.util.Base64
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.fail

/**
 * The Kotlin player as the oracle for the native Swift session's value resolution.
 *
 * Builds [DOCUMENTS] documents from [SplitMix64] seeds — float, integer and colour constants and
 * expressions, colour attributes, id and data-map lookups, text merges, lengths and conversions,
 * written over one small pool of ids so that one id is often written twice, an integer and a float
 * share an id, and an operation reads an id an earlier or a later one writes; expressions also read
 * the player's clock and density — and drives each through [RcPlayerState] with a sequence of
 * frames, host writes (by id and by name) and clicks whose actions write the same pool. A frame is
 * `beginFrame` then one `applyLayoutContentStateOperations` pass, as the Compose player runs one; a
 * host write or a click runs no pass. After every step every observed id's float, integer, text and
 * colour is recorded in `Tests/RcNativePlayerCoreTests/Fixtures/value-resolution-differential.json`
 * with the document's bytes. The Swift suite `NativeSwiftValueResolutionDifferentialTests` replays
 * each sequence through `NativeSwiftDocumentSession` and must reach the same views at every step.
 *
 * Only operations both players resolve in a frame are generated, at the document's top level (where
 * `applyLayoutContentStateOperations` reaches them); conditionals, loops, animations and the draw
 * pass's operations are not, and no value is generated that the Swift session would refuse (a
 * non-finite float, a stack deeper than AndroidX's 128).
 *
 * This test fails when the committed fixture is not what the Kotlin player produces now. After a
 * deliberate change to the generator or the Kotlin player, rewrite it — the same run then passes —
 * with `scripts/agent-gradle.sh :rc-player-runtime:jvmTest --tests
 * '*RcValueResolutionDifferentialTest*' -Prc.valueResolutionDifferential.update=true`, then run the
 * Swift suite.
 */
class RcValueResolutionDifferentialTest {
  @Test
  fun theCommittedFixtureIsWhatTheKotlinPlayerProduces() {
    val json = fixture()
    val file =
      File(
        requireNotNull(System.getProperty(FIXTURE_PROPERTY)) {
          "$FIXTURE_PROPERTY is unset; run this through Gradle"
        },
      )
    val update =
      requireNotNull(System.getProperty(UPDATE_PROPERTY)) {
          "$UPDATE_PROPERTY is unset; run this through Gradle"
        }
        .toBooleanStrict()
    if (update) file.writeText(json)
    if (!file.isFile) fail("$file is missing; see this class's KDoc")
    val committed = file.readText().replace("\r\n", "\n").lines()
    val generated = json.lines()
    val line = committed.indices.firstOrNull { committed[it] != generated.getOrNull(it) }
    if (line != null || committed.size != generated.size) {
      val at = line ?: minOf(committed.size, generated.size)
      fail(
        "${file.name} is stale; see this class's KDoc. First difference at line ${at + 1}:\n" +
          "  committed: ${committed.getOrNull(at)?.take(200)}\n" +
          "  generated: ${generated.getOrNull(at)?.take(200)}",
      )
    }
  }

  /** The generator reaches every kind of operation and step, so a change cannot drop one. */
  @Test
  fun theGeneratedDocumentsCoverEveryKind() {
    val cases = (0 until DOCUMENTS).map { generate(SplitMix64(FIRST_SEED + it)) }
    assertEquals(OperationKind.entries.toSet(), cases.flatMap { it.kinds }.toSet())
    assertEquals(StepKind.entries.toSet(), cases.flatMap { it.steps }.map { it.kind }.toSet())
  }

  /** What a generated operation is, for [theGeneratedDocumentsCoverEveryKind]. */
  private enum class OperationKind {
    FLOAT_CONSTANT,
    INTEGER_CONSTANT,
    FLOAT_EXPRESSION,
    INTEGER_EXPRESSION,
    ID_LOOKUP,
    DATA_MAP_LOOKUP,
    TEXT_MERGE,
    TEXT_LENGTH,
    TEXT_FROM_FLOAT,
    COLOR_EXPRESSION,
    COLOR_ATTRIBUTE,
  }

  /**
   * A kind of step and the letter the fixture spells it with; the Swift suite's step kind reads the
   * same letters and fails on one it does not know.
   */
  private enum class StepKind(val letter: String) {
    FRAME("P"),
    SET_FLOAT_BY_ID("F"),
    SET_NAMED_FLOAT("N"),
    SET_NAMED_INTEGER("I"),
    CLICK("K"),
  }

  /**
   * One step. A frame's [argument] is the index of its time in [FRAME_TIMES]; a write's is the
   * value (a float as its bits); [id] is the id a by-id write targets.
   */
  private data class Step(val kind: StepKind, val argument: Int, val id: Int = 0)

  private class Case(
    val seed: Long,
    val document: RcDocument,
    val kinds: Set<OperationKind>,
    val steps: List<Step>,
  )

  private fun generate(random: SplitMix64): Case {
    val operations = mutableListOf<RcOperation>()
    val kinds = mutableSetOf<OperationKind>()
    val floatExpressionIds = mutableListOf<Int>()
    val integerExpressionIds = mutableListOf<Int>()

    fun numeric(): Int =
      if (random.nextInt(8) == 0) SYSTEM_IDS[random.nextInt(SYSTEM_IDS.size)]
      else NUMERIC_IDS[random.nextInt(NUMERIC_IDS.size)]

    fun target(): Int =
      if (random.nextInt(16) == 0) SYSTEM_IDS[random.nextInt(SYSTEM_IDS.size)]
      else NUMERIC_IDS[random.nextInt(NUMERIC_IDS.size)]

    fun quarter(range: Int): Float = random.nextInt(-range, range + 1) / 4f

    fun floatOperand(): RcFloatWord =
      if (random.nextBoolean()) reference(numeric()) else RcFloatWord.literal(quarter(16))

    operations += TEXT_IDS.mapIndexed { index, id -> RcTextData(id, TEXTS[index]) }
    operations += COLOR_IDS.mapIndexed { index, id -> RcColorConstant(id, COLORS[index]) }
    operations += RcIdList(ID_LIST, LOOKUP_IDS)
    // The map's keys and values are ids nothing else writes: the Kotlin player refuses a missing
    // key or an unset value, where the Swift session leaves the output as it was.
    operations += DATA_MAP_KEYS.mapIndexed { index, id -> RcTextData(id, TEXTS[index]) }
    operations += RcFloatConstant(DATA_MAP_FLOAT, RcFloatWord.literal(2.75f))
    operations += RcIntegerConstant(DATA_MAP_INTEGER, 7)
    operations +=
      RcIdMap(
        DATA_MAP,
        listOf(
          RcDataMapEntry(TEXTS[0], RcIdMap.TYPE_FLOAT, DATA_MAP_FLOAT),
          RcDataMapEntry(TEXTS[1], RcIdMap.TYPE_INT, DATA_MAP_INTEGER),
        ),
      )
    // Every id is declared before anything reads it: the Kotlin player resolves a reference to an
    // unset id to the reference's own NaN bits, the Swift session to 0 (and its evaluator refuses a
    // non-finite result), which is a difference in how a missing value reads, not in order.
    operations += NUMERIC_IDS.map { id ->
      if (random.nextBoolean()) RcFloatConstant(id, RcFloatWord.literal(quarter(32)))
      else RcIntegerConstant(id, random.nextInt(-20, 21))
    }
    repeat(random.nextInt(6, 18)) {
      val kind = OperationKind.entries[random.nextInt(OperationKind.entries.size)]
      kinds += kind
      operations +=
        when (kind) {
          OperationKind.FLOAT_CONSTANT ->
            RcFloatConstant(target(), RcFloatWord.literal(quarter(32)))
          OperationKind.INTEGER_CONSTANT -> RcIntegerConstant(target(), random.nextInt(-20, 21))
          OperationKind.FLOAT_EXPRESSION -> {
            // `a (b op)*`. A product's second operand is a literal, so a cycle multiplying itself
            // over a sequence of frames stays finite.
            val words = mutableListOf(floatOperand())
            repeat(random.nextInt(3)) {
              val operator = FLOAT_OPERATORS[random.nextInt(FLOAT_OPERATORS.size)]
              words +=
                if (operator == FLOAT_MUL) RcFloatWord.literal(MULTIPLIERS[random.nextInt(3)])
                else floatOperand()
              words += RcFloatExpressionEvaluator.operatorWord(operator)
            }
            // One float expression per id: the Kotlin player memoises an expression's inputs by
            // the id it writes, so a second expression at that id is skipped while the first's
            // inputs stand still (a Kotlin bug, not an order the Swift session should copy).
            val id = generateSequence { target() }.take(8).firstOrNull { it !in floatExpressionIds }
            if (id == null) {
              RcFloatConstant(target(), RcFloatWord.literal(quarter(32)))
            } else {
              floatExpressionIds += id
              RcFloatExpression(id, words, null)
            }
          }
          OperationKind.INTEGER_EXPRESSION -> {
            val values = mutableListOf<Int>()
            var mask = 0
            fun operand() {
              if (random.nextBoolean()) {
                mask = mask or (1 shl values.size)
                values += numeric()
              } else {
                values += random.nextInt(-10, 11)
              }
            }
            operand()
            repeat(random.nextInt(3)) {
              operand()
              mask = mask or (1 shl values.size)
              values += INTEGER_OPERATORS[random.nextInt(INTEGER_OPERATORS.size)]
            }
            val id = target()
            integerExpressionIds += id
            RcIntegerExpression(id, mask, values)
          }
          OperationKind.ID_LOOKUP ->
            RcIdLookup(
              target(),
              ID_LIST,
              RcFloatWord.literal(random.nextInt(LOOKUP_IDS.size).toFloat()),
            )
          OperationKind.DATA_MAP_LOOKUP ->
            RcDataMapLookup(target(), DATA_MAP, DATA_MAP_KEYS[random.nextInt(DATA_MAP_KEYS.size)])
          OperationKind.TEXT_MERGE ->
            RcTextMerge(
              TEXT_IDS[random.nextInt(TEXT_IDS.size)],
              TEXT_IDS[random.nextInt(TEXT_IDS.size)],
              TEXT_IDS[random.nextInt(TEXT_IDS.size)],
            )
          OperationKind.TEXT_LENGTH ->
            RcTextLength(target(), TEXT_IDS[random.nextInt(TEXT_IDS.size)])
          OperationKind.TEXT_FROM_FLOAT ->
            RcTextFromFloat(TEXT_IDS[random.nextInt(TEXT_IDS.size)], reference(numeric()), 3, 2, 0)
          OperationKind.COLOR_EXPRESSION ->
            RcColorExpression(
              COLOR_IDS[random.nextInt(COLOR_IDS.size)],
              RcColorExpression.ID_ID_INTERPOLATE,
              COLOR_IDS[random.nextInt(COLOR_IDS.size)],
              COLOR_IDS[random.nextInt(COLOR_IDS.size)],
              RcFloatWord.literal(random.nextInt(5) / 4f).bits,
            )
          OperationKind.COLOR_ATTRIBUTE ->
            RcColorAttribute(target(), COLOR_IDS[random.nextInt(COLOR_IDS.size)], random.nextInt(7))
        }
    }
    operations += RcNamedVariable(NAMED_FLOAT_ID, RcNamedVariable.FLOAT_TYPE, NAMED_FLOAT)
    operations += RcNamedVariable(NAMED_INTEGER_ID, RcNamedVariable.INT_TYPE, NAMED_INTEGER)

    val actions =
      List(random.nextInt(1, 4)) {
        when (random.nextInt(4)) {
          0 -> RcValueIntegerChangeAction(target(), random.nextInt(-20, 21))
          1 -> RcValueFloatChangeAction(target(), RcFloatWord.literal(quarter(32)))
          2 ->
            integerExpressionIds.randomOrNull(random)?.let {
              RcValueIntegerExpressionChangeAction(target().toLong(), it.toLong())
            } ?: RcValueIntegerChangeAction(target(), random.nextInt(-20, 21))
          else ->
            floatExpressionIds.randomOrNull(random)?.let {
              RcValueFloatExpressionChangeAction(target(), it)
            } ?: RcValueFloatChangeAction(target(), RcFloatWord.literal(quarter(32)))
        }
      }
    val document =
      RcDocument(
        RcHeader(RcVersion(1, 1, 0), legacyWidth = 100, legacyHeight = 100, modern = false),
        operations +
          listOf(RcRootLayout(1), RcLayoutContent(2), RcBoxLayout(CLICK_COMPONENT, -1, 1, 1)) +
          listOf(RcClickModifier) +
          actions +
          listOf(CONTAINER_END, RcLayoutContent(4), CONTAINER_END, CONTAINER_END) +
          listOf(CONTAINER_END, CONTAINER_END),
      )
    val steps = buildList {
      add(Step(StepKind.FRAME, 0))
      repeat(random.nextInt(4, 10)) {
        val kind = StepKind.entries[random.nextInt(StepKind.entries.size)]
        add(
          when (kind) {
            StepKind.FRAME -> Step(kind, random.nextInt(FRAME_TIMES.size))
            StepKind.SET_FLOAT_BY_ID -> Step(kind, quarter(32).toRawBits(), target())
            StepKind.SET_NAMED_FLOAT -> Step(kind, quarter(32).toRawBits())
            StepKind.SET_NAMED_INTEGER -> Step(kind, random.nextInt(-20, 21))
            StepKind.CLICK -> Step(kind, 0)
          },
        )
      }
    }
    return Case(random.seed, document, kinds, steps)
  }

  /** The document's state after each step, as the Kotlin player gets there: one entry per slot. */
  private fun play(case: Case, bytes: ByteArray): List<List<String>> {
    val document = RcDocumentCodec.decode(bytes)
    val state = RcPlayerState(document, timeSource = UtcTime)
    val linked = RcDocumentLinker.link(document)
    val clicks = buildList {
      fun visit(node: RcLayoutNode) {
        if (node.componentId == CLICK_COMPONENT) addAll(node.modifiers.clicks)
        when (node) {
          is RcLayoutNode.Root -> node.children.forEach(::visit)
          is RcLayoutNode.Content -> node.children.forEach(::visit)
          is RcLayoutNode.Box -> node.content?.let(::visit)
          else -> Unit
        }
      }
      visit(requireNotNull(RcLayoutTree.build(linked)))
    }
    return case.steps.map { step ->
      when (step.kind) {
        StepKind.FRAME -> {
          val time = FRAME_TIMES[step.argument]
          state.beginFrame(time, EPOCH_MILLIS + (time * 1000).toLong())
          state.applyLayoutContentStateOperations(linked.operations)
        }
        StepKind.SET_FLOAT_BY_ID -> state.setFloat(step.id, Float.fromBits(step.argument))
        StepKind.SET_NAMED_FLOAT ->
          state.setNamedValue(NAMED_FLOAT, RcNamedValue.FloatValue(Float.fromBits(step.argument)))
        StepKind.SET_NAMED_INTEGER ->
          state.setNamedValue(NAMED_INTEGER, RcNamedValue.Integer(step.argument))
        StepKind.CLICK -> clicks.forEach(state::executeClick)
      }
      observe(state)
    }
  }

  /**
   * Every observed id as `integer/floatBits` (`-` for none), then each text (as JSON, `null` for
   * none) and colour (unsigned hex, `-` for none), each already a JSON value. The integer view is
   * read raw: `integer()` answers an unwritten id below 42 with the id itself, which the Swift
   * session's views have no counterpart for.
   */
  private fun observe(state: RcPlayerState): List<String> {
    val numbers = OBSERVED_IDS.map { id ->
      val signature = state.valueSignature(id).toString()
      val integer = INTEGER_FIELD.find(signature)?.groupValues?.get(1)?.takeUnless { it == "null" }
      "${integer ?: "-"}/${state.float(id)?.toRawBits()?.toUInt()?.toString(16) ?: "-"}"
    }
    val texts = TEXT_IDS.map { id -> state.text(id)?.let(::jsonString) ?: "null" }
    val colors = COLOR_IDS.map { id ->
      COLOR_FIELD.find(state.valueSignature(id).toString())
        ?.groupValues
        ?.get(1)
        ?.takeUnless { it == "null" }
        ?.toInt()
        ?.toUInt()
        ?.toString(16) ?: "-"
    }
    return numbers.map(::jsonString) + texts + colors.map(::jsonString)
  }

  private fun fixture(): String = buildString {
    appendLine("{")
    appendLine("  \"format\": $FIXTURE_FORMAT,")
    appendLine("  \"epochMillis\": $EPOCH_MILLIS,")
    appendLine("  \"frameTimes\": [${FRAME_TIMES.joinToString(", ")}],")
    appendLine("  \"observedIds\": [${OBSERVED_IDS.joinToString(", ")}],")
    appendLine("  \"textIds\": [${TEXT_IDS.joinToString(", ")}],")
    appendLine("  \"colorIds\": [${COLOR_IDS.joinToString(", ")}],")
    appendLine("  \"clickComponent\": $CLICK_COMPONENT,")
    appendLine("  \"namedFloat\": ${jsonString(NAMED_FLOAT)},")
    appendLine("  \"namedInteger\": ${jsonString(NAMED_INTEGER)},")
    appendLine("  \"cases\": [")
    val cases = (0 until DOCUMENTS).map { generate(SplitMix64(FIRST_SEED + it)) }
    appendLine(
      cases.joinToString(",\n") { case ->
        val bytes = RcDocumentCodec.encode(case.document)
        // The first step lists every slot; each later one only the slots that step changed, as
        // `[slot, value]` pairs, so the fixture stays a reviewable size.
        var previous: List<String>? = null
        val steps =
          case.steps.zip(play(case, bytes)).joinToString(",\n") { (step, observed) ->
            val changes =
              observed.indices
                .filter { previous?.get(it) != observed[it] }
                .joinToString(", ") { "[$it, ${observed[it]}]" }
            previous = observed
            "        [${jsonString(step.kind.letter)}, ${step.argument}, ${step.id}, [$changes]]"
          }
        "    {\"seed\": ${case.seed}, " +
          "\"document\": ${jsonString(Base64.getEncoder().encodeToString(bytes))},\n" +
          "      \"steps\": [\n$steps\n      ]}"
      },
    )
    appendLine("  ]")
    appendLine("}")
  }

  private fun jsonString(value: String): String = buildString {
    append('"')
    value.forEach { character ->
      when {
        character == '"' -> append("\\\"")
        character == '\\' -> append("\\\\")
        character < ' ' -> append("\\u%04x".format(character.code))
        else -> append(character)
      }
    }
    append('"')
  }

  /** UTC, so the calendar fields are the ones the Swift replay's offset-0 wall clock reads. */
  private object UtcTime : RcTimeSource {
    override fun currentTimeMillis(): Long = EPOCH_MILLIS

    override fun snapshot(epochMillis: Long): RcTimeSnapshot {
      val local = Instant.ofEpochMilli(epochMillis).atOffset(ZoneOffset.UTC)
      return RcTimeSnapshot(
        epochMillis = epochMillis,
        year = local.year,
        month = local.monthValue,
        dayOfMonth = local.dayOfMonth,
        dayOfYear = local.dayOfYear,
        hour = local.hour,
        minute = local.minute,
        second = local.second,
        isoDayOfWeek = local.dayOfWeek.value,
        offsetSeconds = 0,
      )
    }
  }

  /**
   * SplitMix64 (Steele, Lea and Flood, 2014), so the documents are fixed by this file alone: a
   * Kotlin upgrade cannot change them as it could `kotlin.random`'s.
   */
  private class SplitMix64(val seed: Long) {
    private var state = seed

    private fun next(): Long {
      state += -0x61c8864680b583ebL
      var z = state
      z = (z xor (z ushr 30)) * -0x40a7b892e31b1a47L
      z = (z xor (z ushr 27)) * -0x6b2fb644ecceee15L
      return z xor (z ushr 31)
    }

    /** Uniform in `0 until bound`, by rejection. */
    fun nextInt(bound: Int): Int {
      require(bound > 0)
      val limit = Long.MAX_VALUE - Long.MAX_VALUE % bound
      while (true) {
        val value = next() ushr 1
        if (value < limit) return (value % bound).toInt()
      }
    }

    fun nextInt(from: Int, until: Int): Int = from + nextInt(until - from)

    fun nextBoolean(): Boolean = nextInt(2) == 1
  }

  private fun <T> List<T>.randomOrNull(random: SplitMix64): T? =
    if (isEmpty()) null else this[random.nextInt(size)]

  private fun reference(id: Int) = RcFloatWord(0x7fc00000 or id)

  private companion object {
    const val FIXTURE_PROPERTY = "rc.valueResolutionDifferential.fixture"
    const val UPDATE_PROPERTY = "rc.valueResolutionDifferential.update"
    const val FIXTURE_FORMAT = 2
    const val DOCUMENTS = 300
    const val FIRST_SEED = 9_600L

    /** `RcSystemVariableTest.EPOCH_MILLIS`, which the Swift suite's `KotlinReference` names. */
    const val EPOCH_MILLIS = 1_787_243_445_250L
    val FRAME_TIMES = listOf(0f, 0.25f, 0.5f, 1f, 2f)

    /** The ids the generated operations write and read, so they collide often. */
    val NUMERIC_IDS = (60..71).toList()

    /** The player's ids an operation reads, or (rarely) writes, which claims one. */
    val SYSTEM_IDS =
      listOf(
        RcSystemVariables.CONTINUOUS_SEC,
        RcSystemVariables.TIME_IN_SEC,
        RcSystemVariables.TIME_IN_MIN,
        RcSystemVariables.DENSITY,
        RcSystemVariables.ANIMATION_TIME,
        RcSystemVariables.EPOCH_SECOND,
        RcSystemVariables.YEAR,
      )
    val OBSERVED_IDS = NUMERIC_IDS + SYSTEM_IDS
    val TEXT_IDS = listOf(200, 201, 202, 203)
    val TEXTS = listOf("a", "bc", "", "def")
    val COLOR_IDS = listOf(300, 301, 302)
    val COLORS = listOf(0xff000000.toInt(), 0xffffffff.toInt(), 0x80336699.toInt())
    const val ID_LIST = 400
    val LOOKUP_IDS = listOf(61, 62, 7)
    const val DATA_MAP = 410
    val DATA_MAP_KEYS = listOf(210, 211)
    const val DATA_MAP_FLOAT = 80
    const val DATA_MAP_INTEGER = 81
    const val NAMED_FLOAT_ID = 64
    const val NAMED_INTEGER_ID = 65
    const val NAMED_FLOAT = "f"
    const val NAMED_INTEGER = "i"
    const val CLICK_COMPONENT = 3
    val CONTAINER_END = RcNoArg(RcOpcodes.CONTAINER_END)

    const val FLOAT_MUL = RcFloatExpressionEvaluator.OFFSET + 3
    val FLOAT_OPERATORS =
      listOf(1, 2, 3, 6, 7).map { RcFloatExpressionEvaluator.OFFSET + it } // + - * min max
    val MULTIPLIERS = listOf(-1f, 0.5f, 2f)
    val INTEGER_OPERATORS =
      listOf(
        RcIntegerExpression.ADD,
        RcIntegerExpression.SUB,
        RcIntegerExpression.DIV,
        RcIntegerExpression.MOD,
        RcIntegerExpression.MIN,
        RcIntegerExpression.MAX,
      )
    val INTEGER_FIELD = Regex("""integer=(-?\d+|null)""")
    val COLOR_FIELD = Regex("""color=(-?\d+|null)""")
  }
}
