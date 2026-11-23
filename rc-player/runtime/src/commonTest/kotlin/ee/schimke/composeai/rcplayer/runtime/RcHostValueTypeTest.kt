package ee.schimke.composeai.rcplayer.runtime

import ee.schimke.composeai.rcplayer.protocol.RcNamedVariable
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class RcHostValueTypeTest {
  @Test
  fun everyNameBelongsToOneType() {
    val names = RcHostValueType.entries.flatMap { it.names }
    assertEquals(names.distinct(), names)
  }

  @Test
  fun eachHostSpellingResolvesToTheSameWireType() {
    assertEquals(RcNamedVariable.STRING_TYPE, RcHostValueType.ofName("string")?.wireType)
    assertEquals(RcNamedVariable.STRING_TYPE, RcHostValueType.ofName("text")?.wireType)
    assertEquals(RcNamedVariable.FLOAT_TYPE, RcHostValueType.ofName("dp")?.wireType)
    assertEquals(RcNamedVariable.FLOAT_ARRAY_TYPE, RcHostValueType.ofName("float[]")?.wireType)
    assertEquals(RcNamedVariable.FLOAT_ARRAY_TYPE, RcHostValueType.ofName("float_array")?.wireType)
    // A boolean is stored as an integer, as AndroidX's setNamedBooleanOverride does.
    assertEquals(RcNamedVariable.INT_TYPE, RcHostValueType.ofName("bool")?.wireType)
    assertNull(RcHostValueType.ofName("boolean"))
    assertNull(RcHostValueType.ofName("String"))
  }
}
