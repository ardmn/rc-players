package ee.schimke.composeai.rcplayer.compose

import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.runtime.snapshots.SnapshotStateObserver
import ee.schimke.composeai.rcplayer.protocol.RcFloatWord
import ee.schimke.composeai.rcplayer.protocol.RcGraphicsLayerAttribute
import ee.schimke.composeai.rcplayer.protocol.RcGraphicsLayerModifier
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * [RcModulateAlphaLayer]: when an offset drawn into a `ModulateAlpha` layer gives up its own layer,
 * which layer an offset is drawn into, and when its placement is invalidated. Pixels cannot tell
 * these apart where the offset's layer makes no visible difference (an alpha of 1, an offset before
 * a layer that is itself a child layer), so they are pinned here.
 */
class RcModulateAlphaLayerTest {

  @Test
  fun anUnboundLayerFadesNothing() {
    assertFalse(RcModulateAlphaLayer(modulateAlpha(), enclosing = null).childLayersMissAlpha)
  }

  /** At an alpha of 1 there is nothing to miss, so an offset keeps its layer. */
  @Test
  fun onlyAnAlphaBelowOneWithoutABlurIsMissed() {
    val layer = RcModulateAlphaLayer(modulateAlpha(), enclosing = null)
    layer.bind(alpha = { 1f }, blurX = { 0f }, blurY = { 0f })
    assertFalse(layer.childLayersMissAlpha, "alpha 1")
    layer.bind(alpha = { 0.5f }, blurX = { 0f }, blurY = { 0f })
    assertTrue(layer.childLayersMissAlpha, "alpha 0.5")
    layer.bind(alpha = { 0.999f }, blurX = { 0f }, blurY = { 0f })
    assertTrue(layer.childLayersMissAlpha, "alpha just below 1")
    layer.bind(alpha = { 0.5f }, blurX = { 1f }, blurY = { 0f })
    assertFalse(layer.childLayersMissAlpha, "blurred along x")
    layer.bind(alpha = { 0.5f }, blurX = { 0f }, blurY = { 1f })
    assertFalse(layer.childLayersMissAlpha, "blurred along y")
  }

  /**
   * `RenderLayoutNode` keeps a holder across a new document whose layer is equal to the last one's
   * (`remember` compares keys with `==`), so the component's chain has to find it by the same rule.
   */
  @Test
  fun anEqualButNewLayerFindsItsHolder() {
    val holder = RcModulateAlphaLayer(modulateAlpha(), enclosing = null)
    assertSame(holder, holder.ownedBy(modulateAlpha()))
    assertSame(holder, holder.drawnIntoOffset(modulateAlpha(), afterLayer = true))
  }

  @Test
  fun anOffsetIsDrawnIntoTheLayerItsPositionInTheChainPutsItIn() {
    val outer = RcModulateAlphaLayer(modulateAlpha(0.25f), enclosing = null)
    val own = RcModulateAlphaLayer(modulateAlpha(), enclosing = outer)
    // Before the component's own layer, an offset is drawn into the enclosing one, after it into
    // the component's own.
    assertSame(outer, own.drawnIntoOffset(modulateAlpha(), afterLayer = false))
    assertSame(own, own.drawnIntoOffset(modulateAlpha(), afterLayer = true))
    // A component of the outermost layer has nothing around it.
    assertNull(outer.drawnIntoOffset(modulateAlpha(0.25f), afterLayer = false))
    // A component without a layer of its own is drawn into the provided one.
    assertSame(own, own.drawnIntoOffset(layer = null, afterLayer = false))
    assertNull(own.ownedBy(null))
    assertNull(null.drawnIntoOffset(modulateAlpha(), afterLayer = true))
  }

  /**
   * A new reader (a new document's eased values) re-places the offsets that read the layer, even
   * one whose component skipped recomposition.
   */
  @Test
  fun bindingNewReadersInvalidatesThePlacementThatReadTheOldOnes() {
    val layer = RcModulateAlphaLayer(modulateAlpha(), enclosing = null)
    layer.bind(alpha = { 1f }, blurX = { 0f }, blurY = { 0f })
    val invalidations = observe { layer.childLayersMissAlpha }
    Snapshot.withMutableSnapshot { layer.bind(alpha = { 0.5f }, blurX = { 0f }, blurY = { 0f }) }
    Snapshot.sendApplyNotifications()
    assertEquals(1, invalidations(), "a new alpha reader re-places the offset")
    assertTrue(layer.childLayersMissAlpha)
  }

  /**
   * A clock-driven alpha changes every frame; the offsets under it are placed again only when the
   * decision flips, not on each frame.
   */
  @Test
  fun anAlphaThatMovesBelowOneDoesNotReplaceEachFrame() {
    val alpha = mutableFloatStateOf(0.5f)
    val layer = RcModulateAlphaLayer(modulateAlpha(), enclosing = null)
    layer.bind(alpha = { alpha.floatValue }, blurX = { 0f }, blurY = { 0f })
    val invalidations = observe { layer.childLayersMissAlpha }
    for (value in listOf(0.4f, 0.3f, 0.6f)) {
      Snapshot.withMutableSnapshot { alpha.floatValue = value }
      Snapshot.sendApplyNotifications()
    }
    assertEquals(0, invalidations(), "the decision held, so nothing is re-placed")
    Snapshot.withMutableSnapshot { alpha.floatValue = 1f }
    Snapshot.sendApplyNotifications()
    assertEquals(1, invalidations(), "the decision flipped")
  }

  /**
   * Reads [block] as placement does, through a [SnapshotStateObserver], and returns how many times
   * it has been invalidated since.
   */
  private fun observe(block: () -> Unit): () -> Int {
    var count = 0
    val observer = SnapshotStateObserver { it() }
    observer.start()
    val scope = Any()
    lateinit var onChanged: (Any) -> Unit
    onChanged = {
      count++
      observer.observeReads(scope, onChanged, block)
    }
    observer.observeReads(scope, onChanged, block)
    return { count }
  }

  private fun modulateAlpha(alpha: Float = 0.5f) =
    RcGraphicsLayerModifier(
      listOf(
        RcGraphicsLayerAttribute.FloatValue(
          RcGraphicsLayerModifier.ALPHA,
          RcFloatWord.literal(alpha),
        ),
        RcGraphicsLayerAttribute.IntValue(
          RcGraphicsLayerModifier.COMPOSITING_STRATEGY,
          RcGraphicsLayerModifier.COMPOSITING_STRATEGY_MODULATE_ALPHA,
        ),
      ),
    )
}
