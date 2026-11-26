package ee.schimke.composeai.rcplayer.compose

import androidx.activity.ComponentActivity
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.unit.Density
import ee.schimke.composeai.rcplayer.compose.RcEmbeddedLayerFixture.AUTO
import ee.schimke.composeai.rcplayer.compose.RcEmbeddedLayerFixture.EMBEDDED_PROBE
import ee.schimke.composeai.rcplayer.compose.RcEmbeddedLayerFixture.EMBEDDED_WIDTH
import ee.schimke.composeai.rcplayer.compose.RcEmbeddedLayerFixture.HEIGHT
import ee.schimke.composeai.rcplayer.compose.RcEmbeddedLayerFixture.HOST_PROBE
import ee.schimke.composeai.rcplayer.compose.RcEmbeddedLayerFixture.MODULATE_ALPHA
import ee.schimke.composeai.rcplayer.compose.RcEmbeddedLayerFixture.OFFSCREEN
import ee.schimke.composeai.rcplayer.compose.RcEmbeddedLayerFixture.OWN_PROBE
import ee.schimke.composeai.rcplayer.compose.RcEmbeddedLayerFixture.Probe
import ee.schimke.composeai.rcplayer.compose.RcEmbeddedLayerFixture.URL_NESTED
import ee.schimke.composeai.rcplayer.compose.RcEmbeddedLayerFixture.URL_OWN
import ee.schimke.composeai.rcplayer.compose.RcEmbeddedLayerFixture.child
import ee.schimke.composeai.rcplayer.compose.RcEmbeddedLayerFixture.encode
import ee.schimke.composeai.rcplayer.compose.RcEmbeddedLayerFixture.end
import ee.schimke.composeai.rcplayer.compose.RcEmbeddedLayerFixture.host
import ee.schimke.composeai.rcplayer.compose.RcEmbeddedLayerFixture.layer
import ee.schimke.composeai.rcplayer.compose.RcEmbeddedLayerFixture.probeEntry
import ee.schimke.composeai.rcplayer.compose.RcEmbeddedLayerFixture.size
import ee.schimke.composeai.rcplayer.protocol.RcBoxLayout
import ee.schimke.composeai.rcplayer.protocol.RcDocLayout
import ee.schimke.composeai.rcplayer.protocol.RcLayoutContent
import ee.schimke.composeai.rcplayer.protocol.RcRootLayout
import ee.schimke.composeai.rcplayer.protocol.RcTextData
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Android's side of `RcEmbeddedModulateAlphaLayerTest`. AndroidX's child layers get a
 * `ModulateAlpha` parent's alpha, so the player never makes a `ModulateAlpha` layer holder here
 * (`rcChildLayersMissModulatedAlpha` is false) and every offset keeps its layer. This is a parity
 * guard, not a test of the embedded document's starting layer, which only matters on Skiko: it
 * passes with or without that. It pins that no holder ever appears, at any embedding level, and that
 * every subtree is kept through host strategy, alpha and blur changes.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34], qualifiers = "w1000dp-h1000dp")
class RcAndroidEmbeddedModulateAlphaLayerTest {

  @get:Rule val composeRule = createAndroidComposeRule<ComponentActivity>()

  @Test
  fun hostLayerChangesProvideNoLayerAndKeepEverySubtree() {
    val host = Probe()
    val embedded = Probe()
    val embeddedOwn = Probe()
    val registry =
      RcCustomComponentRegistry(
        probeEntry(HOST_PROBE, host),
        probeEntry(EMBEDDED_PROBE, embedded),
        probeEntry(OWN_PROBE, embeddedOwn),
      )
    val documents = mapOf(URL_OWN to ownLayerEmbedded(), URL_NESTED to nestedEmbedded())
    val embeddedDocuments = RcEmbeddedDocuments(maxDepth = 3, resolver = { documents[it] })
    var document by mutableStateOf(host(strategy = MODULATE_ALPHA))
    composeRule.mainClock.autoAdvance = false
    composeRule.setContent {
      CompositionLocalProvider(
        LocalRcEmbeddedDocuments provides embeddedDocuments,
        LocalDensity provides Density(1f),
      ) {
        RcComposePlayer(document, customComponents = registry)
      }
    }
    composeRule.mainClock.advanceTimeByFrame()
    composeRule.waitForIdle()
    val steps =
      listOf<Triple<Int?, Float, Float>>(
        Triple(MODULATE_ALPHA, 0.5f, 0f),
        Triple(AUTO, 0.5f, 0f),
        Triple(OFFSCREEN, 0.5f, 0f),
        Triple(null, 0.5f, 0f),
        Triple(MODULATE_ALPHA, 1f, 0f),
        Triple(MODULATE_ALPHA, 0.5f, 4f),
        Triple(MODULATE_ALPHA, 0.5f, 0f),
      )
    for ((index, step) in steps.withIndex()) {
      val (strategy, alpha, blur) = step
      if (index > 0) {
        composeRule.runOnIdle { document = host(strategy, alpha, blur) }
        composeRule.mainClock.advanceTimeByFrame()
        composeRule.waitForIdle()
      }
      val name = "strategy $strategy, alpha $alpha, blur $blur"
      for ((probeName, probe) in
        listOf("host" to host, "embedded" to embedded, "embedded own" to embeddedOwn)) {
        assertNull("$name: $probeName sees no layer holder", probe.layer)
        assertEquals("$name: $probeName created once", 1, probe.remembers)
        assertEquals("$name: $probeName never disposed", 0, probe.forgets)
      }
    }
  }

  private companion object {
    /** A 40x20 document with a half-alpha `ModulateAlpha` layer and an offset [OWN_PROBE]. */
    fun ownLayerEmbedded(): ByteArray =
      encode(
        EMBEDDED_WIDTH,
        buildList {
          add(RcTextData(50, OWN_PROBE))
          add(RcRootLayout(1))
          add(RcLayoutContent(2))
          add(RcBoxLayout(3, 30, 1, 1))
          add(layer(MODULATE_ALPHA))
          addAll(size(EMBEDDED_WIDTH, HEIGHT))
          add(RcLayoutContent(4))
          child(20, offsetX = 20f, probeTextId = 50)
          repeat(4) { add(end) }
        },
      )

    /** A 40x20 document embedding [URL_OWN], and an offset [EMBEDDED_PROBE]. */
    fun nestedEmbedded(): ByteArray =
      encode(
        EMBEDDED_WIDTH,
        buildList {
          add(RcTextData(50, EMBEDDED_PROBE))
          add(RcTextData(51, URL_OWN))
          add(RcRootLayout(1))
          add(RcLayoutContent(2))
          add(RcBoxLayout(3, 30, 1, 1))
          addAll(size(EMBEDDED_WIDTH, HEIGHT))
          add(RcLayoutContent(4))
          add(RcDocLayout(40, -1, 51))
          addAll(size(EMBEDDED_WIDTH, HEIGHT))
          add(end)
          child(20, offsetX = 20f, probeTextId = 50)
          repeat(4) { add(end) }
        },
      )
  }
}
