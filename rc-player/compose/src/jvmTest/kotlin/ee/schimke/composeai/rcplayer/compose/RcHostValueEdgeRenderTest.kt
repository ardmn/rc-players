package ee.schimke.composeai.rcplayer.compose

import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.unit.Density
import ee.schimke.composeai.rcplayer.protocol.RcBoxLayout
import ee.schimke.composeai.rcplayer.protocol.RcCanvasLayout
import ee.schimke.composeai.rcplayer.protocol.RcColorConstant
import ee.schimke.composeai.rcplayer.protocol.RcColorExpression
import ee.schimke.composeai.rcplayer.protocol.RcConditionalOperations
import ee.schimke.composeai.rcplayer.protocol.RcCoreText
import ee.schimke.composeai.rcplayer.protocol.RcDimensionType
import ee.schimke.composeai.rcplayer.protocol.RcDocument
import ee.schimke.composeai.rcplayer.protocol.RcDocumentCodec
import ee.schimke.composeai.rcplayer.protocol.RcDraw4
import ee.schimke.composeai.rcplayer.protocol.RcDrawTextAnchored
import ee.schimke.composeai.rcplayer.protocol.RcDynamicFloatList
import ee.schimke.composeai.rcplayer.protocol.RcFloatConstant
import ee.schimke.composeai.rcplayer.protocol.RcFloatExpression
import ee.schimke.composeai.rcplayer.protocol.RcFloatWord
import ee.schimke.composeai.rcplayer.protocol.RcGraphicsLayerAttribute
import ee.schimke.composeai.rcplayer.protocol.RcGraphicsLayerModifier
import ee.schimke.composeai.rcplayer.protocol.RcHeader
import ee.schimke.composeai.rcplayer.protocol.RcHeightModifier
import ee.schimke.composeai.rcplayer.protocol.RcLayoutContent
import ee.schimke.composeai.rcplayer.protocol.RcLoopOperation
import ee.schimke.composeai.rcplayer.protocol.RcNamedVariable
import ee.schimke.composeai.rcplayer.protocol.RcNoArg
import ee.schimke.composeai.rcplayer.protocol.RcOffsetModifier
import ee.schimke.composeai.rcplayer.protocol.RcOpcodes
import ee.schimke.composeai.rcplayer.protocol.RcOperation
import ee.schimke.composeai.rcplayer.protocol.RcPaddingModifier
import ee.schimke.composeai.rcplayer.protocol.RcPaintData
import ee.schimke.composeai.rcplayer.protocol.RcRootLayout
import ee.schimke.composeai.rcplayer.protocol.RcRowLayout
import ee.schimke.composeai.rcplayer.protocol.RcTextData
import ee.schimke.composeai.rcplayer.protocol.RcTextFromFloat
import ee.schimke.composeai.rcplayer.protocol.RcTextLayout
import ee.schimke.composeai.rcplayer.protocol.RcTextLength
import ee.schimke.composeai.rcplayer.protocol.RcTextMerge
import ee.schimke.composeai.rcplayer.protocol.RcTextStyleProperty
import ee.schimke.composeai.rcplayer.protocol.RcVersion
import ee.schimke.composeai.rcplayer.protocol.RcVisibilityModifier
import ee.schimke.composeai.rcplayer.protocol.RcWidthInModifier
import ee.schimke.composeai.rcplayer.protocol.RcWidthModifier
import ee.schimke.composeai.rcplayer.protocol.RcZIndexModifier
import ee.schimke.composeai.rcplayer.runtime.RcFloatExpressionEvaluator
import ee.schimke.composeai.rcplayer.runtime.RcNamedValue
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import org.jetbrains.skia.Bitmap

/**
 * Every value a host may write, NaN, the infinities and strings far over a document string's 4000
 * bytes included, as AndroidX's `setNamed*Override` takes them, reaches each float and text
 * consumer of the player without crashing it or hanging a frame: layout sizes, weights, padding,
 * offsets, `widthIn`, z-index, alpha, rotation and scale, colour interpolation, an animated
 * expression, a conditional, visibility, a dynamic list's length, canvas geometry, text formatting,
 * text length and merge.
 *
 * The same documents are written to `Tests/RcNativePlayerCoreTests/Fixtures/host-value-edges/` for
 * the native Swift player's `NativeSwiftHostValueEdgeTests`, which writes the same values into
 * them; run with `-Prc.hostValueEdges.update=true` to rewrite them. This test fails when the
 * committed fixtures differ from the documents built here.
 */
class RcHostValueEdgeRenderTest {

  @Test(timeout = 120_000)
  fun everyFloatConsumerTakesNonFiniteHostValues() =
    assertRenders(
      floatCases.flatMap { case ->
        EDGE_FLOATS.map { value -> Triple(case, "$value", RcNamedValue.FloatValue(value)) }
      },
    ) {
      FLOAT_NAME
    }

  /**
   * The consumers the Swift fixtures do not hold yet: a text's font size, as layout text and as a
   * canvas paint's, and a loop nest whose bounds are the host's. Each takes every edge float, past
   * the ones above to the huge and the negative, without crashing or hanging the frame.
   */
  @Test(timeout = 120_000)
  fun everyFontSizeAndLoopTakesNonFiniteHugeAndNegativeHostValues() =
    assertRenders(
      playerOnlyCases.flatMap { case ->
        (EDGE_FLOATS + HUGE_AND_NEGATIVE_FLOATS).map { value ->
          Triple(case, "$value", RcNamedValue.FloatValue(value))
        }
      },
    ) {
      FLOAT_NAME
    }

  @Test(timeout = 120_000)
  fun everyTextConsumerTakesAStringFarOverADocumentString() =
    assertRenders(
      textCases.flatMap { case ->
        LONG_TEXTS.map { text -> Triple(case, "${text.length} chars", RcNamedValue.Text(text)) }
      },
    ) {
      TEXT_NAME
    }

  /**
   * A megabyte of one word, in a `TextLayout`, a merge and a `CoreText`, renders in time: Skia lays
   * out a word too long for a line in time quadratic in its length, and this one took minutes.
   */
  @Test(timeout = 120_000)
  fun aMegabyteWordLaysOutInTime() =
    assertRenders(
      (textCases.filter { it.name != "long-text-length-as-width" } +
          Case("core-text", coreTextDocument(fontSize = literal(12f))))
        .map { case -> Triple(case, "1 MB", RcNamedValue.Text(MEGABYTE_WORD)) },
    ) {
      TEXT_NAME
    }

  /**
   * Renders every case with its value, and fails with every one that threw or took longer than
   * [MAX_RENDER_MILLIS] for its frames, not only the first.
   */
  private fun assertRenders(
    runs: List<Triple<Case, String, RcNamedValue>>,
    name: () -> String,
  ) {
    val failures = runs.mapNotNull { (case, label, value) ->
      val start = System.nanoTime()
      runCatching { render(case.document, mapOf(name() to value)) }
        .fold(
          onSuccess = { bitmap ->
            val millis = (System.nanoTime() - start) / 1_000_000
            when {
              bitmap.width != WIDTH -> "${case.name} with $label drew ${bitmap.width} wide"
              millis > MAX_RENDER_MILLIS -> "${case.name} with $label took $millis ms"
              else -> null
            }
          },
          onFailure = { error ->
            val at = error.stackTrace.firstOrNull { "rcplayer" in it.className }
            "${case.name} with $label: $error at $at"
          },
        )
    }
    assertTrue(failures.isEmpty(), failures.joinToString("\n"))
  }

  /** The documents the Swift test renders are the ones rendered here. */
  @Test
  fun theSwiftFixturesAreTheseDocuments() {
    val directory =
      File(requireNotNull(System.getProperty(FIXTURE_PROPERTY)) { "$FIXTURE_PROPERTY not set" })
    val expected =
      (floatCases + textCases).associate { "${it.name}.rc" to RcDocumentCodec.encode(it.document) }
    val index =
      (floatCases.map { "${it.name}\t$FLOAT_KIND" } + textCases.map { "${it.name}\t$TEXT_KIND" })
        .joinToString("\n", postfix = "\n")
    if (System.getProperty(UPDATE_PROPERTY) == "true") {
      directory.deleteRecursively()
      directory.mkdirs()
      expected.forEach { (name, bytes) -> File(directory, name).writeBytes(bytes) }
      File(directory, INDEX).writeText(index)
    }
    assertEquals(
      index,
      File(directory, INDEX).readText(),
      "regenerate with -P$UPDATE_PROPERTY=true",
    )
    for ((name, bytes) in expected) {
      assertTrue(
        File(directory, name).readBytes().contentEquals(bytes),
        "$name differs; regenerate with -P$UPDATE_PROPERTY=true",
      )
    }
  }

  private class Case(val name: String, val document: RcDocument)

  /** A canvas box drawing a rect, with [modifiers] and [data] declared before the layout. */
  private fun canvas(
    name: String,
    modifiers: List<RcOperation> = emptyList(),
    data: List<RcOperation> = emptyList(),
    draws: List<RcOperation> = listOf(rect(literal(0f), literal(0f), literal(40f), literal(40f))),
  ) =
    Case(
      name,
      document(
        data +
          listOf(RcRootLayout(1), RcLayoutContent(2), RcCanvasLayout(3, 30)) +
          modifiers +
          listOf(RcNoArg(RcOpcodes.CANVAS_OPERATIONS), RcPaintData(listOf(4, PURPLE))) +
          draws +
          List(4) { END },
      ),
    )

  /** A text component showing [textId], after [data]. */
  private fun text(
    name: String,
    textId: Int,
    data: List<RcOperation> = emptyList(),
    fontSize: RcFloatWord = literal(12f),
  ) =
    Case(
      name,
      document(
        data +
          listOf(
            RcRootLayout(1),
            RcBoxLayout(3, 30, 1, 1),
            RcLayoutContent(4),
            RcTextLayout(
              componentId = 5,
              animationId = 50,
              textId = textId,
              color = INK,
              fontSize = fontSize,
              fontStyle = 0,
              fontWeight = literal(400f),
              fontFamilyId = -1,
              textAlignAndFlags = RcTextLayout.ALIGN_LEFT,
              overflow = RcTextLayout.OVERFLOW_CLIP,
              maxLines = Int.MAX_VALUE,
            ),
            RcLayoutContent(6),
          ) +
          List(5) { END },
      ),
    )

  private val floatCases: List<Case> =
    listOf(
      canvas("width", listOf(RcWidthModifier(RcDimensionType.EXACT, HOST))),
      canvas("height", listOf(RcHeightModifier(RcDimensionType.EXACT, HOST))),
      canvas("padding", listOf(RcPaddingModifier(HOST, HOST, HOST, HOST))),
      canvas("offset", listOf(RcOffsetModifier(HOST, HOST))),
      canvas("width-in", listOf(RcWidthInModifier(HOST, HOST))),
      canvas("z-index", listOf(RcZIndexModifier(HOST))),
      canvas("alpha", listOf(layer(RcGraphicsLayerModifier.ALPHA))),
      canvas("rotation", listOf(layer(RcGraphicsLayerModifier.ROTATION_Z))),
      canvas("scale", listOf(layer(RcGraphicsLayerModifier.SCALE_X))),
      canvas(
        "color-interpolation",
        data =
          listOf(
            RcColorConstant(COLOR_A, RED),
            RcColorConstant(COLOR_B, BLUE),
            RcColorExpression(
              COLOR_OUT,
              RcColorExpression.ID_ID_INTERPOLATE,
              COLOR_A,
              COLOR_B,
              HOST.bits,
            ),
          ),
        draws =
          listOf(
            RcPaintData(listOf(PAINT_COLOR_ID, COLOR_OUT)),
            rect(literal(0f), literal(0f), literal(40f), literal(40f)),
          ),
      ),
      canvas(
        "animated-expression",
        listOf(RcWidthModifier(RcDimensionType.EXACT, reference(ANIMATED))),
        data =
          listOf(
            RcFloatExpression(
              ANIMATED,
              listOf(HOST, literal(2f), operator(3)),
              listOf(literal(0.5f)),
            ),
          ),
      ),
      canvas(
        "conditional",
        draws =
          listOf(
            RcConditionalOperations(RcConditionalOperations.LESS_THAN, HOST, literal(10f)),
            rect(literal(0f), literal(0f), literal(40f), literal(40f)),
            END,
          ),
      ),
      canvas("visibility", listOf(RcVisibilityModifier(HOST_ID))),
      Case("weight", weightDocument()),
      canvas(
        "dynamic-list-length",
        data = listOf(RcDynamicFloatList(LIST, HOST)),
      ),
      canvas("canvas-geometry", draws = listOf(rect(HOST, HOST, HOST, HOST))),
      text("text-from-float", FORMATTED, listOf(RcTextFromFloat(FORMATTED, HOST, 2, 2, 0))),
    )

  /** Rendered here only: the Swift fixtures above do not include them yet. */
  private val playerOnlyCases: List<Case> =
    listOf(
      text("text-size", HOST_TEXT_ID, fontSize = HOST),
      Case("core-text-size", coreTextDocument(fontSize = HOST)),
      canvas(
        "paint-text-size",
        draws =
          listOf(
            RcPaintData(listOf(PAINT_TEXT_SIZE, HOST.bits)),
            RcDrawTextAnchored(
              HOST_TEXT_ID,
              literal(10f),
              literal(30f),
              literal(0f),
              literal(0f),
              0,
            ),
          ),
      ),
      canvas(
        "nested-loop",
        draws =
          listOf(
            RcLoopOperation(0, literal(0f), literal(1f), HOST),
            RcLoopOperation(0, literal(0f), literal(1f), HOST),
            rect(literal(0f), literal(0f), literal(1f), literal(1f)),
            END,
            END,
          ),
      ),
    )

  private val textCases: List<Case> =
    listOf(
      text("long-text", HOST_TEXT_ID),
      text("long-text-merge", MERGED, listOf(RcTextMerge(MERGED, HOST_TEXT_ID, HOST_TEXT_ID))),
      canvas(
        "long-text-length-as-width",
        listOf(RcWidthModifier(RcDimensionType.EXACT, reference(LENGTH))),
        data = listOf(RcTextLength(LENGTH, HOST_TEXT_ID)),
      ),
    )

  /** A `CoreText` showing the host's text at [fontSize], in a box. */
  private fun coreTextDocument(fontSize: RcFloatWord): RcDocument =
    document(
      listOf(
        RcRootLayout(1),
        RcLayoutContent(2),
        RcBoxLayout(3, 30, 1, 1),
        RcLayoutContent(4),
        RcCoreText(
          textId = HOST_TEXT_ID,
          properties =
            listOf(
              RcTextStyleProperty.IntValue(1, 5),
              RcTextStyleProperty.IntValue(2, 50),
              RcTextStyleProperty.IntValue(3, INK),
              RcTextStyleProperty.FloatValue(5, fontSize),
            ),
        ),
        END,
      ) + List(4) { END },
    )

  /** A row of a 30px box and a box weighted by the host's float. */
  private fun weightDocument(): RcDocument =
    document(
      listOf(
        RcRootLayout(1),
        RcLayoutContent(2),
        RcRowLayout(3, 30, 1, 1, literal(0f)),
        RcWidthModifier(RcDimensionType.EXACT, literal(WIDTH.toFloat())),
        RcLayoutContent(4),
        RcBoxLayout(5, 50, 1, 1),
        RcWidthModifier(RcDimensionType.EXACT, literal(30f)),
        RcLayoutContent(51),
        END,
        END,
        RcBoxLayout(6, 60, 1, 1),
        RcWidthModifier(RcDimensionType.WEIGHT, HOST),
        RcLayoutContent(61),
        END,
        END,
      ) + List(4) { END },
    )

  private fun document(operations: List<RcOperation>): RcDocument =
    RcDocument(
      RcHeader(RcVersion(1, 0, 0), legacyWidth = WIDTH, legacyHeight = HEIGHT, modern = false),
      listOf(
        RcFloatConstant(HOST_ID, literal(1f)),
        RcNamedVariable(HOST_ID, RcNamedVariable.FLOAT_TYPE, FLOAT_NAME),
        RcTextData(HOST_TEXT_ID, "seed"),
        RcNamedVariable(HOST_TEXT_ID, RcNamedVariable.STRING_TYPE, TEXT_NAME),
      ) + operations,
    )

  private fun render(document: RcDocument, values: Map<String, RcNamedValue>): Bitmap {
    val namedValues = mutableStateMapOf<String, RcNamedValue>().apply { putAll(values) }
    val scene =
      ImageComposeScene(width = WIDTH, height = HEIGHT, density = Density(1f)) {
        RcComposePlayer(document, namedValues = namedValues)
      }
    try {
      val bitmap = Bitmap().apply { allocN32Pixels(WIDTH, HEIGHT) }
      // A few frames, so an animation steps and a deferred layout pass runs.
      for (frame in 0 until FRAMES) scene.render(frame * FRAME_NANOS)
      check(scene.render(FRAMES * FRAME_NANOS).readPixels(bitmap))
      return bitmap
    } finally {
      scene.close()
    }
  }

  private fun rect(left: RcFloatWord, top: RcFloatWord, right: RcFloatWord, bottom: RcFloatWord) =
    RcDraw4(RcOpcodes.DRAW_RECT, left, top, right, bottom)

  private fun layer(index: Int) =
    RcGraphicsLayerModifier(listOf(RcGraphicsLayerAttribute.FloatValue(index, HOST)))

  companion object {
    const val FIXTURE_PROPERTY: String = "rc.hostValueEdges.fixtures"
    const val UPDATE_PROPERTY: String = "rc.hostValueEdges.update"
    private const val INDEX = "index.tsv"
    private const val FLOAT_KIND = "float"
    private const val TEXT_KIND = "text"

    /** The host's names: the Swift test writes its values under the same ones. */
    private const val FLOAT_NAME = "USER:v"
    private const val TEXT_NAME = "USER:s"

    private const val WIDTH = 100
    private const val HEIGHT = 60
    private const val FRAMES = 4
    private const val FRAME_NANOS = 16_000_000L

    /**
     * A case's frames, composition included, in a fraction of this: a loop nest the host can run
     * forever stops at AndroidX's 20 000 operations a frame, a few milliseconds of rects.
     */
    private const val MAX_RENDER_MILLIS = 3_000L

    private const val HOST_ID = 100
    private const val HOST_TEXT_ID = 101
    private const val ANIMATED = 110
    private const val COLOR_A = 120
    private const val COLOR_B = 121
    private const val COLOR_OUT = 122
    private const val LIST = 130
    private const val FORMATTED = 140
    private const val LENGTH = 141
    private const val MERGED = 142

    /** AndroidX `PaintBundle.TEXT_SIZE`: the paint's text size is the float that follows. */
    private const val PAINT_TEXT_SIZE = 1

    /** AndroidX `PaintBundle.COLOR_ID`: the paint's colour is the colour variable that follows. */
    private const val PAINT_COLOR_ID = 19
    private const val PURPLE = 0xff6750a4.toInt()
    private const val INK = 0xff101828.toInt()
    private const val RED = 0xffff0000.toInt()
    private const val BLUE = 0xff0000ff.toInt()

    private val END = RcNoArg(RcOpcodes.CONTAINER_END)
    private val HOST = reference(HOST_ID)

    private val EDGE_FLOATS =
      floatArrayOf(Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY, -0f, 3e9f)

    /** Past the values the Swift fixtures are rendered with. */
    private val HUGE_AND_NEGATIVE_FLOATS = floatArrayOf(1e30f, -1e30f, -5f, Float.MAX_VALUE)

    private val LONG_TEXTS = listOf("x".repeat(4_001), "word ".repeat(20_000), "😀".repeat(50_000))

    /** A megabyte of one word: Skia's line breaker walked it once per line it filled. */
    private val MEGABYTE_WORD = "x".repeat(1 shl 20)

    private fun literal(value: Float) = RcFloatWord.literal(value)

    private fun reference(id: Int) = RcFloatWord(0xff800000.toInt() or id)

    private fun operator(id: Int) =
      RcFloatExpressionEvaluator.operatorWord(RcFloatExpressionEvaluator.OFFSET + id)
  }
}
