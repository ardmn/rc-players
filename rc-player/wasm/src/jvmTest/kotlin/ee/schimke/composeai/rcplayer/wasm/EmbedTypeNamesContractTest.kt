package ee.schimke.composeai.rcplayer.wasm

import ee.schimke.composeai.rcplayer.runtime.RcHostValueType
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
}
