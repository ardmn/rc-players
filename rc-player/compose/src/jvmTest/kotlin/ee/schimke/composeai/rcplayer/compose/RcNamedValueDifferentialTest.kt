package ee.schimke.composeai.rcplayer.compose

import ee.schimke.composeai.rcplayer.protocol.RcBoxLayout
import ee.schimke.composeai.rcplayer.protocol.RcClickModifier
import ee.schimke.composeai.rcplayer.protocol.RcColorConstant
import ee.schimke.composeai.rcplayer.protocol.RcDocument
import ee.schimke.composeai.rcplayer.protocol.RcDocumentCodec
import ee.schimke.composeai.rcplayer.protocol.RcFloatConstant
import ee.schimke.composeai.rcplayer.protocol.RcFloatExpression
import ee.schimke.composeai.rcplayer.protocol.RcFloatWord
import ee.schimke.composeai.rcplayer.protocol.RcHeader
import ee.schimke.composeai.rcplayer.protocol.RcIntegerConstant
import ee.schimke.composeai.rcplayer.protocol.RcIntegerExpression
import ee.schimke.composeai.rcplayer.protocol.RcLayoutContent
import ee.schimke.composeai.rcplayer.protocol.RcNamedVariable
import ee.schimke.composeai.rcplayer.protocol.RcNoArg
import ee.schimke.composeai.rcplayer.protocol.RcOpcodes
import ee.schimke.composeai.rcplayer.protocol.RcOperation
import ee.schimke.composeai.rcplayer.protocol.RcRootLayout
import ee.schimke.composeai.rcplayer.protocol.RcTextData
import ee.schimke.composeai.rcplayer.protocol.RcValueFloatChangeAction
import ee.schimke.composeai.rcplayer.protocol.RcValueFloatExpressionChangeAction
import ee.schimke.composeai.rcplayer.protocol.RcValueIntegerChangeAction
import ee.schimke.composeai.rcplayer.protocol.RcValueIntegerExpressionChangeAction
import ee.schimke.composeai.rcplayer.protocol.RcValueStringChangeAction
import ee.schimke.composeai.rcplayer.protocol.RcVersion
import ee.schimke.composeai.rcplayer.protocol.RcWireLimits
import ee.schimke.composeai.rcplayer.runtime.RcClickActionBlock
import ee.schimke.composeai.rcplayer.runtime.RcDocumentLinker
import ee.schimke.composeai.rcplayer.runtime.RcFloatExpressionEvaluator
import ee.schimke.composeai.rcplayer.runtime.RcLayoutNode
import ee.schimke.composeai.rcplayer.runtime.RcLayoutTree
import ee.schimke.composeai.rcplayer.runtime.RcNamedValue
import ee.schimke.composeai.rcplayer.runtime.RcPlayerState
import ee.schimke.composeai.rcplayer.runtime.RcTimeSnapshot
import ee.schimke.composeai.rcplayer.runtime.RcTimeSource
import ee.schimke.composeai.rcplayer.runtime.fitsWireType
import java.io.File
import java.util.Base64
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.fail

/**
 * The Kotlin player as the oracle for the native Swift player's named values.
 *
 * Runs the [DIRECTED] cases and [SEQUENCES] seeded sequences of host writes (every setter, edge
 * values, equal writes, undeclared names, wrong types), document actions (clicks that write
 * integers, floats and text, a float written onto an integer and back), frames and reopens through
 * [RcPlayerState], and records every answer and the variables each step changed in
 * `Tests/RcNativePlayerCoreTests/Fixtures/named-value-differential.json`, next to the document
 * bytes and what each click writes. The SwiftUI overlay's suite
 * (`NativeControllerDifferentialTests`) replays the same steps through the native controller and
 * `NativeSwiftDocumentSession` and must reach the same results at every step, except for the
 * differences its allow-list (`named-value-differential-allowlist.json`) names: deliberate ones and
 * tracked bugs.
 *
 * Host values reach the state through [applyHostValueChanges], the player's own path: a value equal
 * to the one already applied is not applied again, so a document action's newer value stands. Each
 * accepted write is one application, as if each landed in its own frame. The controller in front of
 * it, `RcComposePlayerController.set`, is iosMain and cannot run here, so its rule is restated in
 * [KotlinPlayer.set]: a write is accepted when the resolved name is declared and the value fits its
 * type, and it is held by the declared name.
 *
 * A reopen step is a no-op here: the Kotlin player builds its state once per document and keeps it
 * (the native player reopens a session and carries the written values; that is what it checks).
 *
 * This test fails when the committed fixture is not what the Kotlin player produces now. After a
 * deliberate change to the document, the generator or the Kotlin player, rewrite it — the same run
 * then passes — with `scripts/agent-gradle.sh :rc-player-compose:jvmTest --tests
 * '*RcNamedValueDifferentialTest*' -Prc.namedValueDifferential.update=true`, then run the Swift
 * suite. The sequences come from [SplitMix64], not `kotlin.random`, so a Kotlin upgrade cannot
 * change them; the fixture is compared with its line endings normalised.
 */
class RcNamedValueDifferentialTest {
  @Test
  fun theCommittedFixtureIsWhatTheKotlinPlayerProduces() {
    val generatedJson = fixture()
    val file =
      File(
        requireNotNull(System.getProperty(FIXTURE_PROPERTY)) {
          "$FIXTURE_PROPERTY is unset; run this through Gradle"
        },
      )
    // The Swift suite reads the fixture at FIXTURE_PATH; the build must write it there too.
    assertEquals(
      File(FIXTURE_PATH).invariantSeparatorsPath,
      file.invariantSeparatorsPath.takeLast(FIXTURE_PATH.length),
      "$FIXTURE_PROPERTY points away from the path the Swift suite reads",
    )
    val update =
      requireNotNull(System.getProperty(UPDATE_PROPERTY)) {
          "$UPDATE_PROPERTY is unset; run this through Gradle"
        }
        .toBooleanStrict()
    if (update) file.writeText(generatedJson)
    if (!file.isFile) fail("$file is missing; see this class's KDoc")
    val committed = file.readText().replace("\r\n", "\n").lines()
    val generated = generatedJson.lines()
    val firstDifferentLine =
      committed.indices.firstOrNull { committed[it] != generated.getOrNull(it) }
    if (firstDifferentLine != null || committed.size != generated.size) {
      val reportedLine = firstDifferentLine ?: minOf(committed.size, generated.size)
      fail(
        "${file.name} is stale; see this class's KDoc. First difference at line " +
          "${reportedLine + 1}:\n" +
          "  committed: ${committed.getOrNull(reportedLine)?.take(200)}\n" +
          "  generated: ${generated.getOrNull(reportedLine)?.take(200)}",
      )
    }
  }

  /**
   * The seeded generator reaches every kind of step, so a change to it cannot quietly drop one. The
   * directed sequences are left out: they contain every kind by themselves.
   */
  @Test
  fun theSeededSequencesCoverEveryKindOfStep() {
    val kinds = seededOps().flatMap { it.ops }.map { it.kind }.toSet()
    assertEquals(StepKind.entries.toSet(), kinds)
  }

  private class Step(val op: Op, val accepted: Boolean?, val changes: List<Pair<Int, String>>)

  /** The ops one seed produces, before the player has run them. */
  private class SeedOps(val seed: Long, val ops: List<Op>)

  /** One seed's steps, as the fixture records them. */
  private class Sequence(val seed: Long, val steps: List<Step>)

  /** A name a host writes, and the kinds of write its variable takes. */
  private data class HostName(val name: String, val kinds: List<StepKind>)

  /**
   * A kind of step and the letter the fixture spells it with; the Swift suite's
   * `DifferentialStepKind` reads the same letters and fails on one it does not know.
   */
  private enum class StepKind(val letter: String, val isHostWrite: Boolean) {
    SET_FLOAT("F", isHostWrite = true),
    SET_INTEGER("I", isHostWrite = true),
    SET_BOOLEAN("B", isHostWrite = true),
    SET_STRING("S", isHostWrite = true),
    SET_COLOR("C", isHostWrite = true),
    CLICK("K", isHostWrite = false),
    REOPEN("R", isHostWrite = false),
    FRAME("P", isHostWrite = false),
  }

  /**
   * What a click action writes, as the fixture spells it; the Swift suite's `DifferentialClickKind`
   * reads the same names.
   */
  private enum class ClickKind(val label: String) {
    INT("int"),
    INT_EXPRESSION("intExpression"),
    FLOAT("float"),
    FLOAT_EXPRESSION("floatExpression"),
    TEXT("text"),
  }

  private sealed class Op(val kind: StepKind) {
    class SetFloat(val name: String, val value: Float) : Op(StepKind.SET_FLOAT)

    class SetInteger(val name: String, val value: Int) : Op(StepKind.SET_INTEGER)

    class SetBoolean(val name: String, val value: Boolean) : Op(StepKind.SET_BOOLEAN)

    /** [index] is into [STRINGS], so the fixture need not repeat a string at the size limit. */
    class SetString(val name: String, val index: Int) : Op(StepKind.SET_STRING)

    class SetColor(val name: String, val argb: Int) : Op(StepKind.SET_COLOR)

    class Click(val component: Int) : Op(StepKind.CLICK)

    data object Reopen : Op(StepKind.REOPEN)

    data object Frame : Op(StepKind.FRAME)
  }

  /**
   * The directed sequences (negative seeds, from -1) and then the seeded ones (seeds from
   * [FIRST_SEED]).
   */
  private fun sequences(bytes: ByteArray): List<Sequence> {
    val directed = DIRECTED.mapIndexed { index, ops -> SeedOps(-(index + 1L), ops) }
    return (directed + seededOps()).map { seedOps ->
      val player = KotlinPlayer(bytes)
      var previous = player.observe()
      Sequence(
        seedOps.seed,
        seedOps.ops.map { op ->
          val accepted = player.apply(op)
          val now = player.observe()
          val changes = now.indices.filter { now[it] != previous[it] }.map { it to now[it] }
          previous = now
          Step(op, accepted, changes)
        },
      )
    }
  }

  private fun seededOps(): List<SeedOps> =
    (0 until SEQUENCES).map { FIRST_SEED + it }.map { SeedOps(it, generate(SplitMix64(it))) }

  /** The host and the document, as the Kotlin player drives them. */
  private class KotlinPlayer(bytes: ByteArray) {
    private val document = RcDocumentCodec.decode(bytes)
    private val state = RcPlayerState(document, timeSource = FixedTime)
    private val clickActionsByComponent: Map<Int, List<RcClickActionBlock>> = buildMap {
      fun visit(node: RcLayoutNode) {
        if (node.modifiers.clicks.isNotEmpty()) put(node.componentId, node.modifiers.clicks)
        when (node) {
          is RcLayoutNode.Root -> node.children.forEach(::visit)
          is RcLayoutNode.Content -> node.children.forEach(::visit)
          is RcLayoutNode.Box -> node.content?.let(::visit)
          else -> error("Unexpected node in the differential document: $node")
        }
      }
      visit(requireNotNull(RcLayoutTree.build(RcDocumentLinker.link(document))))
    }

    /** What the controller holds, by declared name. */
    private val hostValues = mutableMapOf<String, RcNamedValue>()

    /** What the player last applied to the state ([applyHostValueChanges]). */
    private val applied = mutableMapOf<String, RcNamedValue>()

    fun apply(op: Op): Boolean? =
      when (op) {
        is Op.SetFloat -> set(op.name, RcNamedValue.FloatValue(op.value))
        is Op.SetInteger -> set(op.name, RcNamedValue.Integer(op.value))
        is Op.SetBoolean -> set(op.name, RcNamedValue.BooleanValue(op.value))
        is Op.SetString -> set(op.name, RcNamedValue.Text(STRINGS[op.index]))
        is Op.SetColor -> set(op.name, RcNamedValue.Color(op.argb))
        is Op.Click -> {
          clickActionsByComponent.getValue(op.component).forEach(state::executeClick)
          null
        }
        Op.Reopen -> null
        Op.Frame -> {
          state.beginFrame(0f, FIXED_EPOCH_MILLIS)
          null
        }
      }

    /**
     * `RcComposePlayerController.set`'s answer and store, then the player's own application of the
     * controller's values.
     */
    private fun set(name: String, value: RcNamedValue): Boolean {
      val variable = state.namedVariable(name) ?: return false
      if (!value.fitsWireType(variable.type)) return false
      hostValues[variable.name] = value
      state.applyHostValueChanges(applied, hostValues)
      return true
    }

    fun observe(): List<String> = VARIABLES.map { variable ->
      val id = variable.id
      when (variable.type) {
        RcNamedVariable.INT_TYPE -> "${state.integer(id) ?: "-"}/${floatBits(state.float(id))}"
        RcNamedVariable.FLOAT_TYPE -> floatBits(state.float(id))
        RcNamedVariable.STRING_TYPE ->
          state.text(id)?.let { text ->
            STRINGS.indexOf(text).takeIf { it >= 0 }?.let { "#$it" } ?: "?$text"
          } ?: "-"
        RcNamedVariable.COLOR_TYPE -> state.color(id).toUInt().toString(16)
        else -> error("No observation for ${variable.name}'s type ${variable.type}")
      }
    }

    private fun floatBits(value: Float?): String =
      value?.let { if (it.isNaN()) "nan" else it.toRawBits().toUInt().toString(16) } ?: "-"
  }

  /** A clock stopped at [FIXED_EPOCH_MILLIS], 2026-01-01T00:00Z, which its snapshot spells out. */
  private object FixedTime : RcTimeSource {
    override fun currentTimeMillis(): Long = FIXED_EPOCH_MILLIS

    override fun snapshot(epochMillis: Long): RcTimeSnapshot =
      RcTimeSnapshot(
        epochMillis = epochMillis,
        year = 2026,
        month = 1,
        dayOfMonth = 1,
        dayOfYear = 1,
        hour = 0,
        minute = 0,
        second = 0,
        isoDayOfWeek = 4,
      )
  }

  private fun generate(random: SplitMix64): List<Op> = buildList {
    var previousWrite: Op? = null
    repeat(random.nextInt(4, 17)) {
      val roll = random.nextInt(100)
      val op =
        when {
          // The same write again: no change for the host, whatever a document action did since.
          roll < 12 && previousWrite != null -> previousWrite
          roll < 62 -> hostWrite(random)
          roll < 88 -> Op.Click(CLICK_COMPONENTS[random.nextInt(CLICK_COMPONENTS.size)])
          roll < 95 -> Op.Reopen
          else -> Op.Frame
        }
      if (op.kind.isHostWrite) previousWrite = op
      add(op)
    }
  }

  private fun hostWrite(random: SplitMix64): Op {
    val (name, kinds) = HOST_NAMES[random.nextInt(HOST_NAMES.size)]
    // Mostly the setter the name's variable takes, so most writes land; otherwise any setter.
    val kind =
      if (random.nextInt(4) != 0) kinds[random.nextInt(kinds.size)]
      else HOST_WRITE_KINDS[random.nextInt(HOST_WRITE_KINDS.size)]
    return when (kind) {
      StepKind.SET_FLOAT ->
        Op.SetFloat(name, pick(random, FLOATS) { random.nextInt(-4000, 4000) / 8f })
      StepKind.SET_INTEGER ->
        Op.SetInteger(name, pick(random, INTEGERS) { random.nextInt(-50, 50) })
      StepKind.SET_BOOLEAN -> Op.SetBoolean(name, random.nextBoolean())
      StepKind.SET_STRING -> Op.SetString(name, pickString(random))
      StepKind.SET_COLOR -> Op.SetColor(name, pick(random, COLORS) { random.nextInt() })
      StepKind.CLICK,
      StepKind.REOPEN,
      StepKind.FRAME -> error("$kind is not a host write")
    }
  }

  /** An edge value from [edges] half the time, otherwise an ordinary one. */
  private fun <T> pick(random: SplitMix64, edges: List<T>, ordinary: () -> T): T =
    if (random.nextBoolean()) edges[random.nextInt(edges.size)] else ordinary()

  /** A string past the string limit is rare, as a non-finite float is: see [FLOATS]. */
  private fun pickString(random: SplitMix64): Int =
    if (random.nextInt(40) == 0) STRINGS.lastIndex else random.nextInt(STRINGS.size - 1)

  private fun fixture(): String {
    val bytes = RcDocumentCodec.encode(document())
    return buildString {
      appendLine("{")
      appendLine("  ${jsonString(FixtureKey.FORMAT)}: $FIXTURE_FORMAT,")
      appendLine("  ${jsonString(FixtureKey.STRING_LIMIT_BYTES)}: $STRING_LIMIT_BYTES,")
      val document = jsonString(Base64.getEncoder().encodeToString(bytes))
      appendLine("  ${jsonString(FixtureKey.DOCUMENT)}: $document,")
      val variables =
        VARIABLES.joinToString(", ") { "[${jsonString(it.name)}, ${it.id}, ${it.type}]" }
      appendLine("  ${jsonString(FixtureKey.VARIABLES)}: [$variables],")
      val clicks =
        CLICKS.entries.joinToString(", ") { (component, actions) ->
          "[$component, [${actions.joinToString(", ", transform = ::clickJson)}]]"
        }
      appendLine("  ${jsonString(FixtureKey.CLICKS)}: [$clicks],")
      appendLine(
        "  ${jsonString(FixtureKey.STRINGS)}: [${STRINGS.joinToString(", ") { jsonString(it) }}],",
      )
      val initial = KotlinPlayer(bytes).observe().joinToString(", ") { jsonString(it) }
      appendLine("  ${jsonString(FixtureKey.INITIAL)}: [$initial],")
      appendLine("  ${jsonString(FixtureKey.SEQUENCES)}: [")
      val sequences =
        sequences(bytes).joinToString(",\n") { sequence ->
          "    {${jsonString(FixtureKey.SEED)}: ${sequence.seed}, " +
            "${jsonString(FixtureKey.STEPS)}: [\n" +
            sequence.steps.joinToString(",\n") { step ->
              val changes =
                step.changes.joinToString(", ") { (index, value) ->
                  "[$index, ${jsonString(value)}]"
                }
              "      [${opJson(step.op)}, ${step.accepted ?: "null"}, [$changes]]"
            } +
            "\n    ]}"
        }
      appendLine(sequences)
      appendLine("  ]")
      appendLine("}")
    }
  }

  /**
   * A step as its kind's letter and its arguments. A float travels as its bits, so NaN and -0.0
   * survive; a colour as its unsigned ARGB.
   */
  private fun opJson(op: Op): String {
    val arguments =
      when (op) {
        is Op.SetFloat -> listOf(jsonString(op.name), "${op.value.toRawBits().toUInt()}")
        is Op.SetInteger -> listOf(jsonString(op.name), "${op.value}")
        is Op.SetBoolean -> listOf(jsonString(op.name), "${op.value}")
        is Op.SetString -> listOf(jsonString(op.name), "${op.index}")
        is Op.SetColor -> listOf(jsonString(op.name), "${op.argb.toUInt()}")
        is Op.Click -> listOf("${op.component}")
        Op.Reopen,
        Op.Frame -> emptyList()
      }
    return (listOf(jsonString(op.kind.letter)) + arguments).joinToString(", ", "[", "]")
  }

  /**
   * What one click action writes: its kind and the index of the variable it targets (null when none
   * is declared at that id).
   */
  private fun clickJson(action: RcOperation): String {
    val (kind, targetID) =
      when (action) {
        is RcValueIntegerChangeAction -> ClickKind.INT to action.targetValueId
        is RcValueIntegerExpressionChangeAction ->
          ClickKind.INT_EXPRESSION to action.targetValueId.toInt()
        is RcValueFloatChangeAction -> ClickKind.FLOAT to action.targetValueId
        is RcValueFloatExpressionChangeAction -> ClickKind.FLOAT_EXPRESSION to action.targetValueId
        is RcValueStringChangeAction -> ClickKind.TEXT to action.targetValueId
        else -> error("No fixture kind for $action")
      }
    val target = VARIABLES.indexOfFirst { it.id == targetID }.takeIf { it >= 0 }
    return "[${jsonString(kind.label)}, ${target ?: "null"}]"
  }

  /** A JSON string, ASCII only, so the fixture reads the same to any decoder. */
  private fun jsonString(value: String): String = buildString {
    append('"')
    for (char in value) {
      when {
        char == '"' -> append("\\\"")
        char == '\\' -> append("\\\\")
        char.code in 0x20..0x7e -> append(char)
        else -> append("\\u%04x".format(char.code))
      }
    }
    append('"')
  }

  /**
   * SplitMix64 (Steele, Lea and Flood, 2014), so the seeded sequences are fixed by this file alone:
   * `kotlin.random.Random`'s algorithm is not part of its contract.
   */
  private class SplitMix64(seed: Long) {
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

    fun nextInt(): Int = (next() ushr 32).toInt()

    fun nextBoolean(): Boolean = next() < 0
  }

  /**
   * A named variable: its name, its id and type, and the operation that declares it with its
   * initial value.
   */
  private class Variable(
    val name: String,
    val id: Int,
    val type: Int,
    val declaration: RcOperation,
  ) {
    companion object {
      fun of(name: String, declaration: RcOperation): Variable =
        when (declaration) {
          is RcIntegerConstant ->
            Variable(name, declaration.id, RcNamedVariable.INT_TYPE, declaration)
          is RcFloatConstant ->
            Variable(name, declaration.id, RcNamedVariable.FLOAT_TYPE, declaration)
          is RcTextData -> Variable(name, declaration.id, RcNamedVariable.STRING_TYPE, declaration)
          is RcColorConstant ->
            Variable(name, declaration.id, RcNamedVariable.COLOR_TYPE, declaration)
          else -> error("No named-variable type for $declaration")
        }
    }
  }

  /** The fixture's field names, which the Swift suite's `DifferentialFixture.Key` reads. */
  private object FixtureKey {
    const val FORMAT = "format"
    const val STRING_LIMIT_BYTES = "stringLimitBytes"
    const val DOCUMENT = "document"
    const val VARIABLES = "variables"
    const val CLICKS = "clicks"
    const val STRINGS = "strings"
    const val INITIAL = "initial"
    const val SEQUENCES = "sequences"
    const val SEED = "seed"
    const val STEPS = "steps"
  }

  private companion object {
    /**
     * The fixture's absolute path and whether to rewrite it. The build sets both on every run
     * (`NamedValueDifferentialFixture` in `rc-player/compose/build.gradle.kts`), so a name that
     * drifts on either side fails here rather than leaving the fixture unwritten.
     */
    const val FIXTURE_PROPERTY = "rc.namedValueDifferential.fixture"
    const val UPDATE_PROPERTY = "rc.namedValueDifferential.update"

    /** Where the fixture lives in the checkout, which the Swift suite reads. */
    const val FIXTURE_PATH = "Tests/RcNativePlayerCoreTests/Fixtures/named-value-differential.json"

    /** The fixture's layout; the Swift suite's `DifferentialFixture.format` must be the same. */
    const val FIXTURE_FORMAT = 3

    /**
     * The longest string a document may hold, in UTF-8 bytes: the codec's limit, which the native
     * player also applies to a host string (`NativeSwiftDocumentDecoder.maximumStringBytes`). The
     * fixture carries it and the Swift suite fails when the two differ.
     */
    val STRING_LIMIT_BYTES = RcWireLimits().maxStringBytes
    const val SEQUENCES = 500
    const val FIRST_SEED = 1L
    /** 2026-01-01T00:00Z, a Thursday: [FixedTime]'s snapshot spells the same instant. */
    const val FIXED_EPOCH_MILLIS = 1_767_225_600_000L

    val CONTAINER_END_OP = RcNoArg(RcOpcodes.CONTAINER_END)

    /** A clickable box's content component is its id plus this. */
    const val CONTENT_ID_OFFSET = 1000

    /** The float expression operator `+` (AndroidX's `AnimatedFloatExpression.ADD`). */
    const val FLOAT_ADD = RcFloatExpressionEvaluator.OFFSET + 1

    /** `count + 1`'s mask: its first and third words are references (a variable, an operator). */
    const val COUNT_PLUS_ONE_MASK = 0b101

    // The variables' ids, which the document declares them at and its click actions target.
    const val USER_COUNT_ID = 60
    const val COUNT_ID = 61
    const val USER_FLAG_ID = 62
    const val STEPS_ID = 63
    const val USER_LEVEL_ID = 70
    const val RATIO_ID = 71
    const val USER_TITLE_ID = 80
    const val LABEL_ID = 81
    const val USER_ACCENT_ID = 90
    const val TINT_ID = 91

    // The clickable components, each named for the one write it performs (see [CLICKS]).
    const val INT_9_ON_USER_COUNT = 1001
    const val FLOAT_2_5_ON_USER_COUNT = 1002
    const val FLOAT_9_75_ON_USER_COUNT = 1003
    const val FLOAT_0_25_ON_USER_LEVEL = 1004
    const val LEVEL_PLUS_ONE_ON_USER_LEVEL = 1005
    const val COUNT_PLUS_ONE_ON_USER_COUNT = 1006
    const val TEXT_FROM_DOC_ON_USER_TITLE = 1007
    const val INT_42_ON_COUNT = 1008
    const val INT_1_ON_USER_FLAG = 1009
    const val MINUS_ZERO_ON_RATIO = 1010
    const val INT_2_ON_USER_COUNT = 1011
    const val TEXT_EMPTY_ON_LABEL = 1012
    const val INT_4_ON_RATIO = 1013
    const val FLOAT_7_5_ON_STEPS = 1014
    const val INT_7_ON_STEPS = 1015
    const val INT_0_ON_USER_FLAG = 1016

    /**
     * Cases the seeded sequences reach only by chance, spelled out: each crosses a float and an
     * integer write on one id, an equal host write after a document action, or a reopen.
     */
    val DIRECTED: List<List<Op>> =
      listOf(
        // A float onto an integer, then a host integer: the stale float view (#974).
        listOf(Op.Click(FLOAT_2_5_ON_USER_COUNT), Op.SetInteger("count", 7)),
        // The same with the integer the float left behind, which AndroidX skips as no change.
        listOf(Op.Click(FLOAT_2_5_ON_USER_COUNT), Op.SetInteger("count", 2)),
        // A float onto an integer, then the document's own integer actions.
        listOf(
          Op.Click(FLOAT_9_75_ON_USER_COUNT),
          Op.Click(INT_9_ON_USER_COUNT),
          Op.Click(FLOAT_2_5_ON_USER_COUNT),
          Op.Click(COUNT_PLUS_ONE_ON_USER_COUNT),
        ),
        listOf(
          Op.Click(FLOAT_7_5_ON_STEPS),
          Op.SetBoolean("steps", true),
          Op.Click(FLOAT_7_5_ON_STEPS),
          Op.Click(INT_7_ON_STEPS),
        ),
        // The float view a float write left on an integer, carried across a reopen.
        listOf(
          Op.Click(FLOAT_2_5_ON_USER_COUNT),
          Op.Reopen,
          Op.SetInteger("count", 7),
          Op.Reopen,
        ),
        // An equal host write after a document action: no change, the action's value stands.
        listOf(
          Op.SetInteger("count", 5),
          Op.Click(INT_9_ON_USER_COUNT),
          Op.SetInteger("count", 5),
        ),
        listOf(
          Op.SetString("title", READY),
          Op.Click(TEXT_FROM_DOC_ON_USER_TITLE),
          Op.SetString("USER:title", READY),
        ),
        // -0.0 after 0.0 is a change: the controllers compare floats by their bits, not with `==`.
        listOf(
          Op.SetFloat("level", 0f),
          Op.Click(FLOAT_0_25_ON_USER_LEVEL),
          Op.SetFloat("level", -0f),
        ),
        // A boolean and the integer it stands for are different host values. The document sets it
        // back to 0 in between, so only a check that tells them apart writes the 1.
        listOf(
          Op.SetBoolean("flag", true),
          Op.Click(INT_0_ON_USER_FLAG),
          Op.SetInteger("flag", 1),
        ),
        // An integer action on a float variable.
        listOf(Op.Click(INT_4_ON_RATIO), Op.Reopen),
        // Host values and document values across reopens and frames.
        listOf(
          Op.SetColor("accent", 0x80FF0000.toInt()),
          Op.Click(INT_42_ON_COUNT),
          Op.Click(TEXT_EMPTY_ON_LABEL),
          Op.Reopen,
          Op.Frame,
          Op.SetString("label", EMOJI),
          Op.Reopen,
        ),
        // A write the native controller refuses and the Kotlin one stores, a document action,
        // then the native controller's last accepted value again: a change only on Kotlin.
        listOf(
          Op.SetFloat("level", 1f),
          Op.SetFloat("level", Float.NaN),
          Op.Click(FLOAT_0_25_ON_USER_LEVEL),
          Op.SetFloat("level", 1f),
        ),
        listOf(
          Op.SetString("title", READY),
          Op.SetString("title", PAST_LIMIT),
          Op.Click(TEXT_FROM_DOC_ON_USER_TITLE),
          Op.SetString("title", READY),
        ),
      )

    /**
     * Every host-writable type, under `USER:` and bare, with the value the document declares.
     * `count` is declared both ways, so a host's `count` addresses `USER:count` and only the
     * document's own action reaches the bare one.
     */
    val VARIABLES =
      listOf(
        Variable.of("USER:count", RcIntegerConstant(USER_COUNT_ID, 3)),
        Variable.of("count", RcIntegerConstant(COUNT_ID, 100)),
        Variable.of("USER:flag", RcIntegerConstant(USER_FLAG_ID, 0)),
        Variable.of("steps", RcIntegerConstant(STEPS_ID, 7)),
        Variable.of("USER:level", RcFloatConstant(USER_LEVEL_ID, RcFloatWord.literal(0.5f))),
        Variable.of("ratio", RcFloatConstant(RATIO_ID, RcFloatWord.literal(1.25f))),
        Variable.of("USER:title", RcTextData(USER_TITLE_ID, "Hello")),
        Variable.of("label", RcTextData(LABEL_ID, "plain")),
        Variable.of("USER:accent", RcColorConstant(USER_ACCENT_ID, 0xFF112233.toInt())),
        Variable.of("tint", RcColorConstant(TINT_ID, 0xFF00FF00.toInt())),
      )

    /** The host writes [hostWrite] draws from, in the order it draws them. */
    val HOST_WRITE_KINDS = StepKind.entries.filter { it.isHostWrite }
    val INTEGER_WRITE_KINDS = listOf(StepKind.SET_INTEGER, StepKind.SET_BOOLEAN)

    /**
     * Declared names in both spellings, and names no variable answers to, each with the writes its
     * variable takes (`USER:steps`, `USER:tint` and the missing names reach no variable).
     */
    val HOST_NAMES: List<HostName> =
      listOf(
        HostName("count", INTEGER_WRITE_KINDS),
        HostName("USER:count", INTEGER_WRITE_KINDS),
        HostName("flag", INTEGER_WRITE_KINDS),
        HostName("USER:flag", INTEGER_WRITE_KINDS),
        HostName("steps", INTEGER_WRITE_KINDS),
        HostName("USER:steps", INTEGER_WRITE_KINDS),
        HostName("level", listOf(StepKind.SET_FLOAT)),
        HostName("USER:level", listOf(StepKind.SET_FLOAT)),
        HostName("ratio", listOf(StepKind.SET_FLOAT)),
        HostName("title", listOf(StepKind.SET_STRING)),
        HostName("USER:title", listOf(StepKind.SET_STRING)),
        HostName("label", listOf(StepKind.SET_STRING)),
        HostName("accent", listOf(StepKind.SET_COLOR)),
        HostName("tint", listOf(StepKind.SET_COLOR)),
        HostName("USER:tint", listOf(StepKind.SET_COLOR)),
        HostName("missing", HOST_WRITE_KINDS),
        HostName("USER:missing", HOST_WRITE_KINDS),
      )

    /** Edge floats; the non-finite ones are entered once against many finite ones. */
    val FLOATS =
      listOf(
        0f,
        -0f,
        1f,
        0.5f,
        2.5f,
        9.75f,
        -1.5f,
        7f,
        1e30f,
        -1e30f,
        Float.MIN_VALUE,
        Float.MAX_VALUE,
        2147483648f,
        0f,
        1f,
        2.5f,
        9.75f,
        0.25f,
        3f,
        -0f,
        Float.NaN,
        Float.POSITIVE_INFINITY,
      )

    // Indices into [STRINGS] the directed sequences write.
    const val READY = 4
    const val EMOJI = 6
    const val PAST_LIMIT = 8

    val INTEGERS = listOf(0, 1, -1, 2, 3, 7, 9, 42, Int.MAX_VALUE, Int.MIN_VALUE)

    val COLORS = listOf(0, -1, 0xFF112233.toInt(), 0x80FF0000.toInt(), 0xFF00FF00.toInt())

    /** The last two are exactly at the string limit and one byte past it ([STRING_LIMIT_BYTES]). */
    val STRINGS =
      listOf(
        "",
        "Hello",
        "plain",
        "from-doc",
        "Ready",
        "naïve ✓",
        "😀",
        "x".repeat(STRING_LIMIT_BYTES),
        "x".repeat(STRING_LIMIT_BYTES + 1),
      )

    const val TEXT_FROM_DOC_ID = 300
    const val TEXT_EMPTY_ID = 301
    const val LEVEL_PLUS_ONE_ID = 200
    const val COUNT_PLUS_ONE_ID = 201

    /**
     * A float word that reads the variable at [id]: the quiet NaN (`Float.NaN`'s bits, 0x7fc00000)
     * carrying the id, which [RcFloatWord.referencedId] decodes.
     */
    private fun reference(id: Int) =
      RcFloatWord(Float.NaN.toRawBits() or id).also { check(it.referencedId == id) }

    /** Each clickable component and what a click on it writes. */
    val CLICKS: Map<Int, List<RcOperation>> =
      linkedMapOf(
        INT_9_ON_USER_COUNT to listOf(RcValueIntegerChangeAction(USER_COUNT_ID, 9)),
        // A float written onto an integer, the views the two share ids for.
        FLOAT_2_5_ON_USER_COUNT to
          listOf(RcValueFloatChangeAction(USER_COUNT_ID, RcFloatWord.literal(2.5f))),
        FLOAT_9_75_ON_USER_COUNT to
          listOf(RcValueFloatChangeAction(USER_COUNT_ID, RcFloatWord.literal(9.75f))),
        FLOAT_0_25_ON_USER_LEVEL to
          listOf(RcValueFloatChangeAction(USER_LEVEL_ID, RcFloatWord.literal(0.25f))),
        LEVEL_PLUS_ONE_ON_USER_LEVEL to
          listOf(RcValueFloatExpressionChangeAction(USER_LEVEL_ID, LEVEL_PLUS_ONE_ID)),
        COUNT_PLUS_ONE_ON_USER_COUNT to
          listOf(
            RcValueIntegerExpressionChangeAction(
              USER_COUNT_ID.toLong(),
              COUNT_PLUS_ONE_ID.toLong(),
            ),
          ),
        TEXT_FROM_DOC_ON_USER_TITLE to
          listOf(RcValueStringChangeAction(USER_TITLE_ID, TEXT_FROM_DOC_ID)),
        INT_42_ON_COUNT to listOf(RcValueIntegerChangeAction(COUNT_ID, 42)),
        INT_1_ON_USER_FLAG to listOf(RcValueIntegerChangeAction(USER_FLAG_ID, 1)),
        MINUS_ZERO_ON_RATIO to listOf(RcValueFloatChangeAction(RATIO_ID, RcFloatWord.literal(-0f))),
        // The integer a float write of 2.5 left behind, written as an integer.
        INT_2_ON_USER_COUNT to listOf(RcValueIntegerChangeAction(USER_COUNT_ID, 2)),
        TEXT_EMPTY_ON_LABEL to listOf(RcValueStringChangeAction(LABEL_ID, TEXT_EMPTY_ID)),
        // An integer written onto a float.
        INT_4_ON_RATIO to listOf(RcValueIntegerChangeAction(RATIO_ID, 4)),
        FLOAT_7_5_ON_STEPS to listOf(RcValueFloatChangeAction(STEPS_ID, RcFloatWord.literal(7.5f))),
        INT_7_ON_STEPS to listOf(RcValueIntegerChangeAction(STEPS_ID, 7)),
        INT_0_ON_USER_FLAG to listOf(RcValueIntegerChangeAction(USER_FLAG_ID, 0)),
      )

    /** [CLICKS]' components in order, which the generator draws from. */
    val CLICK_COMPONENTS = CLICKS.keys.toList()

    fun document(): RcDocument {
      val declarations =
        VARIABLES.map { it.declaration } +
          listOf(
            RcTextData(TEXT_FROM_DOC_ID, "from-doc"),
            RcTextData(TEXT_EMPTY_ID, ""),
            RcFloatExpression(
              LEVEL_PLUS_ONE_ID,
              listOf(
                reference(USER_LEVEL_ID),
                RcFloatWord.literal(1f),
                RcFloatExpressionEvaluator.operatorWord(FLOAT_ADD),
              ),
              null,
            ),
            // `count + 1`: the first value is a variable, the third the operator.
            RcIntegerExpression(
              COUNT_PLUS_ONE_ID,
              COUNT_PLUS_ONE_MASK,
              listOf(USER_COUNT_ID, 1, RcIntegerExpression.ADD),
            ),
          ) +
          VARIABLES.map { RcNamedVariable(it.id, it.type, it.name) }
      val boxes = CLICKS.flatMap { (component, actions) ->
        listOf(RcBoxLayout(component, -1, 1, 1), RcClickModifier) +
          actions +
          listOf(
            CONTAINER_END_OP,
            RcLayoutContent(component + CONTENT_ID_OFFSET),
            CONTAINER_END_OP,
            CONTAINER_END_OP,
          )
      }
      return RcDocument(
        RcHeader(RcVersion(1, 1, 0), legacyWidth = 100, legacyHeight = 100, modern = false),
        declarations +
          listOf(
            RcRootLayout(1),
            RcLayoutContent(2),
            RcBoxLayout(10, -1, 1, 1),
            RcLayoutContent(11),
          ) +
          boxes +
          listOf(CONTAINER_END_OP, CONTAINER_END_OP, CONTAINER_END_OP, CONTAINER_END_OP),
      )
    }
  }
}
