package ee.schimke.composeai.rcplayer.wasm

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals

/** JVM-only: it reads the embed contract from the repository, which a browser test cannot. */
class RcNamedValueTypeContractTest {
  @Test
  fun theTypeNamesAreTheOnesTheEmbedContractLists() {
    // The contract's `namedValues` row: "Kinds: `string`, `float`, ... ." Drift either way fails.
    val doc = File("../../docs/design/RC_PLAYER_EMBED.md").readText()
    val listed =
      Regex("""Kinds: ((?:`[a-z]+`(?:, )?)+)\.""").find(doc)?.groupValues?.get(1)
        ?: error("no 'Kinds:' list in RC_PLAYER_EMBED.md")
    val documented = Regex("`([a-z]+)`").findAll(listed).map { it.groupValues[1] }.toList()
    assertEquals(documented, RcNamedValueType.entries.map { it.typeName })
  }
}
