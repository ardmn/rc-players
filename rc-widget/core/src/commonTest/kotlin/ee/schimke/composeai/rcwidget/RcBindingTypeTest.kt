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
      assertTrue(type.wireName in type.hostType.names, "${type.wireName} in ${type.hostType.names}")
    }
  }

  @Test
  fun wireTypesAndNamesAreUnchanged() {
    // The published contract: these spellings and wire types are what templates already use.
    assertEquals(
      listOf("text", "float", "color", "image", "int", "long", "float[]"),
      RcBindingType.entries.map { it.wireName },
    )
    assertEquals(RcNamedVariable.STRING_TYPE, RcBindingType.TEXT.wireType)
    assertEquals(RcNamedVariable.FLOAT_ARRAY_TYPE, RcBindingType.FLOAT_ARRAY.wireType)
    assertEquals(RcBindingType.TEXT, RcBindingType.ofWireName("text"))
    assertEquals(RcBindingType.LONG, RcBindingType.ofWire(RcNamedVariable.LONG_TYPE))
  }

  @Test
  fun otherHostSpellingsOfTheSameTypeAreAccepted() {
    assertEquals(RcBindingType.TEXT, RcBindingType.ofWireName("string"))
    assertEquals(RcBindingType.FLOAT_ARRAY, RcBindingType.ofWireName("float_array"))
    assertEquals(RcBindingType.FLOAT, RcBindingType.ofWireName("dp"))
    // A boolean has no binding type of its own: it is stored, and declared, as an int.
    assertEquals(RcBindingType.INT, RcBindingType.ofWireName("bool"))
    // By name and by wire type always agree.
    for (host in ee.schimke.composeai.rcplayer.runtime.RcHostValueType.entries) {
      for (name in host.names) {
        assertEquals(RcBindingType.ofWire(host.wireType), RcBindingType.ofWireName(name), name)
      }
    }
    assertNull(RcBindingType.ofWireName("unknown"))
  }
}
