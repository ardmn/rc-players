package ee.schimke.composeai.rcplayer.compose

import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.unit.Density
import ee.schimke.composeai.rcplayer.protocol.RcDocument
import ee.schimke.composeai.rcplayer.protocol.RcDocumentCodec
import ee.schimke.composeai.rcplayer.protocol.RcNamedVariable
import ee.schimke.composeai.rcplayer.runtime.RcNamedValue
import kotlin.test.Test
import kotlin.test.assertTrue
import org.jetbrains.skia.Bitmap

/**
 * A megabyte host string of one word, which AndroidX's `setNamedStringOverride` takes, renders each
 * document's first frames in [MAX_RENDER_MILLIS], in one string variable or in all of them.
 */
class RcLongHostStringRenderTest {
  @Test(timeout = 300_000)
  fun aMegabyteHostStringRendersEveryDocumentInTime() {
    val failures = mutableListOf<String>()
    for (fixture in FIXTURES) {
      val document = RcDocumentCodec.decode(fixtureBytes(fixture))
      val names =
        document.operations
          .filterIsInstance<RcNamedVariable>()
          .filter { it.type == RcNamedVariable.STRING_TYPE }
          .map { it.name }
      assertTrue(names.isNotEmpty(), "$fixture has no host string")
      val runs =
        listOf("every string" to names) +
          if (names.size > 1) names.map { it to listOf(it) } else emptyList()
      for ((label, written) in runs) {
        val start = System.nanoTime()
        val error = runCatching {
          render(document, written.associateWith { RcNamedValue.Text(LONG) })
        }
        val millis = (System.nanoTime() - start) / 1_000_000
        error.exceptionOrNull()?.let { failures += "$fixture, $label: $it" }
        if (millis > MAX_RENDER_MILLIS) failures += "$fixture, $label: $millis ms"
      }
    }
    assertTrue(failures.isEmpty(), failures.joinToString("\n"))
  }

  private fun fixtureBytes(name: String): ByteArray =
    checkNotNull(javaClass.getResourceAsStream("/rc-fixtures/$name")) { "missing fixture $name" }
      .use { it.readBytes() }

  private fun render(document: RcDocument, values: Map<String, RcNamedValue>) {
    val namedValues = mutableStateMapOf<String, RcNamedValue>().apply { putAll(values) }
    val scene =
      ImageComposeScene(width = SIZE, height = SIZE, density = Density(1f)) {
        RcComposePlayer(document, namedValues = namedValues)
      }
    try {
      val bitmap = Bitmap().apply { allocN32Pixels(SIZE, SIZE) }
      for (frame in 0 until FRAMES) scene.render(frame * FRAME_NANOS)
      check(scene.render(FRAMES * FRAME_NANOS).readPixels(bitmap))
    } finally {
      scene.close()
    }
  }

  private companion object {
    /** Corpus documents that show host strings in a `CoreText`. */
    val FIXTURES =
      listOf(
        "host-string-banner.rc",
        "host-string-quantity-stepper.rc",
        "host-string-button-namedlabel.rc",
      )
    val LONG = "x".repeat(1 shl 20)
    const val SIZE = 200
    const val FRAMES = 3
    const val FRAME_NANOS = 16_000_000L

    /** The frames of one run, composition included. */
    const val MAX_RENDER_MILLIS = 2_000L
  }
}
