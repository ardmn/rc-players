package ee.schimke.composeai.rcplayer.runtime

import kotlin.math.roundToInt

/**
 * Java's `Math.round(float)`, which AndroidX rounds with: NaN (a host's value, or 0/0) is 0 where
 * `roundToInt` throws; out-of-range values saturate and a half rounds up, as in both.
 */
public fun Float.javaRoundToInt(): Int = if (isNaN()) 0 else roundToInt()
