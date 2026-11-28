package ee.schimke.composeai.rcplayer.runtime

import ee.schimke.composeai.rcplayer.protocol.RcLoopOperation

/**
 * The loop operations each of a document's [loops] used when a painted drawing last ran it, for
 * [RcPlayerState.forEachLoopValue].
 *
 * Only a loop run inside a painted drawing ([inPass]) records; one run outside any (an action, an
 * unpainted INVISIBLE drawing) reads the budget and records nothing, as AndroidX counts only what
 * paints.
 *
 * Costs, for L document loops and P drawings: [ordinal] O(1) amortised when equal loops are asked
 * for in document order (a cursor per key; O(k) for k equal loops otherwise), [usedBefore] and
 * [record] O(log L) (a Fenwick tree of the counts), a drawing O(P + the loops it ran last time).
 */
internal class RcLoopBudget(private val loops: List<RcLoopOperation>) {
  /** A top-level drawing and the ordinals of the loops it recorded. */
  private class Pass(val owner: Any) {
    var ordinals = mutableListOf<Int>()

    /** Counts this drawing removed or lowered in its current run: later loops may draw more. */
    var freed = false
  }

  /** Equal loops (a data class) share a key; [ordinal] tells them apart by identity. */
  private val ordinalsByLoop: Map<RcLoopOperation, List<Int>> = loops.indices.groupBy { loops[it] }

  /** Per key, the position in its [ordinalsByLoop] list of the loop asked for last. */
  private val lastFound = mutableMapOf<RcLoopOperation, Int>()

  private val used = IntArray(loops.size)

  /** Fenwick tree over [used]: node i holds the sum of a range ending at ordinal i - 1. */
  private val prefixTree = IntArray(loops.size + 1)

  /** The drawing that recorded each loop's count. */
  private val recordedBy = arrayOfNulls<Pass>(loops.size)

  private val passes = mutableListOf<Pass>()
  private var currentPass: Pass? = null

  /** [operation]'s index in document order, or -1 for a loop the document does not hold. */
  fun ordinal(operation: RcLoopOperation): Int {
    val candidates = ordinalsByLoop[operation] ?: return -1
    val start = lastFound[operation] ?: 0
    for (step in candidates.indices) {
      val position = (start + step) % candidates.size
      if (loops[candidates[position]] === operation) {
        // The next equal loop is likely the one asked for next.
        lastFound[operation] = (position + 1) % candidates.size
        return candidates[position]
      }
    }
    return -1
  }

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

  /** Records [operations] for [ordinal] under the current painted drawing; none outside one. */
  fun record(ordinal: Int, operations: Int) {
    val pass = currentPass ?: return
    if (recordedBy[ordinal] != null && operations < used[ordinal]) pass.freed = true
    set(ordinal, operations)
    recordedBy[ordinal] = pass
    pass.ordinals.add(ordinal)
  }

  /**
   * Runs [block] as one painted drawing of [owner]. Its previous counts stand while it draws, so a
   * loop it draws first (a child inside `DrawContent`) sees what it sees when redrawn alone; at the
   * end, the counts it did not record again are released, and [onFreed] runs if budget was freed.
   */
  fun <T> inPass(owner: Any, onFreed: () -> Unit, block: () -> T): T {
    val pass = passes.firstOrNull { it.owner === owner } ?: Pass(owner).also(passes::add)
    val previous = pass.ordinals
    pass.ordinals = mutableListOf()
    pass.freed = false
    val enclosing = currentPass
    currentPass = pass
    try {
      return block()
    } finally {
      currentPass = enclosing
      val recordedAgain = pass.ordinals.toHashSet()
      for (ordinal in previous) {
        if (ordinal !in recordedAgain && recordedBy[ordinal] === pass && used[ordinal] != 0) {
          set(ordinal, 0)
          pass.freed = true
        }
      }
      if (pass.freed) onFreed()
    }
  }

  /**
   * Runs [block] with no drawing recording, after releasing [owner]'s ([onFreed] if that freed).
   */
  fun <T> unpainted(owner: Any, onFreed: () -> Unit, block: () -> T): T {
    if (release(owner)) onFreed()
    val enclosing = currentPass
    currentPass = null
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
    var freed = false
    for (ordinal in pass.ordinals) {
      if (recordedBy[ordinal] === pass && used[ordinal] != 0) {
        set(ordinal, 0)
        freed = true
      }
    }
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
