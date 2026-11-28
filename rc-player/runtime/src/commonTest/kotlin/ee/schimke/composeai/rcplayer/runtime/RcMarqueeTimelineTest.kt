@file:Suppress("DEPRECATION")

package ee.schimke.composeai.rcplayer.runtime

import kotlin.test.Test
import kotlin.test.assertEquals

class RcMarqueeTimelineTest {
  @Test
  fun holdsForTwiceTheInitialDelay() {
    assertEquals(0f, androidXMarqueeOffset(100f, 1f, 100f, 500f, .999f))
    assertEquals(0f, androidXMarqueeOffset(100f, 1f, 100f, 500f, 1f))
  }

  @Test
  fun takesItsPhaseFromFirstPaintPlusOneDelay() {
    // One-second cycle, started at 0.5 s: 1.25 s is a quarter in, 1.5 s is back at rest, 2 s is
    // the far end. Phasing from the end of the hold instead would put 1.5 s at the far end.
    assertEquals(-50f, androidXMarqueeOffset(100f, 1f, 100f, 500f, 1.25f), .001f)
    assertEquals(0f, androidXMarqueeOffset(100f, 1f, 100f, 500f, 1.5f), .001f)
    assertEquals(-100f, androidXMarqueeOffset(100f, 1f, 100f, 500f, 2f), .001f)
  }

  @Test
  fun matchesTheConformanceTickerAtItsCapturedFrames() {
    // modifier_marquee_ticker: 240 px of overflow at 60 px/s with a 500 ms delay, first painted at
    // 9 s and sampled from 10 s.
    fun at(seconds: Float) = androidXMarqueeOffset(240f, 1f, 60f, 500f, seconds - 9f)
    assertEquals(-120f, at(10.5f), .01f)
    assertEquals(-204.85f, at(11f), .01f)
    assertEquals(-240f, at(11.5f), .01f)
    assertEquals(-35.15f, at(14f), .01f)
  }

  @Test
  fun aNegativeVelocitySweepsAsItsMagnitude() {
    // MarqueeModifierOperation.java:180-184: a negative duration flips the phase's sign, and the
    // cosine is even, so AndroidX scrolls the same way at -v as at v.
    for (seconds in listOf(1.25f, 1.6f, 2f, 7.3f)) {
      assertEquals(
        androidXMarqueeOffset(100f, 1f, 100f, 500f, seconds),
        androidXMarqueeOffset(100f, 1f, -100f, 500f, seconds),
        .001f,
      )
    }
    assertEquals(-50f, androidXMarqueeOffset(100f, 1f, -100f, 500f, 1.25f), .001f)
  }

  @Test
  fun aVelocityThatGivesNoFiniteDurationStandsStill() {
    for (velocity in listOf(Float.NaN, 0f, Float.NEGATIVE_INFINITY, Float.POSITIVE_INFINITY)) {
      assertEquals(0f, androidXMarqueeOffset(100f, 1f, velocity, 500f, 1.25f), "$velocity")
    }
  }
}
