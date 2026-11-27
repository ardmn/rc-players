package ee.schimke.composeai.rcplayer.compose

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import org.jetbrains.skia.Bitmap

/**
 * [RcBasicText] lays out only the part of a long text that can be seen, and draws exactly what
 * [BasicText] draws with the whole of it: the same pixels for one long word, words, lines, CJK,
 * emoji, combining marks and digits, in narrow, square and wide boxes, every alignment, clipped and
 * ellipsized, capped by lines and auto-sized. The threshold is 0 here, so every text is cut, and
 * each is short enough for the whole of it to lay out in the reference.
 *
 * The reference takes an `onTextLayout`, as the player's text does: without one, the whole text
 * drew 19 of these cases a pixel row differently below its last line than with one.
 */
class RcLongTextTest {
  @Test(timeout = 300_000)
  fun aCutTextDrawsWhatTheWholeTextDraws() {
    val failures = mutableListOf<String>()
    var cut = 0
    var cases = 0
    for ((name, text) in TEXTS) {
      for ((width, height) in BOXES) {
        for (style in STYLES) {
          for ((overflow, maxLines) in LIMITS) {
            cases++
            val label = "$name in ${width}x$height, ${style.first}, $overflow, $maxLines lines"
            val (same, wasCut) =
              drawsTheWhole(text, width, height, style.second, overflow, maxLines)
            if (wasCut) cut++
            if (!same) failures += label
          }
        }
      }
    }
    assertTrue(
      failures.isEmpty(),
      "${failures.size} of $cases differ:\n" + failures.joinToString("\n"),
    )
    // Most are cut: a check that only ever compared the whole text with itself would pass too.
    assertTrue(cut > cases / 2, "only $cut of $cases texts were cut")
  }

  /**
   * A prefix whose last lines end just inside the box is not taken: those lines break where the
   * prefix ends, not where the whole text does. One long word ends its last line short; a long word
   * after short ones fills the rest of their line, where the few letters of it a prefix holds move
   * to the next. Each box shows the top of one of the first prefix's last lines.
   */
  @Test
  fun aPrefixWhoseLastLinesShowIsNotTaken() {
    for (text in listOf("x".repeat(12_000), "w ".repeat(500) + "y".repeat(12_000))) {
      var prefix: TextLayoutResult? = null
      render(WIDTH, 4_000) {
        BasicText(
          text.substring(0, RC_FIRST_TEXT_PREFIX_LENGTH),
          Modifier,
          STYLE,
          onTextLayout = { prefix = it },
        )
      }
      val laidOut = checkNotNull(prefix)
      for (shown in 1..RC_UNSETTLED_PREFIX_LINES) {
        val height = laidOut.getLineTop(laidOut.lineCount - shown).toInt() + GLYPH_TOP
        val (same, _) = drawsTheWhole(text, WIDTH, height, STYLE, TextOverflow.Clip, Int.MAX_VALUE)
        assertTrue(
          same,
          "${text.take(4)}: the box shows the prefix's line ${-shown}, drawn otherwise",
        )
      }
    }
  }

  /** Whether [RcBasicText] draws [text] as [BasicText] does, and whether it cut it to do so. */
  private fun drawsTheWhole(
    text: String,
    width: Int,
    height: Int,
    style: TextStyle,
    overflow: TextOverflow,
    maxLines: Int,
  ): Pair<Boolean, Boolean> {
    val reference =
      render(width, height) {
        BasicText(
          text,
          Modifier,
          style,
          onTextLayout = {},
          overflow = overflow,
          maxLines = maxLines,
        )
      }
    var shownLength = -1
    val candidate =
      render(width, height) {
        RcBasicText(
          text = text,
          modifier = Modifier,
          onTextLayout = { shownLength = it.layoutInput.text.length },
          style = style,
          overflow = overflow,
          maxLines = maxLines,
          textMeasurer = rememberTextMeasurer(),
          longTextLength = 0,
        )
      }
    return reference.contentEquals(candidate) to (shownLength in 0 until text.length)
  }

  @Test
  fun anAutoSizedCutTextDrawsWhatTheWholeTextDraws() {
    val text = "x".repeat(40_000)
    val style = TextStyle(color = Color.Black)
    val autoSize =
      TextAutoSize.StepBased(minFontSize = 6.sp, maxFontSize = 40.sp, stepSize = 0.5.sp)
    val reference =
      render(120, 90) {
        BasicText(
          text,
          Modifier,
          style,
          onTextLayout = {},
          overflow = TextOverflow.Clip,
          autoSize = autoSize,
        )
      }
    var shownLength = -1
    val candidate =
      render(120, 90) {
        RcBasicText(
          text = text,
          modifier = Modifier,
          onTextLayout = { shownLength = it.layoutInput.text.length },
          style = style,
          overflow = TextOverflow.Clip,
          maxLines = Int.MAX_VALUE,
          textMeasurer = rememberTextMeasurer(),
          autoSize = autoSize,
          autoSizeMinFontSize = 6.sp,
          longTextLength = 0,
        )
      }
    assertTrue(shownLength in 0 until text.length, "the text was not cut")
    assertContentEquals(reference, candidate)
  }

  /** The semantics hold the whole text, not the part laid out. */
  @OptIn(ExperimentalComposeUiApi::class)
  @Test
  fun theSemanticsHoldTheWholeText() {
    val text = "word ".repeat(8_000)
    val scene =
      ImageComposeScene(width = 100, height = 100, density = Density(1f)) {
        Box(Modifier.size(100.dp)) { cutText(text) }
      }
    try {
      scene.render(0L)
      val texts = buildList {
        fun walk(node: SemanticsNode) {
          node.config.getOrNull(SemanticsProperties.Text)?.forEach { add(it.text) }
          node.children.forEach(::walk)
        }
        scene.semanticsOwners.firstOrNull()?.unmergedRootSemanticsNode?.let(::walk)
      }
      assertEquals(listOf(text), texts)
    } finally {
      scene.close()
    }
  }

  /**
   * A parent that asks a cut text its intrinsic size gets the whole text's, as from [BasicText]: a
   * `SubcomposeLayout` has none of its own and threw.
   */
  @Test
  fun anIntrinsicParentGetsTheWholeTextsSize() {
    val text = "word ".repeat(8_000)
    fun size(content: @Composable () -> Unit): IntArray =
      render(100, 4_000) { Row(Modifier.height(IntrinsicSize.Min)) { content() } }
    val reference = size { BasicText(text, Modifier, STYLE, onTextLayout = {}) }
    val candidate = size { cutText(text) }
    assertContentEquals(reference, candidate)
  }

  @Composable
  private fun cutText(text: String) =
    RcBasicText(
      text = text,
      modifier = Modifier,
      onTextLayout = {},
      style = STYLE,
      overflow = TextOverflow.Clip,
      maxLines = Int.MAX_VALUE,
      textMeasurer = rememberTextMeasurer(),
      longTextLength = 0,
    )

  private fun render(width: Int, height: Int, content: @Composable () -> Unit): IntArray {
    val scene =
      ImageComposeScene(width = width, height = height, density = Density(1f)) {
        Box(Modifier.size(width.dp, height.dp)) { content() }
      }
    try {
      val bitmap = Bitmap().apply { allocN32Pixels(width, height) }
      check(scene.render(0L).readPixels(bitmap))
      return IntArray(width * height) { bitmap.getColor(it % width, it / width) }
    } finally {
      scene.close()
    }
  }

  private companion object {
    val STYLE = TextStyle(color = Color.Black, fontSize = 14.sp)
    const val WIDTH = 200

    /** Far enough into a line for an `x`'s ink to show. */
    const val GLYPH_TOP = 10

    val TEXTS =
      listOf(
        "one word" to "x".repeat(12_000),
        "words" to "word ".repeat(4_000),
        "mixed" to "Abc 123, déf-ghi; ".repeat(1_200),
        "lines" to "line\n".repeat(3_000),
        "cjk" to "漢字かな".repeat(3_000),
        "emoji" to "😀👍🏽".repeat(3_000),
        "combining" to "é".repeat(6_000),
        "digits" to "1234567890".repeat(2_000),
        // A prefix of the short lines is narrower than the box, the whole text is not.
        "short lines, then a long one" to "ab\n".repeat(3_000) + "x ".repeat(400),
      )

    val BOXES = listOf(37 to 300, 200 to 200, 400 to 50)

    val STYLES =
      listOf(
        "14 sp start" to STYLE,
        "9 sp centred" to STYLE.copy(fontSize = 9.sp, textAlign = TextAlign.Center),
        "20 sp justified" to STYLE.copy(fontSize = 20.sp, textAlign = TextAlign.Justify),
        "12 sp end, line height 2" to
          STYLE.copy(fontSize = 12.sp, textAlign = TextAlign.End, lineHeight = 24.sp),
        "unspecified size" to STYLE.copy(fontSize = TextUnit.Unspecified),
      )

    val LIMITS =
      listOf(
        TextOverflow.Clip to Int.MAX_VALUE,
        TextOverflow.Ellipsis to Int.MAX_VALUE,
        TextOverflow.Clip to 3,
        TextOverflow.Ellipsis to 2,
      )
  }
}
