package ee.schimke.composeai.rcwidget

import ee.schimke.composeai.rcplayer.protocol.RcNamedVariable
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RcBindingTypeTest {
  @Test
  fun eachWireNameIsANameOfItsHostType() {
    for (type in RcBindingType.entries) {
      assertTrue(type.hostType.hasName(type.wireName), type.wireName)
    }
  }

  @Test
  fun theContractSpellingsAndWireTypesAreUnchanged() {
    val expected =
      listOf(
        Triple(RcBindingType.TEXT, "text", RcNamedVariable.STRING_TYPE),
        Triple(RcBindingType.FLOAT, "float", RcNamedVariable.FLOAT_TYPE),
        Triple(RcBindingType.COLOR, "color", RcNamedVariable.COLOR_TYPE),
        Triple(RcBindingType.IMAGE, "image", RcNamedVariable.IMAGE_TYPE),
        Triple(RcBindingType.INT, "int", RcNamedVariable.INT_TYPE),
        Triple(RcBindingType.LONG, "long", RcNamedVariable.LONG_TYPE),
        Triple(RcBindingType.FLOAT_ARRAY, "float[]", RcNamedVariable.FLOAT_ARRAY_TYPE),
      )
    assertEquals(expected.map { it.first }, RcBindingType.entries)
    for ((type, name, wire) in expected) {
      assertEquals(name, type.wireName)
      assertEquals(wire, type.wireType, name)
      assertEquals(type, RcBindingType.ofWireName(name))
      assertEquals(type, RcBindingType.ofWire(wire))
    }
  }

  @Test
  fun otherHostsSpellingsAreNotPartOfTheWidgetContract() {
    for (name in listOf("string", "bool", "dp", "float_array", "unknown")) {
      assertNull(RcBindingType.ofWireName(name), name)
    }
  }
}
