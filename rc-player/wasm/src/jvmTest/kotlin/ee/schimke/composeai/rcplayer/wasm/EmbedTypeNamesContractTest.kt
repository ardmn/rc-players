package ee.schimke.composeai.rcplayer.wasm

import ee.schimke.composeai.rcplayer.runtime.RcHostValueType
import ee.schimke.composeai.rcplayer.runtime.RcNamedValue
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/** JVM-only: it reads the embed contract from the repository, which a browser test cannot. */
class EmbedTypeNamesContractTest {
  @Test
  fun theTypeNamesAreTheOnesTheEmbedContractLists() {
    // The contract's `namedValues` row: "Kinds: `string`, `float`, ... ." Drift either way fails.
    val doc = File("../../docs/design/RC_PLAYER_EMBED.md").readText()
    val listed =
      Regex("""Kinds: ((?:`[a-z_\[\]]+`(?:, )?)+)\.""").find(doc)?.groupValues?.get(1)
        ?: error("no 'Kinds:' list in RC_PLAYER_EMBED.md")
    val documented = Regex("`([a-z_\\[\\]]+)`").findAll(listed).map { it.groupValues[1] }.toList()
    assertEquals(documented, EMBED_TYPE_NAMES)
    // Every accepted name means a type the shared host vocabulary knows.
    for (name in EMBED_TYPE_NAMES) assertNotNull(RcHostValueType.ofName(name), name)
  }

  @Test
  fun otherHostsNamesAreNotPartOfTheEmbedContract() {
    // The shared vocabulary knows these, but the embed contract does not list them.
    for (name in listOf("text", "float_array", "float[]", "image")) {
      assertNull(parseNamedValue(name, "1"), name)
    }
  }

  @Test
  fun everyEmbedKindProducesAValue() {
    // A kind in the contract that parses to nothing would be accepted by the list and silently
    // dropped, so each must give a value for a well-formed input.
    val samples =
      mapOf(
        "string" to "a",
        "float" to "1.5",
        "dp" to "2",
        "int" to "3",
        "bool" to "true",
        "color" to "#FFFF8800",
        "long" to "4",
      )
    assertEquals(EMBED_TYPE_NAMES.toSet(), samples.keys)
    for ((kind, value) in samples) assertNotNull(parseNamedValue(kind, value), kind)
  }

  @Test
  fun numbersAreReadTheSameInEveryLocale() {
    // The value comes from JSON via JavaScript's String(), which always writes a '.', and the
    // parser is locale-independent; a comma decimal is malformed and dropped, never misread.
    val saved = java.util.Locale.getDefault()
    try {
      for (locale in
        listOf(java.util.Locale.GERMANY, java.util.Locale("ru", "RU"), java.util.Locale.US)) {
        java.util.Locale.setDefault(locale)
        assertEquals(RcNamedValue.FloatValue(1.5f), parseNamedValue("float", "1.5"), "$locale")
        assertNull(parseNamedValue("float", "1,5"), "$locale")
      }
    } finally {
      java.util.Locale.setDefault(saved)
    }
  }
}
