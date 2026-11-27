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
 * A text component's [BasicText], which lays out only the part of a very long text that can be
 * seen.
 *
 * A host may write a string of any length, and Skia's line breaker is quadratic in a word too long
 * for a line: for every line it fills it walks on to the end of that word, so a megabyte of one
 * word in a 200 px box cost a million characters times 40 000 lines per layout, and a text is laid
 * out several times a frame. A frame took minutes. Text with spaces is linear, but still shapes and
 * breaks every character on every layout.
 *
 * A text of up to [RC_LONG_TEXT_LENGTH] characters is the plain [BasicText] it always was. A longer
 * one is measured first, with the incoming constraints, and handed to [BasicText] as a prefix,
 * grown fourfold until its settled lines reach past the box: [rcVisibleTextPrefix]. What is drawn,
 * the size, whether the text overflows and the semantics' text (the whole of it) do not change.
 * What can: the host's `onTextLaidOut` and a `LastBaseline` see the prefix's lines, and a text
 * crossing the threshold is a new subtree, which holds no state of its own.
 *
 * The text is not cut where its lines can be seen past the box ([TextOverflow.Visible], or a box of
 * unbounded height), where [cuttable] is false (the closed-form Ahem model sizes the whole text
 * itself), or where the platform's line breaker may look past a line ([rcTextBreaksLinesGreedily]).
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
  /** The smallest size [autoSize] may choose; the prefix is measured at it. */
  autoSizeMinFontSize: TextUnit = TextUnit.Unspecified,
  cuttable: Boolean = true,
  longTextLength: Int = RC_LONG_TEXT_LENGTH,
) {
  if (
    !rcTextBreaksLinesGreedily ||
      !cuttable ||
      text.length <= longTextLength ||
      overflow == TextOverflow.Visible ||
      (autoSize != null && !autoSizeMinFontSize.isSpecified)
  ) {
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
 * The prefix of [text] that lays out, in [constraints], exactly as much of [text] as can be seen:
 * [text] itself when no shorter one is known to.
 *
 * Skia breaks lines greedily, deciding each break from the text up to the end of the word it is in,
 * so a prefix lays its lines out as the whole text does until the last word it cuts: every line but
 * its last two. A prefix whose lines but those two reach past the box's height, or number more than
 * [maxLines], is laid out, clipped and reported as overflowing exactly as the whole is. Each try
 * quadruples the prefix, so the work is that of the last one, a few times the box's characters.
 *
 * The prefix is also only taken when
 * - it is at least as wide as the box, so the layout is the box's width either way, not the widest
 *   line's;
 * - [text] has no right-to-left character, so no bidi level before the cut can depend on what
 *   follows it;
 * - it holds the text's first letter, if there is one, so the paragraph's direction is the same.
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

  private fun laidOut(width: Int): TextLayoutResult =
    element.textMeasurer.measure(
      text = element.text,
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
