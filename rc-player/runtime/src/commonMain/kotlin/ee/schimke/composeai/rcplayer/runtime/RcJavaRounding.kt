package ee.schimke.composeai.rcplayer.runtime

import kotlin.math.roundToInt

/**
 * Java's `Math.round(float)`, which AndroidX's players round with: NaN — a host's value, or an
 * expression that divides zero by zero — is 0, where `roundToInt` throws; the infinities and values
 * past `Int`'s range saturate, and a half rounds up, as in both. The one rounding every player path
 * that may see a host's float uses.
 */
public fun Float.javaRoundToInt(): Int = if (isNaN()) 0 else roundToInt()
