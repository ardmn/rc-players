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

/** A size's bounds in pixels, [Constraints.Infinity] for none: `SizeNode.targetConstraints`. */
private class RcSizeBounds(
  val minWidth: Int,
  val maxWidth: Int,
  val minHeight: Int,
  val maxHeight: Int,
) {
  val hasFixedWidth: Boolean
    get() = minWidth == maxWidth

  val hasFixedHeight: Boolean
    get() = minHeight == maxHeight

  fun constrainWidth(width: Int) = width.coerceIn(minWidth, maxWidth)

  fun constrainHeight(height: Int) = height.coerceIn(minHeight, maxHeight)
}

private class RcSizeNode(var element: RcSizeElement) : Modifier.Node(), LayoutModifierNode {
  private val Density.bounds: RcSizeBounds
    get() {
      fun Dp.pixels(): Int? = if (isSpecified) roundToPx().coerceAtLeast(0) else null
      val maxWidth = element.maxWidth.pixels() ?: Constraints.Infinity
      val maxHeight = element.maxHeight.pixels() ?: Constraints.Infinity
      fun minPixels(min: Dp, max: Int): Int =
        min.pixels()?.coerceIn(0, max)?.takeIf { it != Constraints.Infinity } ?: 0
      return RcSizeBounds(
        minPixels(element.minWidth, maxWidth),
        maxWidth,
        minPixels(element.minHeight, maxHeight),
        maxHeight,
      )
    }

  override fun MeasureScope.measure(
    measurable: Measurable,
    constraints: Constraints,
  ): MeasureResult {
    val target = bounds
    val child =
      if (element.enforceIncoming) {
        // `Constraints.constrain`: the size, within the incoming bounds.
        rcConstraints(
          target.minWidth.coerceIn(constraints.minWidth, constraints.maxWidth),
          target.maxWidth.coerceIn(constraints.minWidth, constraints.maxWidth),
          target.minHeight.coerceIn(constraints.minHeight, constraints.maxHeight),
          target.maxHeight.coerceIn(constraints.minHeight, constraints.maxHeight),
        )
      } else {
        fun ownIfSpecified(dp: Dp, own: Int, incoming: Int) = if (dp.isSpecified) own else incoming
        rcConstraints(
          ownIfSpecified(
            element.minWidth,
            target.minWidth,
            constraints.minWidth.coerceAtMost(target.maxWidth),
          ),
          ownIfSpecified(
            element.maxWidth,
            target.maxWidth,
            constraints.maxWidth.coerceAtLeast(target.minWidth),
          ),
          ownIfSpecified(
            element.minHeight,
            target.minHeight,
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
