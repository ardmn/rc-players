package ee.schimke.composeai.rcplayer.compose

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.SkikoComposeUiTest
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.runSkikoComposeUiTest
import androidx.compose.ui.test.swipeWithVelocity
import androidx.compose.ui.unit.Density
import ee.schimke.composeai.rcplayer.protocol.RcDocumentCodec
import ee.schimke.composeai.rcplayer.runtime.RcPlayerState
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.float
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * The reference side of a differential test: the Kotlin player's readouts of a scroll's offset,
 * maximum offset and content length, in points, kept in the JSON the native Swift tests also read.
 * The documents come from `renders/swift-creation/ScrollMetrics.swift.txt` at display scale 2.
 */
@OptIn(ExperimentalTestApi::class)
class RcScrollMetricsReferenceTest {
  private val expected: JsonObject =
    Json.parseToJsonElement(File(EXPECTED_PATH).readText()).jsonObject

  @Test
  fun aPagedScrollAtRestPublishesNoOffsetAndTheFullRange() =
    runDocument(PAGED_PATH) { assertReadouts(PAGED, REST) }

  @Test
  fun aListAtRestPublishesNoOffsetAndTheFullRange() =
    runDocument(LIST_PATH) { assertReadouts(LIST, REST) }

  /**
   * A scroll frame that moves the offset leaves the range alone, so it must not re-evaluate the
   * whole document: the player recomposes (and reports its state) only when a published extent
   * changes.
   */
  @Test
  fun scrollingWithoutChangingTheRangeDoesNotInvalidateTheDocument() {
    var stateReports = 0
    runDocument(LIST_PATH, onStateChanged = { stateReports += 1 }) {
      val beforeScroll = stateReports
      dragList(distance = LIST_DRAG_PX)
      assertEquals(beforeScroll, stateReports, "state reports while scrolling a list")
      assertReadouts(LIST, REST, ignoring = OFFSET)
    }
  }

  private fun runDocument(
    path: String,
    onStateChanged: ((RcPlayerState) -> Unit)? = null,
    block: SkikoComposeUiTest.() -> Unit,
  ) {
    val bytes = File(path).readBytes()
    val header = RcDocumentCodec.decode(bytes).header
    runSkikoComposeUiTest(
      size = Size(header.width.toFloat(), header.height.toFloat()),
      density = Density(1f),
    ) {
      setContent {
        // The public player's own path, with the state callback only the internal one takes.
        RcComposePlayerResolved(
          prepared = remember { RcPreparedDocument(RcDocumentCodec.decode(bytes)) },
          modifier = Modifier.fillMaxSize(),
          theme = RcPlayerTheme.System.resolve(),
          namedValues = rememberRcNamedValues(),
          onEvent = {},
          typefaces = RcTypefaceLoader.Default,
          systemColors = { null },
          customComponents = RcCustomComponentRegistry.Empty,
          onStateChanged = onStateChanged,
        )
      }
      waitForIdle()
      block()
    }
  }

  /** Scrolls the list [distance] px towards its end from inside it, releasing at rest. */
  private fun SkikoComposeUiTest.dragList(distance: Float) {
    onRoot().performTouchInput {
      val travel = distance + viewConfiguration.touchSlop
      swipeWithVelocity(
        start = Offset(LIST_DRAG_X, LIST_DRAG_START_Y),
        end = Offset(LIST_DRAG_X, LIST_DRAG_START_Y - travel),
        endVelocity = 0f,
        durationMillis = DRAG_MILLIS,
      )
    }
    waitForIdle()
  }

  /** The three readouts the document shows, each read from its text's semantics. */
  private fun SkikoComposeUiTest.readouts(): Map<String, Float> {
    val texts =
      onAllNodes(SemanticsMatcher.keyIsDefined(SemanticsProperties.Text), useUnmergedTree = true)
        .fetchSemanticsNodes()
        .flatMap { node -> node.config.getOrNull(SemanticsProperties.Text).orEmpty() }
        .map { it.text }
    return READOUTS.associateWith { name ->
      val prefix = "$name "
      val shown = texts.filter { it.startsWith(prefix) }
      assertEquals(1, shown.size, "readout '$name' among $texts")
      shown.single().removePrefix(prefix).toFloat()
    }
  }

  private fun SkikoComposeUiTest.assertReadouts(
    document: String,
    state: String,
    ignoring: String? = null,
  ) {
    val want = expected.getValue(document).jsonObject.getValue(state).jsonObject
    val compared = READOUTS - setOfNotNull(ignoring)
    assertEquals(
      compared.associateWith { want.getValue(it).jsonPrimitive.float },
      readouts().filterKeys { it in compared },
      "$document / $state",
    )
  }

  private companion object {
    // jvmTest runs in rc-player/compose, two levels below the repository root.
    const val REPO_ROOT = "../.."
    // The Swift tests' own fixtures, so both players read the same bytes.
    const val FIXTURES = "$REPO_ROOT/Tests/RcNativePlayerUIKitTests/Fixtures"
    const val PAGED_PATH = "$FIXTURES/scroll-metrics-paged.rc"
    const val LIST_PATH = "$FIXTURES/scroll-metrics-list.rc"
    const val EXPECTED_PATH = "$FIXTURES/scroll-metrics.expected.json"

    // Keys of the shared expected file.
    const val PAGED = "paged"
    const val LIST = "list"
    const val REST = "rest"
    const val OFFSET = "offset"

    /** The readout names, as each text's prefix and as the expected file's keys. */
    val READOUTS = listOf(OFFSET, "maximumOffset", "contentLength")

    /** The list scrolls below its readouts; the drag runs up its middle, within its travel. */
    const val LIST_DRAG_X = 200f
    const val LIST_DRAG_START_Y = 420f
    const val LIST_DRAG_PX = 200f
    const val DRAG_MILLIS = 200L
  }
}
