package ee.schimke.composeai.rcplayer.runtime

import kotlin.math.floor

/**
 * Java's `Math.round(float)`, which AndroidX rounds with: the closest int, a half up, NaN 0, past
 * `Int` saturated (`Double.toInt`). The sum is exact in double; Kotlin/Native's `roundToInt` adds
 * 0.5f in float (stdlib math.kt:1337), which rounds 0.49999997f to 1.
 */
public fun Float.javaRoundToInt(): Int = floor(toDouble() + 0.5).toInt()
