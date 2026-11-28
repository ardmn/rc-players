package ee.schimke.composeai.rcplayer.compose

import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.FirstBaseline
import androidx.compose.ui.layout.IntrinsicMeasurable
import androidx.compose.ui.layout.IntrinsicMeasureScope
import androidx.compose.ui.layout.LastBaseline
import androidx.compose.ui.layout.Measurable
import androidx.compose.ui.layout.MeasureResult
import androidx.compose.ui.layout.MeasureScope
import androidx.compose.ui.layout.SubcomposeLayout
import androidx.compose.ui.node.LayoutModifierNode
import androidx.compose.ui.node.ModifierNodeElement
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.text
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.isSpecified
import kotlin.math.ceil

/**
 * A text component's [BasicText] that lays out only the visible part of a very long text.
 *
 * Skia's line breaker is quadratic in a word too long for a line, so a host's megabyte-long word
 * took minutes per frame. A text longer than [longTextLength] is laid out as [rcVisibleTextPrefix];
 * what is drawn, the size, the overflow and the semantics' text stay the whole text's, while
 * `onTextLayout` and `LastBaseline` see the prefix's lines. Crossing the length swaps the subtree,
 * which holds no state. The text is not cut where lines can show past the box
 * ([TextOverflow.Visible], unbounded height), where [cuttable] is false (the Ahem model sizes the
 * whole text), or where the line breaker looks past a line ([rcTextBreaksLinesGreedily]).
 *
 * @param autoSizeMinFontSize the smallest size [autoSize] may choose; the prefix is measured at it.
 */
@Composable
internal fun RcBasicText(
  text: String,
  modifier: Modifier,
  onTextLayout: (TextLayoutResult) -> Unit,
  style: TextStyle,
  overflow: TextOverflow,
  maxLines: Int,
  textMeasurer: TextMeasurer,
  autoSize: TextAutoSize? = null,
  autoSizeMinFontSize: TextUnit = TextUnit.Unspecified,
  cuttable: Boolean = true,
  longTextLength: Int = RC_LONG_TEXT_LENGTH,
) {
  val mayCut =
    rcTextBreaksLinesGreedily &&
      cuttable &&
      text.length > longTextLength &&
      overflow != TextOverflow.Visible &&
      (autoSize == null || autoSizeMinFontSize.isSpecified)
  if (!mayCut) {
    BasicText(
      text = text,
      modifier = modifier,
      style = style,
      onTextLayout = onTextLayout,
      overflow = overflow,
      maxLines = maxLines,
      autoSize = autoSize,
    )
    return
  }
  val measureStyle = if (autoSize != null) style.copy(fontSize = autoSizeMinFontSize) else style
  SubcomposeLayout(
    modifier.then(RcWholeTextIntrinsicsElement(text, style, overflow, maxLines, textMeasurer)),
  ) { constraints ->
    val shown = rcVisibleTextPrefix(text, constraints, measureStyle, maxLines, textMeasurer)
    val placeable =
      subcompose(Unit) {
          BasicText(
            text = shown,
            // The outermost value of a key wins on a node: the whole text, not the prefix.
            modifier = Modifier.semantics { this.text = AnnotatedString(text) },
            style = style,
            onTextLayout = onTextLayout,
            overflow = overflow,
            maxLines = maxLines,
            autoSize = autoSize,
          )
        }
        .single()
        .measure(constraints)
    layout(
      placeable.width,
      placeable.height,
      mapOf(FirstBaseline to placeable[FirstBaseline], LastBaseline to placeable[LastBaseline]),
    ) {
      placeable.place(0, 0)
    }
  }
}

/**
 * The first prefix of [text], each try four times longer, that lays out in [constraints] all of
 * [text] that can be seen; [text] itself when none is found.
 *
 * Skia breaks lines greedily, so a prefix lays out as the whole text does but for its last
 * [RC_UNSETTLED_PREFIX_LINES] lines; once the others pass the box's height or [maxLines], it clips
 * and overflows as the whole does. A prefix is taken only if it is at least as wide as the box,
 * [text] has no right-to-left character (bidi levels may depend on what follows the cut), and it
 * holds the text's first letter (the paragraph's direction).
 */
internal fun rcVisibleTextPrefix(
  text: String,
  constraints: Constraints,
  style: TextStyle,
  maxLines: Int,
  textMeasurer: TextMeasurer,
): String {
  if (!constraints.hasBoundedHeight || !constraints.hasBoundedWidth) return text
  // Two linear scans of the text per measure, far cheaper than one layout of it.
  if (text.any(::isRightToLeft)) return text
  val firstLetter = text.indexOfFirst { it.isLetter() }
  var length = RC_FIRST_TEXT_PREFIX_LENGTH
  while (length < text.length) {
    // Never between the halves of a surrogate pair.
    val cut = if (text[length - 1].isHighSurrogate()) length + 1 else length
    if (cut >= text.length) break
    if (cut > firstLetter) {
      val laidOut =
        textMeasurer.measure(
          text = text.substring(0, cut),
          style = style,
          overflow = TextOverflow.Clip,
          maxLines = Int.MAX_VALUE,
          constraints =
            Constraints(minWidth = constraints.minWidth, maxWidth = constraints.maxWidth),
        )
      val settled = laidOut.lineCount - RC_UNSETTLED_PREFIX_LINES
      if (
        settled > 0 &&
          laidOut.multiParagraph.intrinsics.maxIntrinsicWidth >= constraints.maxWidth &&
          (settled > maxLines || laidOut.getLineBottom(settled - 1) > constraints.maxHeight)
      ) {
        return text.substring(0, cut)
      }
    }
    length *= 4
  }
  return text
}

/** [text]'s first [RC_LONG_TEXT_LENGTH] chars, never between the halves of a surrogate pair. */
private fun longTextHead(text: String): String {
  val length =
    if (text.length > RC_LONG_TEXT_LENGTH && text[RC_LONG_TEXT_LENGTH - 1].isHighSurrogate()) {
      RC_LONG_TEXT_LENGTH + 1
    } else {
      RC_LONG_TEXT_LENGTH
    }
  return text.take(length)
}

/**
 * Whether [text] has a run of more than [length] chars with no whitespace. Linear; a text with no
 * space at all (CJK, say) counts as one word, so its intrinsic height stays a lower bound.
 */
internal fun rcHasWordLongerThan(text: String, length: Int): Boolean {
  var run = 0
  for (char in text) {
    run = if (char.isWhitespace()) 0 else run + 1
    if (run > length) return true
  }
  return false
}

/** Right-to-left letters, Arabic digits and the bidi controls. */
private fun isRightToLeft(char: Char): Boolean =
  when (char.code) {
    in 0x0590..0x08FF,
    in 0xFB1D..0xFDFF,
    in 0xFE70..0xFEFF,
    0x061C,
    0x200F,
    in 0x202A..0x202E,
    in 0x2066..0x2069 -> true
    // The supplementary right-to-left blocks, U+10800..U+10FFF and U+1E800..U+1EFFF.
    in 0xD802..0xD803,
    0xD83A,
    0xD83B -> true
    else -> false
  }

/**
 * Text longer than this may be cut to what can be seen. One word this long took 19 ms per Skia
 * layout in a 200 px box on a desktop JVM, and a text lays out a few times a frame.
 */
internal const val RC_LONG_TEXT_LENGTH: Int = 16_384

/** The first prefix [rcVisibleTextPrefix] tries. */
internal const val RC_FIRST_TEXT_PREFIX_LENGTH: Int = 1024

/** The prefix's last lines, which the word it cuts may break differently than the whole text. */
internal const val RC_UNSETTLED_PREFIX_LINES: Int = 2

/**
 * The whole text's intrinsic sizes, as [BasicText] reports them: a [SubcomposeLayout] has none of
 * its own, and a parent that asks (a `FitBox`'s probe, an intrinsic row) would throw.
 */
private data class RcWholeTextIntrinsicsElement(
  val text: String,
  val style: TextStyle,
  val overflow: TextOverflow,
  val maxLines: Int,
  val textMeasurer: TextMeasurer,
) : ModifierNodeElement<RcWholeTextIntrinsicsNode>() {
  /** Whether [text] has a word Skia would break quadratically: one scan, on the first ask. */
  val hasOverlongWord: Boolean by lazy { rcHasWordLongerThan(text, RC_LONG_TEXT_LENGTH) }

  override fun create() = RcWholeTextIntrinsicsNode(this)

  override fun update(node: RcWholeTextIntrinsicsNode) {
    node.element = this
  }
}

private class RcWholeTextIntrinsicsNode(var element: RcWholeTextIntrinsicsElement) :
  Modifier.Node(), LayoutModifierNode {
  override fun MeasureScope.measure(
    measurable: Measurable,
    constraints: Constraints,
  ): MeasureResult {
    val placeable = measurable.measure(constraints)
    return layout(placeable.width, placeable.height) { placeable.place(0, 0) }
  }

  /**
   * The text laid out at [width]. Skia breaks a word longer than a line quadratically (a megabyte
   * word took 87 s under a `FitBox`), so at a bounded width a text with a word past
   * [RC_LONG_TEXT_LENGTH] lays out only its first [RC_LONG_TEXT_LENGTH] chars: its height is then a
   * lower bound, exact once the prefix fills [maxLines]. Any other text lays out whole.
   */
  private fun laidOut(width: Int): TextLayoutResult =
    element.textMeasurer.measure(
      text =
        if (width != Constraints.Infinity && element.hasOverlongWord) longTextHead(element.text)
        else element.text,
      style = element.style,
      overflow = element.overflow,
      maxLines = element.maxLines,
      constraints =
        if (width == Constraints.Infinity) Constraints() else Constraints(maxWidth = width),
    )

  override fun IntrinsicMeasureScope.minIntrinsicWidth(
    measurable: IntrinsicMeasurable,
    height: Int,
  ): Int = ceil(laidOut(Constraints.Infinity).multiParagraph.intrinsics.minIntrinsicWidth).toInt()

  override fun IntrinsicMeasureScope.maxIntrinsicWidth(
    measurable: IntrinsicMeasurable,
    height: Int,
  ): Int = ceil(laidOut(Constraints.Infinity).multiParagraph.intrinsics.maxIntrinsicWidth).toInt()

  override fun IntrinsicMeasureScope.minIntrinsicHeight(
    measurable: IntrinsicMeasurable,
    width: Int,
  ): Int = laidOut(width).size.height

  override fun IntrinsicMeasureScope.maxIntrinsicHeight(
    measurable: IntrinsicMeasurable,
    width: Int,
  ): Int = laidOut(width).size.height
}
