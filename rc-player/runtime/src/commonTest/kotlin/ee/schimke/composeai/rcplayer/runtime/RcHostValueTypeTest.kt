package ee.schimke.composeai.rcplayer.runtime

import ee.schimke.composeai.rcplayer.protocol.RcNamedVariable
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class RcHostValueTypeTest {
  @Test
  fun everyNameBelongsToOneType() {
    val names =
      listOf(
        "string",
        "text",
        "float",
        "dp",
        "color",
        "image",
        "int",
        "bool",
        "long",
        "float[]",
        "float_array",
      )
    for (name in names) {
      assertEquals(1, RcHostValueType.entries.count { it.hasName(name) }, name)
    }
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
  fun everyWireTypeReadsBackAsItsNonBooleanType() {
    val expected =
      mapOf(
        RcNamedVariable.STRING_TYPE to RcHostValueType.STRING,
        RcNamedVariable.FLOAT_TYPE to RcHostValueType.FLOAT,
        RcNamedVariable.COLOR_TYPE to RcHostValueType.COLOR,
        RcNamedVariable.IMAGE_TYPE to RcHostValueType.IMAGE,
        RcNamedVariable.INT_TYPE to RcHostValueType.INT,
        RcNamedVariable.LONG_TYPE to RcHostValueType.LONG,
        RcNamedVariable.FLOAT_ARRAY_TYPE to RcHostValueType.FLOAT_ARRAY,
      )
    for ((wire, type) in expected) assertEquals(type, RcHostValueType.ofWire(wire), "wire $wire")
    assertNull(RcHostValueType.ofWire(99))
  }

  @Test
  fun onlyImageCannotBeSuppliedByAHost() {
    assertEquals(
      listOf(RcHostValueType.IMAGE),
      RcHostValueType.entries.filterNot { it.hostSuppliable },
    )
    assertEquals("string", RcHostValueType.STRING.canonicalName)
    assertEquals("float[]", RcHostValueType.FLOAT_ARRAY.canonicalName)
  }
}
