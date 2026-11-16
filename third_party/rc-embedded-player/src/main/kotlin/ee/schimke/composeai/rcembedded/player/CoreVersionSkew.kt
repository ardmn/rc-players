/*
 * Copyright 2026 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// VERSION SKEW (rc-players): this file has no upstream counterpart. It stands in for a
// `remote-core` member the player is compiled against but that a `remote-core` on the consumer's
// runtime classpath may not have:
//
// - `ImageAttribute.getImageId()`, which androidx-main added in d18fe8f34fb and alpha23 ships, is
//   absent from other `remote-core` builds that resolve beside this artifact — the androidx.dev
//   `1.0.0-SNAPSHOT` a snapshot-lane consumer pins (build 16639771) among them. Called
//   unconditionally, it threw `NoSuchMethodError` the first time a document's draw stream reached
// an
//   `ImageAttribute`, which aborted the whole draw: an image-background button or card baked to a
//   fully transparent frame, its label included. `RcPlayerDrawing.kt` and `GraphContext.kt` read
//   the id through [imageIdCompat] instead of the member.
//
// Delete this file, and restore `op.imageId` at both call sites, once no supported consumer runs
// this player against a `remote-core` without the getter. See PROVENANCE.md.

package ee.schimke.composeai.rcembedded.player

import androidx.compose.remote.core.WireBuffer
import androidx.compose.remote.core.operations.ImageAttribute
import java.util.Collections
import java.util.WeakHashMap

/**
 * `ImageAttribute.getImageId()`: the (possibly NaN-boxed) id of the image whose width or height the
 * operation publishes.
 *
 * Read through the member while the runtime `remote-core` has it. Where it does not, the id comes
 * from the operation's own wire form ([ImageAttributeImageId.fromWire]), which both lines write
 * identically — the same value the member returns, with no reflection on a private field.
 */
internal val ImageAttribute.imageIdCompat: Int
    get() {
        if (ImageAttributeImageId.getterAvailable) {
            try {
                return imageId
            } catch (_: NoSuchMethodError) {
                ImageAttributeImageId.getterAvailable = false
            }
        }
        return ImageAttributeImageId.fromWireCached(this)
    }

/** The fallback behind [imageIdCompat], separate so a test can drive it on a core that has both. */
internal object ImageAttributeImageId {
    /** Whether the runtime `remote-core` has `getImageId()`; cleared on the first miss. */
    @Volatile internal var getterAvailable: Boolean = true

    // An operation's image id never changes, and the draw stream asks for it on every pass, so the
    // decoded id is kept per operation rather than re-serialized each frame. Weak keys: the
    // operations belong to a document, which this must not keep alive.
    private val decoded: MutableMap<ImageAttribute, Int> =
        Collections.synchronizedMap(WeakHashMap())

    internal fun fromWireCached(op: ImageAttribute): Int =
        decoded[op] ?: fromWire(op).also { decoded[op] = it }

    /**
     * The image id from [op]'s wire form. `ImageAttribute.apply` writes the opcode byte, the output
     * id, then the image id, both as ints — the layout `ImageAttribute.read` decodes and every
     * document carries, so it cannot drift from the field the getter returns.
     */
    internal fun fromWire(op: ImageAttribute): Int {
        val buffer = WireBuffer(WIRE_BUFFER_BYTES)
        op.write(buffer)
        buffer.index = 0
        buffer.readByte() // opcode
        buffer.readInt() // output id
        return buffer.readInt()
    }

    // Opcode, two ints, the type and argument count as shorts: enough for an op without arguments.
    // The buffer grows for any that has them.
    private const val WIRE_BUFFER_BYTES = 32
}
