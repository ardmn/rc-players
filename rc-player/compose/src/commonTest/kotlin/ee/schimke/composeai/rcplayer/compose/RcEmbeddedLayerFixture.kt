package ee.schimke.composeai.rcplayer.compose

import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.Composable
import androidx.compose.runtime.RememberObserver
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import ee.schimke.composeai.rcplayer.protocol.RcBackgroundModifier
import ee.schimke.composeai.rcplayer.protocol.RcBoxLayout
import ee.schimke.composeai.rcplayer.protocol.RcCustomLayout
import ee.schimke.composeai.rcplayer.protocol.RcDimensionType
import ee.schimke.composeai.rcplayer.protocol.RcDocLayout
import ee.schimke.composeai.rcplayer.protocol.RcDocument
import ee.schimke.composeai.rcplayer.protocol.RcDocumentCodec
import ee.schimke.composeai.rcplayer.protocol.RcFloatWord
import ee.schimke.composeai.rcplayer.protocol.RcGraphicsLayerAttribute
import ee.schimke.composeai.rcplayer.protocol.RcGraphicsLayerModifier
import ee.schimke.composeai.rcplayer.protocol.RcHeader
import ee.schimke.composeai.rcplayer.protocol.RcHeightModifier
import ee.schimke.composeai.rcplayer.protocol.RcLayoutContent
import ee.schimke.composeai.rcplayer.protocol.RcNoArg
import ee.schimke.composeai.rcplayer.protocol.RcOffsetModifier
import ee.schimke.composeai.rcplayer.protocol.RcOpcodes
import ee.schimke.composeai.rcplayer.protocol.RcOperation
import ee.schimke.composeai.rcplayer.protocol.RcRootLayout
import ee.schimke.composeai.rcplayer.protocol.RcTextData
import ee.schimke.composeai.rcplayer.protocol.RcVersion
import ee.schimke.composeai.rcplayer.protocol.RcWidthModifier

/**
 * The documents and probes the embedded `ModulateAlpha` layer tests share: the Skiko one
 * (`RcEmbeddedModulateAlphaLayerTest`, jvmTest) and its Android parity guard
 * (`RcAndroidEmbeddedModulateAlphaLayerTest`, androidHostTest).
 */
internal object RcEmbeddedLayerFixture {
  /** The host document: a [PROBE_WIDTH] custom component beside an [EMBEDDED_WIDTH] document. */
  const val WIDTH = 60
  const val HEIGHT = 20
  /** Each embedded document's width, and the slot the host gives it. */
  const val EMBEDDED_WIDTH = 40
  /** The host's custom component, and each child box an embedded document stacks. */
  const val PROBE_WIDTH = WIDTH - EMBEDDED_WIDTH
  const val MODULATE_ALPHA = RcGraphicsLayerModifier.COMPOSITING_STRATEGY_MODULATE_ALPHA
  const val AUTO = RcGraphicsLayerModifier.COMPOSITING_STRATEGY_AUTO
  const val OFFSCREEN = RcGraphicsLayerModifier.COMPOSITING_STRATEGY_OFFSCREEN
  const val URL_OWN = "doc://own"
  const val URL_NESTED = "doc://nested"
  const val HOST_PROBE = "hostProbe"
  const val EMBEDDED_PROBE = "embeddedProbe"
  const val OWN_PROBE = "ownProbe"

  val end = RcNoArg(RcOpcodes.CONTAINER_END)

  fun literal(value: Float) = RcFloatWord.literal(value)

  fun size(width: Int, height: Int) =
    listOf(
      RcWidthModifier(RcDimensionType.EXACT, literal(width.toFloat())),
      RcHeightModifier(RcDimensionType.EXACT, literal(height.toFloat())),
    )

  fun background(red: Float, blue: Float) =
    RcBackgroundModifier(
      flags = 0,
      colorId = 0,
      reserved1 = 0,
      reserved2 = 0,
      red = literal(red),
      green = literal(0f),
      blue = literal(blue),
      alpha = literal(1f),
      shapeType = RcBackgroundModifier.SHAPE_RECTANGLE,
    )

  fun layer(strategy: Int, alpha: Float = 0.5f, blur: Float = 0f) =
    RcGraphicsLayerModifier(
      buildList {
        add(RcGraphicsLayerAttribute.FloatValue(RcGraphicsLayerModifier.ALPHA, literal(alpha)))
        add(
          RcGraphicsLayerAttribute.IntValue(RcGraphicsLayerModifier.COMPOSITING_STRATEGY, strategy),
        )
        if (blur > 0f) {
          add(
            RcGraphicsLayerAttribute.FloatValue(
              RcGraphicsLayerModifier.BLUR_RADIUS_X,
              literal(blur),
            ),
          )
          add(
            RcGraphicsLayerAttribute.FloatValue(
              RcGraphicsLayerModifier.BLUR_RADIUS_Y,
              literal(blur),
            ),
          )
        }
      },
    )

  fun header(width: Int) =
    RcHeader(RcVersion(1, 1, 0), legacyWidth = width, legacyHeight = HEIGHT, modern = false)

  /**
   * A [WIDTH]x[HEIGHT] box (with a graphics layer of [strategy] unless null) stacking a
   * [PROBE_WIDTH] custom component ([HOST_PROBE]) and an [EMBEDDED_WIDTH] embedded document
   * ([url]).
   */
  fun host(
    strategy: Int?,
    alpha: Float = 0.5f,
    blur: Float = 0f,
    url: String = URL_NESTED,
  ): RcDocument =
    RcDocument(
      header(WIDTH),
      buildList<RcOperation> {
        add(RcTextData(50, HOST_PROBE))
        add(RcTextData(51, url))
        add(RcRootLayout(1))
        add(RcLayoutContent(2))
        add(RcBoxLayout(3, 30, 1, 1))
        if (strategy != null) add(layer(strategy, alpha, blur))
        addAll(size(WIDTH, HEIGHT))
        add(RcLayoutContent(4))
        add(RcCustomLayout(10, 0, 50, emptyList()))
        addAll(size(PROBE_WIDTH, HEIGHT))
        add(end)
        add(RcDocLayout(20, -1, 51))
        addAll(size(EMBEDDED_WIDTH, HEIGHT))
        add(end)
        repeat(4) { add(end) }
      },
    )

  /**
   * A [PROBE_WIDTH] box moved by [offsetX] unless null, with [background] unless null, holding the
   * custom component named by [probeTextId] unless null.
   */
  fun MutableList<RcOperation>.child(
    id: Int,
    offsetX: Float?,
    probeTextId: Int?,
    background: RcBackgroundModifier? = null,
  ) {
    add(RcBoxLayout(id, 30 + id, 1, 1))
    if (offsetX != null) add(RcOffsetModifier(literal(offsetX), literal(0f)))
    addAll(size(PROBE_WIDTH, HEIGHT))
    if (background != null) add(background)
    add(RcLayoutContent(id + 1))
    if (probeTextId != null) {
      add(RcCustomLayout(id + 2, 0, probeTextId, emptyList()))
      addAll(size(PROBE_WIDTH, HEIGHT))
      add(end)
    }
    add(end)
    add(end)
  }

  fun encode(width: Int, operations: List<RcOperation>) =
    RcDocumentCodec.encode(RcDocument(header(width), operations))

  /** What a custom component saw, and how often its remembered state was created and forgotten. */
  class Probe {
    var layer: RcModulateAlphaLayer? = null
    var remembers = 0
    var forgets = 0
    val present
      get() = remembers - forgets
  }

  private class Remembered(private val probe: Probe) : RememberObserver {
    override fun onRemembered() {
      probe.remembers++
    }

    override fun onForgotten() {
      probe.forgets++
    }

    override fun onAbandoned() = Unit
  }

  /** A custom component named [name] that records into [probe]. */
  fun probeEntry(
    name: String,
    probe: Probe,
  ): Pair<String, @Composable (RcCustomComponent, Modifier) -> Unit> =
    name to
      { _, modifier ->
        probe.layer = LocalRcModulateAlphaLayer.current
        remember { Remembered(probe) }
        Box(modifier)
      }
}
