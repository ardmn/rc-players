package ee.schimke.composeai.rcplayer.compose

import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.unit.Density
import ee.schimke.composeai.rcplayer.protocol.RcCanvasLayout
import ee.schimke.composeai.rcplayer.protocol.RcCollapsibleRowLayout
import ee.schimke.composeai.rcplayer.protocol.RcColumnLayout
import ee.schimke.composeai.rcplayer.protocol.RcConditionalOperations
import ee.schimke.composeai.rcplayer.protocol.RcDimensionType
import ee.schimke.composeai.rcplayer.protocol.RcDocument
import ee.schimke.composeai.rcplayer.protocol.RcDraw4
import ee.schimke.composeai.rcplayer.protocol.RcFloatConstant
import ee.schimke.composeai.rcplayer.protocol.RcFloatWord
import ee.schimke.composeai.rcplayer.protocol.RcHeader
import ee.schimke.composeai.rcplayer.protocol.RcHeightModifier
import ee.schimke.composeai.rcplayer.protocol.RcLayoutContent
import ee.schimke.composeai.rcplayer.protocol.RcLoopOperation
import ee.schimke.composeai.rcplayer.protocol.RcNamedVariable
import ee.schimke.composeai.rcplayer.protocol.RcNoArg
import ee.schimke.composeai.rcplayer.protocol.RcOpcodes
import ee.schimke.composeai.rcplayer.protocol.RcOperation
import ee.schimke.composeai.rcplayer.protocol.RcPaintData
import ee.schimke.composeai.rcplayer.protocol.RcRootLayout
import ee.schimke.composeai.rcplayer.protocol.RcVersion
import ee.schimke.composeai.rcplayer.protocol.RcVisibilityModifier
import ee.schimke.composeai.rcplayer.protocol.RcWidthModifier
import ee.schimke.composeai.rcplayer.runtime.RcNamedValue
import kotlin.test.Test
import kotlin.test.assertEquals
import org.jetbrains.skia.Bitmap

/**
 * AndroidX counts a frame's loop operations from zero on every paint (CoreDocument.java:2357,
 * LoopOperation.java:126-140), so only the loops that paint spend the budget.
 */
class RcLoopBudgetRenderTest {
  @Test
  fun aLoopThatStoppedUnderAConditionalLeavesTheBudgetToLaterLoops() {
    val spender =
      listOf(RcConditionalOperations(RcConditionalOperations.EQUAL, HOST, literal(SHOWN))) +
        endlessLoop() +
        END
    assertTheSecondCanvasDrawsOnceTheFirstLoopStops(canvas(FIRST, spender))
  }

  @Test
  fun aLoopWhoseComponentWentGoneLeavesTheBudgetToLaterLoops() {
    assertTheSecondCanvasDrawsOnceTheFirstLoopStops(
      canvas(FIRST, endlessLoop(), visibility = RcVisibilityModifier(HOST_ID)),
    )
  }

  /** AndroidX lays an INVISIBLE component out and does not paint it, so its loop spends nothing. */
  @Test
  fun aLoopWhoseComponentTurnedInvisibleLeavesTheBudgetToLaterLoops() {
    assertTheSecondCanvasDrawsOnceTheFirstLoopStops(
      canvas(FIRST, endlessLoop(), visibility = RcVisibilityModifier(HOST_ID)),
      stopped = INVISIBLE,
    )
  }

  /**
   * Known limitation, pinned: a child a collapsible row drops for want of room is neither placed
   * nor drawn, so the count its last drawing recorded stands and a later loop stays blank, where
   * AndroidX, which does not paint it, draws that loop.
   */
  @Test
  fun aLoopWhoseComponentACollapsibleRowDropsStillHoldsTheBudget() {
    val row =
      listOf(
        RcCollapsibleRowLayout(5, -1, 1, 1, literal(0f)),
        RcWidthModifier(RcDimensionType.EXACT, HOST),
        RcHeightModifier(RcDimensionType.EXACT, literal(CANVAS_HEIGHT)),
        RcLayoutContent(6),
      ) + canvas(FIRST, endlessLoop(), width = 30f) + listOf(END, END)
    assertTheSecondCanvasDrawsOnceTheFirstLoopStops(
      row,
      shown = WIDTH.toFloat(),
      stopped = 10f,
      redAfter = 0,
    )
  }

  /**
   * [first]'s loop spends the whole budget while the host value is [shown]; once the host writes
   * [stopped], the second canvas's one-pass loop draws its red square ([redAfter] pixels).
   */
  private fun assertTheSecondCanvasDrawsOnceTheFirstLoopStops(
    first: List<RcOperation>,
    shown: Float = SHOWN,
    stopped: Float = HIDDEN,
    redAfter: Int = (SIZE * SIZE).toInt(),
  ) {
    val second =
      canvas(
        SECOND,
        listOf(
          RcLoopOperation(0, literal(0f), literal(1f), literal(1f)),
          RcDraw4(RcOpcodes.DRAW_RECT, literal(0f), literal(0f), literal(SIZE), literal(SIZE)),
          END,
        ),
      )
    val document =
      RcDocument(
        RcHeader(RcVersion(1, 0, 0), legacyWidth = WIDTH, legacyHeight = HEIGHT, modern = false),
        listOf(
          RcFloatConstant(HOST_ID, literal(shown)),
          RcNamedVariable(HOST_ID, RcNamedVariable.FLOAT_TYPE, HOST_NAME),
          RcFloatConstant(ENDLESS_ID, literal(Float.POSITIVE_INFINITY)),
          RcRootLayout(1),
          RcLayoutContent(2),
          RcColumnLayout(3, -1, 1, 1, literal(0f)),
          RcLayoutContent(4),
        ) + first + second + List(4) { END },
      )
    val values =
      mutableStateMapOf<String, RcNamedValue>(HOST_NAME to RcNamedValue.FloatValue(shown))
    val scene =
      ImageComposeScene(width = WIDTH, height = HEIGHT, density = Density(1f)) {
        RcComposePlayer(document, namedValues = values)
      }
    try {
      var time = 0L
      fun redPixels(): Int {
        val bitmap = Bitmap().apply { allocN32Pixels(WIDTH, HEIGHT) }
        repeat(FRAMES) {
          scene.render(time)
          time += FRAME_NANOS
        }
        check(scene.render(time).readPixels(bitmap))
        return (0 until WIDTH * HEIGHT).count { bitmap.getColor(it % WIDTH, it / WIDTH) == RED }
      }
      assertEquals(0, redPixels(), "the first loop spends the budget")
      Snapshot.withMutableSnapshot { values[HOST_NAME] = RcNamedValue.FloatValue(stopped) }
      assertEquals(redAfter, redPixels(), "the second loop draws")
    } finally {
      scene.close()
    }
  }

  /** A canvas [width] by [CANVAS_HEIGHT] drawing [draws] in red. */
  private fun canvas(
    id: Int,
    draws: List<RcOperation>,
    visibility: RcOperation? = null,
    width: Float = WIDTH.toFloat(),
  ): List<RcOperation> =
    listOfNotNull(
      RcCanvasLayout(id, -1),
      RcWidthModifier(RcDimensionType.EXACT, literal(width)),
      RcHeightModifier(RcDimensionType.EXACT, literal(CANVAS_HEIGHT)),
      visibility,
      RcNoArg(RcOpcodes.CANVAS_OPERATIONS),
      RcPaintData(listOf(PAINT_COLOR, RED)),
    ) + draws + listOf(END, END)

  /** A loop the host never ends, an empty rect each pass: it spends the whole frame's budget. */
  private fun endlessLoop(): List<RcOperation> =
    listOf(
      RcLoopOperation(0, literal(0f), literal(1f), ENDLESS),
      RcDraw4(RcOpcodes.DRAW_RECT, literal(0f), literal(0f), literal(0f), literal(0f)),
      END,
    )

  private companion object {
    const val WIDTH = 40
    const val HEIGHT = 40
    const val CANVAS_HEIGHT = 20f
    const val SIZE = 10f
    /**
     * Frames before a readback: past AndroidX's 300 ms default exit animation (`Component.layout`).
     */
    const val FRAMES = 30
    const val FRAME_NANOS = 16_000_000L
    const val FIRST = 10
    const val SECOND = 20
    const val HOST_ID = 100
    const val ENDLESS_ID = 101
    const val HOST_NAME = "USER:v"

    /** AndroidX `Component.Visibility.VISIBLE`, `GONE`, `INVISIBLE` (Component.java:548-550). */
    const val SHOWN = 1f
    const val HIDDEN = 0f
    const val INVISIBLE = 2f

    /** AndroidX `PaintBundle.COLOR` (PaintBundle.java:810): the colour that follows. */
    const val PAINT_COLOR = 4
    const val RED = 0xffff0000.toInt()
    val END = RcNoArg(RcOpcodes.CONTAINER_END)
    val HOST = RcFloatWord(0xff800000.toInt() or HOST_ID)
    val ENDLESS = RcFloatWord(0xff800000.toInt() or ENDLESS_ID)

    fun literal(value: Float) = RcFloatWord.literal(value)
  }
}
