package ee.schimke.composeai.rcplayer.runtime

import ee.schimke.composeai.rcplayer.protocol.RcBitmapData
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
import ee.schimke.composeai.rcplayer.protocol.RcImageAttribute
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
import ee.schimke.composeai.rcplayer.protocol.RcTextLookup
import ee.schimke.composeai.rcplayer.protocol.RcTextMerge
import ee.schimke.composeai.rcplayer.protocol.RcTextSubtext
import ee.schimke.composeai.rcplayer.protocol.RcTextTransform
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
 * This test fails when the committed fixture is not what the Kotlin player produces now, or is
 * missing. After a deliberate change to the generator or the Kotlin player, rewrite it — the same
 * run then passes — with `scripts/agent-gradle.sh :rc-player-runtime:jvmTest --tests
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
    assertEquals(OperationKind.entries.toSet(), cases.flatMap { it.kinds }.toSet())
    assertEquals(StepKind.entries.toSet(), cases.flatMap { it.steps }.map { it.kind }.toSet())
    assertEquals(ActionKind.entries.toSet(), cases.flatMap { it.actionKinds }.toSet())
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
    TEXT_SUBTEXT,
    TEXT_TRANSFORM,
    TEXT_LOOKUP,
    IMAGE_ATTRIBUTE,
    COLOR_EXPRESSION,
    COLOR_ATTRIBUTE,
  }

  /** What a generated click action writes. */
  private enum class ActionKind {
    INTEGER,
    FLOAT,
    INTEGER_EXPRESSION,
    FLOAT_EXPRESSION,
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
   * One step. [argument] is a frame's index into [FRAME_TIMES], a float write's value as its bits,
   * an integer write's value, or 0 for a click; [id] is the id a by-id write targets.
   */
  private data class Step(val kind: StepKind, val argument: Int, val id: Int = 0)

  /** The generated documents, built once for both tests. */
  private val cases by lazy { (0 until DOCUMENTS).map { generate(SplitMix64(FIRST_SEED + it)) } }

  private class Case(
    val seed: Long,
    val document: RcDocument,
    val kinds: Set<OperationKind>,
    val actionKinds: Set<ActionKind>,
    val steps: List<Step>,
  )

  private fun generate(random: SplitMix64): Case {
    val operations = mutableListOf<RcOperation>()
    val kinds = mutableSetOf<OperationKind>()
    val floatExpressionIds = mutableSetOf<Int>()
    val integerExpressionIds = mutableSetOf<Int>()

    /** An id an operation reads: now and then the player's own. */
    fun readID(): Int =
      if (random.nextInt(8) == 0) SYSTEM_IDS[random.nextInt(SYSTEM_IDS.size)]
      else NUMERIC_IDS[random.nextInt(NUMERIC_IDS.size)]

    /** An id an operation writes: rarely a system id, which the write then claims. */
    fun writeID(): Int =
      if (random.nextInt(16) == 0) SYSTEM_IDS[random.nextInt(SYSTEM_IDS.size)]
      else NUMERIC_IDS[random.nextInt(NUMERIC_IDS.size)]

    fun quarters(limit: Int): Float = random.nextInt(-limit, limit + 1) / 4f

    fun smallInteger(): Int = random.nextInt(-INTEGER_LIMIT, INTEGER_LIMIT + 1)

    fun floatOperand(): RcFloatWord =
      if (random.nextBoolean()) reference(readID())
      else RcFloatWord.literal(quarters(OPERAND_QUARTERS))

    operations += TEXT_IDS.mapIndexed { index, id -> RcTextData(id, TEXTS[index]) }
    operations += COLOR_IDS.mapIndexed { index, id -> RcColorConstant(id, COLORS[index]) }
    operations += RcIdList(ID_LIST, LOOKUP_IDS)
    operations += RcIdList(TEXT_LIST, TEXT_IDS)
    operations += RcBitmapData(BITMAP, BITMAP_WIDTH, BITMAP_HEIGHT, 0, 0, ByteArray(4))
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
      if (random.nextBoolean()) RcFloatConstant(id, RcFloatWord.literal(quarters(QUARTERS)))
      else RcIntegerConstant(id, smallInteger())
    }
    repeat(random.nextInt(6, 18)) {
      val kind = OperationKind.entries[random.nextInt(OperationKind.entries.size)]
      val operation =
        when (kind) {
          OperationKind.FLOAT_CONSTANT ->
            RcFloatConstant(writeID(), RcFloatWord.literal(quarters(QUARTERS)))
          OperationKind.INTEGER_CONSTANT -> RcIntegerConstant(writeID(), smallInteger())
          OperationKind.FLOAT_EXPRESSION -> {
            // `a (b op)*`. A product's second operand is a literal, so a cycle multiplying itself
            // over a sequence of frames stays finite.
            val words = mutableListOf(floatOperand())
            repeat(random.nextInt(3)) {
              val operator = FLOAT_OPERATORS[random.nextInt(FLOAT_OPERATORS.size)]
              words +=
                if (operator == FLOAT_MUL) {
                  RcFloatWord.literal(MULTIPLIERS[random.nextInt(MULTIPLIERS.size)])
                } else {
                  floatOperand()
                }
              words += RcFloatExpressionEvaluator.operatorWord(operator)
            }
            // One float expression per id: the Kotlin player memoises an expression's inputs by
            // the id it writes, so a second expression at that id is skipped while the first's
            // inputs stand still (a Kotlin bug, not an order to copy). A few draws
            // find a free id; with none, the operation is a constant instead.
            val freeIDs = generateSequence(::writeID).take(FREE_ID_DRAWS)
            val id = freeIDs.firstOrNull { it !in floatExpressionIds }
            if (id == null) {
              RcFloatConstant(writeID(), RcFloatWord.literal(quarters(QUARTERS)))
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
                values += readID()
              } else {
                values += random.nextInt(-LITERAL_LIMIT, LITERAL_LIMIT + 1)
              }
            }
            operand()
            repeat(random.nextInt(3)) {
              operand()
              mask = mask or (1 shl values.size)
              values += INTEGER_OPERATORS[random.nextInt(INTEGER_OPERATORS.size)]
            }
            val id = writeID()
            integerExpressionIds += id
            RcIntegerExpression(id, mask, values)
          }
          OperationKind.ID_LOOKUP ->
            RcIdLookup(
              writeID(),
              ID_LIST,
              RcFloatWord.literal(random.nextInt(LOOKUP_IDS.size).toFloat()),
            )
          OperationKind.DATA_MAP_LOOKUP ->
            RcDataMapLookup(writeID(), DATA_MAP, DATA_MAP_KEYS[random.nextInt(DATA_MAP_KEYS.size)])
          OperationKind.TEXT_MERGE ->
            RcTextMerge(
              TEXT_IDS[random.nextInt(TEXT_IDS.size)],
              TEXT_IDS[random.nextInt(TEXT_IDS.size)],
              TEXT_IDS[random.nextInt(TEXT_IDS.size)],
            )
          OperationKind.TEXT_LENGTH ->
            RcTextLength(writeID(), TEXT_IDS[random.nextInt(TEXT_IDS.size)])
          OperationKind.TEXT_FROM_FLOAT ->
            RcTextFromFloat(
              outId = TEXT_IDS[random.nextInt(TEXT_IDS.size)],
              value = reference(readID()),
              digitsBefore = 3,
              digitsAfter = 2,
              flags = 0,
            )
          OperationKind.TEXT_SUBTEXT ->
            RcTextSubtext(
              TEXT_IDS[random.nextInt(TEXT_IDS.size)],
              TEXT_IDS[random.nextInt(TEXT_IDS.size)],
              RcFloatWord.literal(random.nextInt(3).toFloat()),
              RcFloatWord.literal(random.nextInt(-1, 3).toFloat()),
            )
          // From the start, to the end: Kotlin's substring refuses a range past a shorter text,
          // where Swift clamps it.
          OperationKind.TEXT_TRANSFORM ->
            RcTextTransform(
              TEXT_IDS[random.nextInt(TEXT_IDS.size)],
              TEXT_IDS[random.nextInt(TEXT_IDS.size)],
              RcFloatWord.literal(0f),
              RcFloatWord.literal(-1f),
              TEXT_TRANSFORMS[random.nextInt(TEXT_TRANSFORMS.size)],
            )
          OperationKind.TEXT_LOOKUP ->
            RcTextLookup(
              TEXT_IDS[random.nextInt(TEXT_IDS.size)],
              TEXT_LIST,
              RcFloatWord.literal(random.nextInt(TEXT_IDS.size).toFloat()),
            )
          OperationKind.IMAGE_ATTRIBUTE ->
            RcImageAttribute(
              writeID(),
              BITMAP,
              if (random.nextBoolean()) RcImageAttribute.IMAGE_WIDTH
              else RcImageAttribute.IMAGE_HEIGHT,
              emptyList(),
            )
          OperationKind.COLOR_EXPRESSION ->
            RcColorExpression(
              COLOR_IDS[random.nextInt(COLOR_IDS.size)],
              RcColorExpression.ID_ID_INTERPOLATE,
              COLOR_IDS[random.nextInt(COLOR_IDS.size)],
              COLOR_IDS[random.nextInt(COLOR_IDS.size)],
              RcFloatWord.literal(random.nextInt(5) / 4f).bits,
            )
          OperationKind.COLOR_ATTRIBUTE ->
            RcColorAttribute(
              writeID(),
              COLOR_IDS[random.nextInt(COLOR_IDS.size)],
              COLOR_ATTRIBUTES[random.nextInt(COLOR_ATTRIBUTES.size)],
            )
        }
      // What was emitted, not what was drawn: a float expression with no free id is a constant.
      kinds += if (operation is RcFloatConstant) OperationKind.FLOAT_CONSTANT else kind
      operations += operation
    }
    operations += RcNamedVariable(NAMED_FLOAT_ID, RcNamedVariable.FLOAT_TYPE, NAMED_FLOAT)
    operations += RcNamedVariable(NAMED_INTEGER_ID, RcNamedVariable.INT_TYPE, NAMED_INTEGER)

    val actions =
      List(random.nextInt(1, 4)) {
        when (ActionKind.entries[random.nextInt(ActionKind.entries.size)]) {
          ActionKind.INTEGER -> RcValueIntegerChangeAction(writeID(), smallInteger())
          ActionKind.FLOAT ->
            RcValueFloatChangeAction(writeID(), RcFloatWord.literal(quarters(QUARTERS)))
          ActionKind.INTEGER_EXPRESSION ->
            integerExpressionIds.randomOrNull(random)?.let {
              RcValueIntegerExpressionChangeAction(writeID().toLong(), it.toLong())
            } ?: RcValueIntegerChangeAction(writeID(), smallInteger())
          ActionKind.FLOAT_EXPRESSION ->
            floatExpressionIds.randomOrNull(random)?.let {
              RcValueFloatExpressionChangeAction(writeID(), it)
            } ?: RcValueFloatChangeAction(writeID(), RcFloatWord.literal(quarters(QUARTERS)))
        }
      }
    val document =
      RcDocument(
        RcHeader(RcVersion(1, 1, 0), legacyWidth = 100, legacyHeight = 100, modern = false),
        buildList {
          addAll(operations)
          addAll(listOf(RcRootLayout(1), RcLayoutContent(2)))
          addAll(listOf(RcBoxLayout(CLICK_COMPONENT, -1, 1, 1), RcClickModifier))
          addAll(actions)
          addAll(listOf(CONTAINER_END, RcLayoutContent(4), CONTAINER_END, CONTAINER_END))
          addAll(listOf(CONTAINER_END, CONTAINER_END))
        },
      )
    val steps = buildList {
      add(Step(StepKind.FRAME, 0))
      repeat(random.nextInt(4, 10)) {
        val kind = StepKind.entries[random.nextInt(StepKind.entries.size)]
        add(
          when (kind) {
            StepKind.FRAME -> Step(kind, random.nextInt(FRAME_TIMES.size))
            StepKind.SET_FLOAT_BY_ID -> Step(kind, quarters(QUARTERS).toRawBits(), writeID())
            StepKind.SET_NAMED_FLOAT -> Step(kind, quarters(QUARTERS).toRawBits())
            StepKind.SET_NAMED_INTEGER -> Step(kind, smallInteger())
            StepKind.CLICK -> Step(kind, 0)
          },
        )
      }
    }
    val actionKinds =
      actions.mapTo(mutableSetOf()) { action ->
        when (action) {
          is RcValueIntegerChangeAction -> ActionKind.INTEGER
          is RcValueFloatChangeAction -> ActionKind.FLOAT
          is RcValueIntegerExpressionChangeAction -> ActionKind.INTEGER_EXPRESSION
          else -> ActionKind.FLOAT_EXPRESSION
        }
      }
    return Case(random.seed, document, kinds, actionKinds, steps)
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
   * the stored one: `integer()` answers an unwritten id below 42 with the id itself, which the
   * Swift session's views have no counterpart for.
   */
  private fun observe(state: RcPlayerState): List<String> {
    val numbers = OBSERVED_IDS.map { id ->
      val integer = state.storedInteger(id)?.toString() ?: "-"
      jsonString("$integer/${state.float(id)?.toRawBits()?.toUInt()?.toString(16) ?: "-"}")
    }
    val texts = TEXT_IDS.map { id -> state.text(id)?.let(::jsonString) ?: "null" }
    val colors = COLOR_IDS.map { id ->
      jsonString(state.storedColor(id)?.toUInt()?.toString(16) ?: "-")
    }
    return numbers + texts + colors
  }

  private fun fixture(): String = buildString {
    appendLine("{")
    appendLine("  \"format\": $FIXTURE_FORMAT,")
    appendLine("  \"epochMillis\": $EPOCH_MILLIS,")
    appendLine("  \"frameTimes\": [${FRAME_TIMES.joinToString(", ")}],")
    appendLine("  \"observedIds\": [${OBSERVED_IDS.joinToString(", ")}],")
    // Sorted, so the fixture does not follow the set's declaration order.
    appendLine("  \"systemIds\": [${RcSystemVariables.ALL.sorted().joinToString(", ")}],")
    appendLine("  \"documents\": $DOCUMENTS,")
    appendLine("  \"textIds\": [${TEXT_IDS.joinToString(", ")}],")
    appendLine("  \"colorIds\": [${COLOR_IDS.joinToString(", ")}],")
    appendLine("  \"clickComponent\": $CLICK_COMPONENT,")
    appendLine("  \"namedFloat\": ${jsonString(NAMED_FLOAT)},")
    appendLine("  \"namedInteger\": ${jsonString(NAMED_INTEGER)},")
    appendLine("  \"cases\": [")
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
      when (character) {
        '"' -> append("\\\"")
        '\\' -> append("\\\\")
        in '\u0000'..'\u001f' -> append("\\u%04x".format(character.code))
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

  /** One element, chosen by [random]; insertion order, so a seed always picks the same one. */
  private fun <T> Set<T>.randomOrNull(random: SplitMix64): T? =
    if (isEmpty()) null else elementAt(random.nextInt(size))

  private fun reference(id: Int) = RcFloatWord(0x7fc00000 or id)

  private companion object {
    const val FIXTURE_PROPERTY = "rc.valueResolutionDifferential.fixture"
    const val UPDATE_PROPERTY = "rc.valueResolutionDifferential.update"
    const val FIXTURE_FORMAT = 2
    const val DOCUMENTS = 300
    const val FIRST_SEED = 9_600L

    /** The Swift suite's `KotlinReference.epochMillis` names the same instant. */
    const val EPOCH_MILLIS = RcSystemVariableTest.EPOCH_MILLIS
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
    const val TEXT_LIST = 420
    const val BITMAP = 430
    const val BITMAP_WIDTH = 8
    const val BITMAP_HEIGHT = 4

    /**
     * `RcTextTransform`'s operations the codec writes: lower, upper, trim, capitalise words, first.
     */
    val TEXT_TRANSFORMS = (1..5).toList()
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

    // RcFloatExpressionEvaluator's operators, by their AndroidX numbers.
    const val FLOAT_ADD = RcFloatExpressionEvaluator.OFFSET + 1
    const val FLOAT_SUB = RcFloatExpressionEvaluator.OFFSET + 2
    const val FLOAT_MUL = RcFloatExpressionEvaluator.OFFSET + 3
    const val FLOAT_MIN = RcFloatExpressionEvaluator.OFFSET + 6
    const val FLOAT_MAX = RcFloatExpressionEvaluator.OFFSET + 7
    val FLOAT_OPERATORS = listOf(FLOAT_ADD, FLOAT_SUB, FLOAT_MUL, FLOAT_MIN, FLOAT_MAX)
    /**
     * A product's second operand, so a value that multiplies itself frame after frame stays finite.
     */
    val MULTIPLIERS = listOf(-1f, 0.5f, 2f)

    /** The range of an integer constant and of an action's integer value. */
    const val INTEGER_LIMIT = 20

    /** The range of an integer expression's literal operand. */
    const val LITERAL_LIMIT = 10

    /** How many ids a float expression draws for one no other float expression writes. */
    const val FREE_ID_DRAWS = 8

    /**
     * Float constants and writes are quarters in `-QUARTERS / 4 .. QUARTERS / 4`; operands
     * narrower.
     */
    const val QUARTERS = 32
    const val OPERAND_QUARTERS = 16
    val COLOR_ATTRIBUTES =
      listOf(
        RcColorAttribute.COLOR_HUE,
        RcColorAttribute.COLOR_SATURATION,
        RcColorAttribute.COLOR_BRIGHTNESS,
        RcColorAttribute.COLOR_RED,
        RcColorAttribute.COLOR_GREEN,
        RcColorAttribute.COLOR_BLUE,
        RcColorAttribute.COLOR_ALPHA,
      )
    val INTEGER_OPERATORS =
      listOf(
        RcIntegerExpression.ADD,
        RcIntegerExpression.SUB,
        RcIntegerExpression.DIV,
        RcIntegerExpression.MOD,
        RcIntegerExpression.MIN,
        RcIntegerExpression.MAX,
      )
  }
}
