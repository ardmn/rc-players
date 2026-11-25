package ee.schimke.composeai.rcplayer.wasm

import ee.schimke.composeai.rcplayer.protocol.RcDocument
import ee.schimke.composeai.rcplayer.protocol.RcHeader
import ee.schimke.composeai.rcplayer.protocol.RcNamedVariable
import ee.schimke.composeai.rcplayer.protocol.RcVersion
import ee.schimke.composeai.rcplayer.runtime.RcNamedValue
import ee.schimke.composeai.rcplayer.runtime.RcPlayerState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class RcHostParametersTest {
  @Test
  fun densityAcceptsPositiveDecimals() {
    assertEquals(2.625f, parseDensityParameter("2.625"))
    assertEquals(2f, parseDensityParameter("2"))
    assertEquals(0.5f, parseDensityParameter(".5"))
    assertEquals(1f, parseDensityParameter(" 1 "))
    assertEquals(15f, parseDensityParameter("1.5e1"))
    assertEquals(MAX_DENSITY_PARAMETER, parseDensityParameter("64"))
  }

  @Test
  fun densityRejectsEverythingElse() {
    listOf(
        null,
        "",
        " ",
        "0",
        "0.0",
        "-2",
        "+2",
        "NaN",
        "Infinity",
        "2.6f",
        "0x1p1",
        "2,625",
        "2.625dp",
        "1e999",
      )
      .forEach { raw -> assertNull(parseDensityParameter(raw), "density=$raw") }
  }

  @Test
  fun absentDensityKeepsThePlatformDensity() {
    assertEquals(1f, hostDensity(platformDensity = 1f, requested = null))
    assertEquals(2f, hostDensity(platformDensity = 2f, requested = null))
  }

  @Test
  fun requestedDensityIsMeasuredInCssPixels() {
    // A 454 px capture at density 2.625 is 172.95 dp wide. Shown in a 454 CSS px box, each dp must
    // span 2.625 CSS px: 2.625 device px at devicePixelRatio 1, 5.25 at devicePixelRatio 2.
    assertEquals(2.625f, hostDensity(platformDensity = 1f, requested = 2.625f))
    assertEquals(5.25f, hostDensity(platformDensity = 2f, requested = 2.625f))
  }

  @Test
  fun aDensityPastTheCeilingIsIgnored() {
    // Finite, but large enough that dp values times it overflow layout downstream.
    listOf("64.01", "1.5e3", "1e37", "3e38").forEach { raw ->
      assertNull(parseDensityParameter(raw), "density=$raw")
    }
  }

  @Test
  fun aDensityThatOverflowsWhenScaledFallsBackToThePlatformDensity() {
    // 3e38 parses as a finite float, but × devicePixelRatio 2 overflows to infinity.
    assertEquals(2f, hostDensity(platformDensity = 2f, requested = 3e38f))
  }

  private val bcp47 = Regex("[a-zA-Z]{2,8}(-[a-zA-Z0-9]{1,8})*")

  private fun isValid(tag: String) = bcp47.matches(tag)

  @Test
  fun validLanguageTagsPassThrough() {
    assertEquals(listOf("en-US", "de"), usableLanguageTags(listOf("en-US", "de"), ::isValid))
  }

  @Test
  fun posixDecorationsAreStripped() {
    assertEquals(
      listOf("en-US", "de-DE", "fr-FR"),
      usableLanguageTags(listOf("en-US@posix", "de_DE.UTF-8", "fr_FR.UTF-8@euro"), ::isValid),
    )
  }

  @Test
  fun fallsBackToThePrimarySubtag() {
    assertEquals(listOf("en"), usableLanguageTags(listOf("en-!!"), ::isValid))
  }

  @Test
  fun duplicatesCollapseInOrder() {
    assertEquals(
      listOf("en-US", "en"),
      usableLanguageTags(listOf("en-US", "en-US@posix", "en", "en_US"), ::isValid),
    )
  }

  @Test
  fun neverEmpty() {
    assertEquals(listOf(FALLBACK_LANGUAGE_TAG), usableLanguageTags(emptyList(), ::isValid))
    assertEquals(listOf(FALLBACK_LANGUAGE_TAG), usableLanguageTags(listOf("", "@", "1"), ::isValid))
  }

  @Test
  fun aBooleanIsTheBooleanValueTheIosControllerWrites() {
    assertEquals(RcNamedValue.BooleanValue(true), parseNamedValue("bool", "true"))
    assertEquals(RcNamedValue.BooleanValue(false), parseNamedValue("bool", "false"))
    // The documented embed contract: a boolean does not validate, anything but `true` is false.
    for (value in listOf("1", "TRUE", "yes", "")) {
      assertEquals(RcNamedValue.BooleanValue(false), parseNamedValue("bool", value), value)
    }
  }

  @Test
  fun aBooleanStillReachesTheDocumentAsTheInteger1Or0() {
    val document =
      RcDocument(
        RcHeader(RcVersion(1, 0, 0)),
        listOf(RcNamedVariable(50, RcNamedVariable.INT_TYPE, "USER:enabled")),
      )
    fun applied(value: String): Int? {
      val namedValue = parseNamedValue("bool", value)!!
      return RcPlayerState(document, namedValues = mapOf("USER:enabled" to namedValue)).integer(50)
    }
    assertEquals(1, applied("true"))
    assertEquals(0, applied("false"))
  }

  @Test
  fun everyOtherKindParsesAsBefore() {
    assertEquals(RcNamedValue.Text("Ready"), parseNamedValue("string", "Ready"))
    assertEquals(RcNamedValue.FloatValue(0.75f), parseNamedValue("float", "0.75"))
    assertEquals(RcNamedValue.FloatValue(12f), parseNamedValue("dp", "12"))
    assertEquals(RcNamedValue.Integer(7), parseNamedValue("int", "7"))
    assertEquals(RcNamedValue.Color(0xFFFF8800.toInt()), parseNamedValue("color", "#FFFF8800"))
    assertEquals(
      RcNamedValue.LongValue(1_700_000_000_000),
      parseNamedValue("long", "1700000000000"),
    )
    assertNull(parseNamedValue("int", "seven"))
    assertNull(parseNamedValue("color", "orange"))
    assertNull(parseNamedValue("long", "soon"))
    assertNull(parseNamedValue("unknown", "1"))
  }
}
