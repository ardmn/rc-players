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

  @Test
  fun eachValueFitsExactlyItsOwnWireType() {
    val values =
      listOf(
        RcNamedValue.Text("a") to RcNamedVariable.STRING_TYPE,
        RcNamedValue.FloatValue(1f) to RcNamedVariable.FLOAT_TYPE,
        RcNamedValue.Color(0) to RcNamedVariable.COLOR_TYPE,
        RcNamedValue.Integer(1) to RcNamedVariable.INT_TYPE,
        RcNamedValue.LongValue(1) to RcNamedVariable.LONG_TYPE,
        // AndroidX keeps a boolean as an integer 1 or 0.
        RcNamedValue.BooleanValue(true) to RcNamedVariable.INT_TYPE,
        RcNamedValue.FloatArrayValue(listOf(1f)) to RcNamedVariable.FLOAT_ARRAY_TYPE,
      )
    val wireTypes = RcHostValueType.entries.map { it.wireType }.distinct()
    for ((value, wireType) in values) {
      for (other in wireTypes) {
        assertEquals(other == wireType, value.fitsWireType(other), "$value in $other")
      }
    }
  }

  @Test
  fun aWireTypeReadsBackAsTheNonBooleanType() {
    assertEquals(RcHostValueType.INT, RcHostValueType.ofWire(RcNamedVariable.INT_TYPE))
    assertEquals(RcHostValueType.STRING, RcHostValueType.ofWire(RcNamedVariable.STRING_TYPE))
    assertNull(RcHostValueType.ofWire(99))
  }
}
