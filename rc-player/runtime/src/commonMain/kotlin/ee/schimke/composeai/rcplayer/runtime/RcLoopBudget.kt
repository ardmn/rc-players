package ee.schimke.composeai.rcplayer.runtime

import ee.schimke.composeai.rcplayer.protocol.RcLoopOperation

/**
 * The loop operations each of a document's [loops] used when it last ran, and which top-level
 * drawing ran it, for [RcPlayerState.forEachLoopValue].
 *
 * Costs, for L document loops and P drawings: [ordinal] is a hash lookup, [usedBefore] and [record]
 * O(log L) (a Fenwick tree of the counts), a drawing's start O(P + the loops it ran last time).
 */
internal class RcLoopBudget(private val loops: List<RcLoopOperation>) {
  /** A top-level drawing and the ordinals of the loops it recorded. */
  private class Pass(val owner: Any) {
    val ordinals = mutableListOf<Int>()
  }

  /** Equal loops (a data class) share a key; [ordinal] tells them apart by identity. */
  private val ordinalsByLoop: Map<RcLoopOperation, List<Int>> = loops.indices.groupBy { loops[it] }

  private val used = IntArray(loops.size)

  /** Fenwick tree over [used]: node i holds the sum of a range ending at ordinal i - 1. */
  private val prefixTree = IntArray(loops.size + 1)

  /** The drawing that recorded each loop's count; null for one run outside any drawing. */
  private val recordedBy = arrayOfNulls<Pass>(loops.size)

  private val passes = mutableListOf<Pass>()
  private var currentPass: Pass? = null

  /** [operation]'s index in document order, or -1 for a loop the document does not hold. */
  fun ordinal(operation: RcLoopOperation): Int =
    ordinalsByLoop[operation]?.firstOrNull { loops[it] === operation } ?: -1

  /** What the loops before [ordinal] in document order used; 0 for a loop outside the document. */
  fun usedBefore(ordinal: Int): Int {
    var sum = 0
    var node = ordinal
    while (node > 0) {
      sum += prefixTree[node]
      node -= node and -node
    }
    return sum
  }

  fun record(ordinal: Int, operations: Int) {
    set(ordinal, operations)
    recordedBy[ordinal] = currentPass
    currentPass?.ordinals?.add(ordinal)
  }

  fun <T> inPass(owner: Any, block: () -> T): T {
    val pass = passes.firstOrNull { it.owner === owner } ?: Pass(owner).also(passes::add)
    clear(pass)
    val enclosing = currentPass
    currentPass = pass
    try {
      return block()
    } finally {
      currentPass = enclosing
    }
  }

  /** Whether releasing [owner] freed any budget, which later loops can now draw with. */
  fun release(owner: Any): Boolean {
    val pass = passes.firstOrNull { it.owner === owner } ?: return false
    passes.remove(pass)
    return clear(pass)
  }

  /** Zeroes the counts [pass] recorded and still holds; whether any was not zero. */
  private fun clear(pass: Pass): Boolean {
    var freed = false
    for (ordinal in pass.ordinals) {
      if (recordedBy[ordinal] === pass && used[ordinal] != 0) {
        set(ordinal, 0)
        freed = true
      }
    }
    pass.ordinals.clear()
    return freed
  }

  private fun set(ordinal: Int, operations: Int) {
    val delta = operations - used[ordinal]
    used[ordinal] = operations
    var node = ordinal + 1
    while (node <= loops.size) {
      prefixTree[node] += delta
      node += node and -node
    }
  }
}
