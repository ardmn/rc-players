package ee.schimke.composeai.rcplayer.runtime

import ee.schimke.composeai.rcplayer.protocol.RcDataMapEntry
import ee.schimke.composeai.rcplayer.protocol.RcDataMapLookup
import ee.schimke.composeai.rcplayer.protocol.RcDocument
import ee.schimke.composeai.rcplayer.protocol.RcHeader
import ee.schimke.composeai.rcplayer.protocol.RcIdMap
import ee.schimke.composeai.rcplayer.protocol.RcLongConstant
import ee.schimke.composeai.rcplayer.protocol.RcNamedVariable
import ee.schimke.composeai.rcplayer.protocol.RcTextData
import ee.schimke.composeai.rcplayer.protocol.RcTimeAttribute
import ee.schimke.composeai.rcplayer.protocol.RcTimeAttributeType
import ee.schimke.composeai.rcplayer.protocol.RcVersion
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Clearing a host long, against the document's `LongConstant`s (`documentLongIds`): a long the
 * document gives a constant clears to it, one it does not clears to nothing, and the readers of a
 * long — a `fromArgument` time attribute, a long data-map entry — still evaluate once it is gone.
 * AndroidX throws reading a long with no `LongConstant` there (`TimeAttribute.paint`,
 * `DataMapLookup.apply` cast a null); the native Swift player leaves the attribute unset and reads
 * the lookup as 0, and so does this one (`NativeSwiftNamedValueClearTests`).
 */
class RcNamedValueLongClearTest {
  private val attribute =
    RcTimeAttribute(24, 1, RcTimeAttributeType.FromArgumentSeconds, listOf(13))
  private val lookup = RcDataMapLookup(30, 20, 21)

  private fun document(withConstant: Boolean) =
    RcDocument(
      RcHeader(RcVersion(1, 0, 0)),
      listOfNotNull(
        RcLongConstant(1, 1_700_000_000_000L),
        if (withConstant) RcLongConstant(13, 1_699_999_000_000L) else null,
        RcNamedVariable(13, RcNamedVariable.LONG_TYPE, "USER:start"),
        RcTextData(21, "k"),
        RcIdMap(20, listOf(RcDataMapEntry("k", RcIdMap.TYPE_LONG, 13))),
        attribute,
        lookup,
      ),
    )

  @Test
  fun aLongWithAConstantClearsToTheConstantAndTheSeededHostValueIsNotRecorded() {
    val state =
      RcPlayerState(document(true), namedValues = mapOf("start" to RcNamedValue.LongValue(5L)))
    assertEquals(5L, state.long(13))
    state.clearNamedValue("start")
    assertEquals(1_699_999_000_000L, state.long(13))
  }

  @Test
  fun aLongWithNoConstantSeededByTheHostClearsToNothing() {
    val state =
      RcPlayerState(document(false), namedValues = mapOf("start" to RcNamedValue.LongValue(5L)))
    assertEquals(5L, state.long(13))
    state.clearNamedValue("start")
    assertNull(state.long(13))
  }

  @Test
  fun aLaterDocumentWithAConstantDoesNotChangeAnEarlierStatesClear() {
    val first = RcPlayerState(document(false))
    val second = RcPlayerState(document(true))
    first.setNamedValue("start", RcNamedValue.LongValue(5L))
    second.setNamedValue("start", RcNamedValue.LongValue(5L))
    first.clearNamedValue("start")
    second.clearNamedValue("start")
    assertNull(first.long(13))
    assertEquals(1_699_999_000_000L, second.long(13))
  }

  /** A host long read as a `fromArgument` time attribute's argument, then cleared. */
  @Test
  fun aClearedArgumentLongWithNoConstantStillEvaluates() {
    val state =
      RcPlayerState(
        document(false),
        namedValues = mapOf("start" to RcNamedValue.LongValue(1_699_999_990_000L)),
      )
    state.applyTimeAttribute(attribute)
    assertEquals(10f, state.float(24))
    state.clearNamedValue("start")
    state.applyTimeAttribute(attribute)
    // Nothing to measure from: the slot is not written again, as the Swift player leaves it unset.
    assertEquals(10f, state.float(24))
  }

  /** A host long read through a long data-map entry, then cleared. */
  @Test
  fun aClearedDataMapLongWithNoConstantStillEvaluates() {
    val state =
      RcPlayerState(document(false), namedValues = mapOf("start" to RcNamedValue.LongValue(7L)))
    state.applyDataOperation(lookup)
    assertEquals(7, state.integer(30))
    state.clearNamedValue("start")
    state.applyDataOperation(lookup)
    assertEquals(0, state.integer(30))
  }
}
