import Foundation

/// `Int(Float)` traps on NaN, infinity and anything beyond `Int`'s range, and a document is free to
/// compute any of those. NaN maps to 0 and everything else saturates, so a malformed value degrades
/// one frame's output instead of crashing the host.
func nativeSwiftClampedInt(_ value: Float) -> Int {
  guard !value.isNaN else { return 0 }
  if value >= Float(Int.max) { return Int.max }
  if value <= Float(Int.min) { return Int.min }
  return Int(value)
}

/// The integer view of a float: truncated toward zero and clamped to 32 bits, NaN as 0 — Kotlin's
/// `Float.toInt()`, which `RcPlayerState.storeFloat` publishes beside every float.
func nativeSwiftIntegerView(_ value: Float) -> Int {
  Int(Int32(clamping: nativeSwiftClampedInt(value)))
}

/// `value` with NaN as 0 and each infinity as the largest finite float of its sign: how Java's
/// `(int)` cast and `Math.round` read a float AndroidX's players convert, so a host's NaN or
/// infinity reaches a layout field as a number rather than failing the frame.
func nativeSwiftSaturated(_ value: Float) -> Float {
  if value.isNaN { return 0 }
  return min(max(value, -.greatestFiniteMagnitude), .greatestFiniteMagnitude)
}
