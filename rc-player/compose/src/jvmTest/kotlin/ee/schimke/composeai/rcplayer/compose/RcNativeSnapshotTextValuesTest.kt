package ee.schimke.composeai.rcplayer.compose

import ee.schimke.composeai.rcplayer.protocol.RcBoxLayout
import ee.schimke.composeai.rcplayer.protocol.RcCoreText
import ee.schimke.composeai.rcplayer.protocol.RcDocument
import ee.schimke.composeai.rcplayer.protocol.RcDocumentCodec
import ee.schimke.composeai.rcplayer.protocol.RcFloatExpression
import ee.schimke.composeai.rcplayer.protocol.RcFloatWord
import ee.schimke.composeai.rcplayer.protocol.RcHeader
import ee.schimke.composeai.rcplayer.protocol.RcLayoutContent
import ee.schimke.composeai.rcplayer.protocol.RcNoArg
import ee.schimke.composeai.rcplayer.protocol.RcOpcodes
import ee.schimke.composeai.rcplayer.protocol.RcOperation
import ee.schimke.composeai.rcplayer.protocol.RcRootLayout
import ee.schimke.composeai.rcplayer.protocol.RcTextData
import ee.schimke.composeai.rcplayer.protocol.RcTextLayout
import ee.schimke.composeai.rcplayer.protocol.RcTextStyleProperty
import ee.schimke.composeai.rcplayer.protocol.RcVersion
import ee.schimke.composeai.rcplayer.runtime.RcFloatExpressionEvaluator
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * The native snapshot's text takes a computed font size and weight as the Compose player does: a
 * NaN weight is the normal 400, a NaN or negative size Android's default 12 px, and an infinite one
 * [RC_MAX_TEXT_SIZE_PX].
 */
class RcNativeSnapshotTextValuesTest {
  @Test
  fun aComputedNaNOrInfiniteSizeAndWeightAreNormalised() {
    val cases =
      listOf(
        Triple(NAN, NAN, 12f to 400f),
        Triple(INFINITY, literal(-5f), RC_MAX_TEXT_SIZE_PX to 1f),
        Triple(literal(-5f), INFINITY, 12f to 1000f),
        Triple(literal(20f), literal(700f), 20f to 700f),
      )
    for ((size, weight, expected) in cases) {
      for ((kind, text) in
        listOf("TextLayout" to textLayout(size, weight), "CoreText" to coreText(size, weight))) {
        val command = textCommand(text)
        assertEquals(
          expected,
          command.textSize to command.textWeight,
          "$kind with size ${size.bits.toString(16)}, weight ${weight.bits.toString(16)}",
        )
      }
    }
  }

  private fun textCommand(text: RcOperation): RcNativeDrawCommand {
    val document =
      RcDocument(
        RcHeader(RcVersion(1, 0, 0), legacyWidth = 100, legacyHeight = 60, modern = false),
        listOf(
          RcFloatExpression(NAN_ID, listOf(literal(0f), literal(0f), DIVIDE), null),
          RcFloatExpression(INFINITY_ID, listOf(literal(1f), literal(0f), DIVIDE), null),
          RcTextData(TEXT_ID, "hello"),
          RcRootLayout(1),
          RcBoxLayout(3, 30, 1, 1),
          RcLayoutContent(4),
          text,
          RcLayoutContent(6),
        ) + List(5) { RcNoArg(RcOpcodes.CONTAINER_END) },
      )
    val snapshot = RcNativeSnapshotSession(RcDocumentCodec.encode(document)).snapshot()
    val pending = ArrayDeque(listOf(snapshot.root))
    while (pending.isNotEmpty()) {
      val node = pending.removeFirst()
      node.commands
        .firstOrNull { it.text != null }
        ?.let {
          return it
        }
      pending.addAll(node.children)
    }
    error("no text command")
  }

  private fun textLayout(size: RcFloatWord, weight: RcFloatWord) =
    RcTextLayout(
      componentId = 5,
      animationId = 50,
      textId = TEXT_ID,
      color = 0xff000000.toInt(),
      fontSize = size,
      fontStyle = 0,
      fontWeight = weight,
      fontFamilyId = -1,
      textAlignAndFlags = RcTextLayout.ALIGN_LEFT,
      overflow = RcTextLayout.OVERFLOW_CLIP,
      maxLines = Int.MAX_VALUE,
    )

  private fun coreText(size: RcFloatWord, weight: RcFloatWord) =
    RcCoreText(
      textId = TEXT_ID,
      properties =
        // Property ids: 1 component id, 5 font size, 7 font weight.
        listOf(
          RcTextStyleProperty.IntValue(1, 5),
          RcTextStyleProperty.FloatValue(5, size),
          RcTextStyleProperty.FloatValue(7, weight),
        ),
    )

  private companion object {
    const val NAN_ID = 200
    const val INFINITY_ID = 201
    const val TEXT_ID = 101
    val NAN = reference(NAN_ID)
    val INFINITY = reference(INFINITY_ID)
    /** AndroidX `DIV`. */
    val DIVIDE = RcFloatExpressionEvaluator.operatorWord(RcFloatExpressionEvaluator.OFFSET + 4)

    fun literal(value: Float) = RcFloatWord.literal(value)

    fun reference(id: Int) = RcFloatWord(0xff800000.toInt() or id)
  }
}
