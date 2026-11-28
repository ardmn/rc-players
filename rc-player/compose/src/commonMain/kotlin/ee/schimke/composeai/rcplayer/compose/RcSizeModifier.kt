package ee.schimke.composeai.rcplayer.compose

import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.IntrinsicMeasurable
import androidx.compose.ui.layout.IntrinsicMeasureScope
import androidx.compose.ui.layout.Measurable
import androidx.compose.ui.layout.MeasureResult
import androidx.compose.ui.layout.MeasureScope
import androidx.compose.ui.node.LayoutModifierNode
import androidx.compose.ui.node.ModifierNodeElement
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.isSpecified

/**
 * Compose's `width`, `height`, `widthIn`, `heightIn` and their `required` forms, for any size a
 * host may write.
 *
 * Compose's `SizeNode` (foundation-layout `Size.kt`) builds a `Constraints` before constraining it
 * and throws "Can't represent a width" past 262,142 px, where AndroidX takes an exact size up to
 * the space it has (LegacyMeasurePolicy.java:45). This is `SizeNode` with every `Constraints` built
 * by [rcConstraints].
 */
internal fun Modifier.rcSize(
  minWidth: Dp = Dp.Unspecified,
  maxWidth: Dp = Dp.Unspecified,
  minHeight: Dp = Dp.Unspecified,
  maxHeight: Dp = Dp.Unspecified,
  enforceIncoming: Boolean = true,
): Modifier = this.then(RcSizeElement(minWidth, maxWidth, minHeight, maxHeight, enforceIncoming))

internal fun Modifier.rcWidth(width: Dp): Modifier = rcSize(minWidth = width, maxWidth = width)

internal fun Modifier.rcHeight(height: Dp): Modifier =
  rcSize(minHeight = height, maxHeight = height)

/**
 * `Constraints` as near the bounds as Compose can hold, the width first: one axis keeps up to
 * 262,142 px and the other what is left. Bounds it can hold come back as they are.
 */
internal fun rcConstraints(minWidth: Int, maxWidth: Int, minHeight: Int, maxHeight: Int) =
  Constraints.fitPrioritizingWidth(minWidth, maxWidth, minHeight, maxHeight)

private data class RcSizeElement(
  val minWidth: Dp,
  val maxWidth: Dp,
  val minHeight: Dp,
  val maxHeight: Dp,
  val enforceIncoming: Boolean,
) : ModifierNodeElement<RcSizeNode>() {
  override fun create() = RcSizeNode(this)

  override fun update(node: RcSizeNode) {
    node.element = this
  }
}

/**
 * A size's bounds in pixels, [Constraints.Infinity] for none: `SizeNode.targetConstraints`. A min
 * too large for an Int (from 2^31 px, +inf) is 0 here and [fillsWidth] / [fillsHeight]: it takes
 * the space there is, as AndroidX's min(maxWidth, size) does (LegacyMeasurePolicy.java:45).
 */
private class RcSizeBounds(
  val minWidth: Int,
  val maxWidth: Int,
  val minHeight: Int,
  val maxHeight: Int,
  val fillsWidth: Boolean,
  val fillsHeight: Boolean,
) {
  val hasFixedWidth: Boolean
    get() = !fillsWidth && minWidth == maxWidth

  val hasFixedHeight: Boolean
    get() = !fillsHeight && minHeight == maxHeight

  /** The min to measure with: the incoming max for a filling one, while that is bounded. */
  fun measureMinWidth(incoming: Constraints): Int =
    if (fillsWidth) fillPixels(incoming.maxWidth, maxWidth) else minWidth

  fun measureMinHeight(incoming: Constraints): Int =
    if (fillsHeight) fillPixels(incoming.maxHeight, maxHeight) else minHeight

  fun constrainWidth(width: Int) = width.coerceIn(minWidth, maxWidth)

  fun constrainHeight(height: Int) = height.coerceIn(minHeight, maxHeight)
}

/** The largest size a `Constraints` holds on one axis, which keeps intrinsics clear of overflow. */
private val LARGEST_CONSTRAINT_PIXELS =
  rcConstraints(Constraints.Infinity - 1, Constraints.Infinity - 1, 0, 0).maxWidth

/**
 * A filling min: the incoming [incomingMax] within the size's own [max]; in unbounded space (a
 * scroll) the largest a `Constraints` holds, as large as it can be and still finite.
 */
private fun fillPixels(incomingMax: Int, max: Int): Int =
  minOf(incomingMax, max).takeIf { it != Constraints.Infinity } ?: LARGEST_CONSTRAINT_PIXELS

private class RcSizeNode(var element: RcSizeElement) : Modifier.Node(), LayoutModifierNode {
  private val Density.bounds: RcSizeBounds
    get() {
      // `roundToPx` reads -inf as Constraints.Infinity too; a negative size is none.
      fun Dp.pixels(): Int? =
        when {
          !isSpecified -> null
          value < 0f -> 0
          else -> roundToPx()
        }
      val maxWidth = element.maxWidth.pixels() ?: Constraints.Infinity
      val maxHeight = element.maxHeight.pixels() ?: Constraints.Infinity
      // Compose's SizeNode drops an unbounded min; here it fills (RcSizeBounds).
      val minWidth = element.minWidth.pixels()?.coerceIn(0, maxWidth) ?: 0
      val minHeight = element.minHeight.pixels()?.coerceIn(0, maxHeight) ?: 0
      val fillsWidth = minWidth == Constraints.Infinity
      val fillsHeight = minHeight == Constraints.Infinity
      return RcSizeBounds(
        minWidth = if (fillsWidth) 0 else minWidth,
        maxWidth = maxWidth,
        minHeight = if (fillsHeight) 0 else minHeight,
        maxHeight = maxHeight,
        fillsWidth = fillsWidth,
        fillsHeight = fillsHeight,
      )
    }

  override fun MeasureScope.measure(
    measurable: Measurable,
    constraints: Constraints,
  ): MeasureResult {
    val target = bounds
    val minWidth = target.measureMinWidth(constraints)
    val minHeight = target.measureMinHeight(constraints)
    val child =
      if (element.enforceIncoming) {
        // `Constraints.constrain`: the size, within the incoming bounds.
        rcConstraints(
          minWidth.coerceIn(constraints.minWidth, constraints.maxWidth),
          target.maxWidth.coerceIn(constraints.minWidth, constraints.maxWidth),
          minHeight.coerceIn(constraints.minHeight, constraints.maxHeight),
          target.maxHeight.coerceIn(constraints.minHeight, constraints.maxHeight),
        )
      } else {
        fun ownIfSpecified(dp: Dp, own: Int, incoming: Int) = if (dp.isSpecified) own else incoming
        rcConstraints(
          ownIfSpecified(
            element.minWidth,
            minWidth,
            constraints.minWidth.coerceAtMost(target.maxWidth),
          ),
          ownIfSpecified(
            element.maxWidth,
            target.maxWidth,
            constraints.maxWidth.coerceAtLeast(target.minWidth),
          ),
          ownIfSpecified(
            element.minHeight,
            minHeight,
            constraints.minHeight.coerceAtMost(target.maxHeight),
          ),
          ownIfSpecified(
            element.maxHeight,
            target.maxHeight,
            constraints.maxHeight.coerceAtLeast(target.minHeight),
          ),
        )
      }
    val placeable = measurable.measure(child)
    return layout(placeable.width, placeable.height) { placeable.placeRelative(0, 0) }
  }

  /** A fixed size as an intrinsic one: no more than a `Constraints` holds. */
  private fun fixed(size: Int): Int = rcConstraints(size, size, 0, 0).maxWidth

  override fun IntrinsicMeasureScope.minIntrinsicWidth(
    measurable: IntrinsicMeasurable,
    height: Int,
  ): Int {
    val target = bounds
    if (target.hasFixedWidth) return fixed(target.maxWidth)
    val childHeight = if (element.enforceIncoming) height else target.constrainHeight(height)
    return target.constrainWidth(measurable.minIntrinsicWidth(childHeight))
  }

  override fun IntrinsicMeasureScope.maxIntrinsicWidth(
    measurable: IntrinsicMeasurable,
    height: Int,
  ): Int {
    val target = bounds
    if (target.hasFixedWidth) return fixed(target.maxWidth)
    val childHeight = if (element.enforceIncoming) height else target.constrainHeight(height)
    return target.constrainWidth(measurable.maxIntrinsicWidth(childHeight))
  }

  override fun IntrinsicMeasureScope.minIntrinsicHeight(
    measurable: IntrinsicMeasurable,
    width: Int,
  ): Int {
    val target = bounds
    if (target.hasFixedHeight) return fixed(target.maxHeight)
    val childWidth = if (element.enforceIncoming) width else target.constrainWidth(width)
    return target.constrainHeight(measurable.minIntrinsicHeight(childWidth))
  }

  override fun IntrinsicMeasureScope.maxIntrinsicHeight(
    measurable: IntrinsicMeasurable,
    width: Int,
  ): Int {
    val target = bounds
    if (target.hasFixedHeight) return fixed(target.maxHeight)
    val childWidth = if (element.enforceIncoming) width else target.constrainWidth(width)
    return target.constrainHeight(measurable.maxIntrinsicHeight(childWidth))
  }
}
