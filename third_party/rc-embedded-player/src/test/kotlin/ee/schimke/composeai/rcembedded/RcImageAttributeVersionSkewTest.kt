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

package ee.schimke.composeai.rcembedded

import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View.MeasureSpec
import android.view.ViewGroup
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.remote.core.operations.ImageAttribute
import androidx.compose.remote.core.operations.Utils
import androidx.compose.remote.player.core.RemoteDocument
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.unit.Density
import ee.schimke.composeai.rcembedded.player.ExperimentalRemoteDocumentPlayer
import ee.schimke.composeai.rcembedded.player.ImageAttributeImageId
import ee.schimke.composeai.rcembedded.player.imageIdCompat
import ee.schimke.composeai.rcembedded.player.resources.RemoteImageSupport
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * An `ImageAttribute` must play on a `remote-core` without `ImageAttribute.getImageId()`.
 *
 * This player is compiled against alpha23, which has the getter, but a consumer can resolve another
 * `remote-core` beside it: remote-m3-catalog's snapshot lane runs it on androidx.dev build
 * 16639771, whose `ImageAttribute` keeps the id in a package-private field and has no accessor. The
 * call threw `NoSuchMethodError` from inside the draw stream the first time it reached the op,
 * which abandoned the whole frame — every image-background button and background-image card baked
 * fully transparent, labels and all, while the CMP player drew the same bytes.
 *
 * The suite runs on alpha23, where the getter exists, so the tests below drive the fallback the
 * skewed core takes ([ImageAttributeImageId.getterAvailable] cleared, as the first
 * `NoSuchMethodError` clears it) and check it against the getter. The fixture is the snapshot
 * writer's own `ImageBackgroundRemoteButton` capture, the document that baked blank.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34], qualifiers = "xhdpi")
class RcImageAttributeVersionSkewTest {

    @get:Rule val composeRule = createAndroidComposeRule<ComponentActivity>()

    @After
    fun restoreGetter() {
        ImageAttributeImageId.getterAvailable = true
    }

    @Test
    fun theWireFormReadsTheSameImageIdAsTheGetter() {
        val nanBoxed = Utils.asNan(52).toRawBits()
        for (op in
            listOf(
                ImageAttribute(53, 52, ImageAttribute.IMAGE_WIDTH, null),
                ImageAttribute(54, 52, ImageAttribute.IMAGE_HEIGHT, intArrayOf(7, 8, 9)),
                ImageAttribute(55, nanBoxed, ImageAttribute.IMAGE_WIDTH, null),
                ImageAttribute(56, -1, ImageAttribute.IMAGE_HEIGHT, intArrayOf()),
            )) {
            assertEquals(op.toString(), op.imageId, ImageAttributeImageId.fromWire(op))
        }
    }

    @Test
    fun withoutTheGetterTheIdStillResolves() {
        ImageAttributeImageId.getterAvailable = false
        val op = ImageAttribute(53, 52, ImageAttribute.IMAGE_WIDTH, null)
        assertEquals(52, op.imageIdCompat)
    }

    @Test
    fun anImageBackgroundButtonDrawsItsTextureWithoutTheGetter() {
        ImageAttributeImageId.getterAvailable = false
        val bitmap = render("ImageBackgroundRemoteButtonSnapshotWriter-454x200.rc")

        // The frame the skewed core abandoned, drawn whole on the getter-less path. The document's
        // bitmap is a uniform 8x8 of (236, 236, 236) under a scrim fading from (51, 46, 60) at the
        // container's start to transparent at its end, its geometry derived from the image's
        // published width and height: so the centre row runs dark to light only when the texture,
        // the `ImageAttribute` dimensions and the scrim all drew. The id itself is pinned by the
        // two tests above; this one is the end-to-end picture remote-m3-catalog bakes.
        val row = bitmap.height / 2
        val start = bitmap.getPixel(START_X, row)
        val end = bitmap.getPixel(END_X, row)
        assertTrue("the button drew nothing at its start: ${hex(start)}", start ushr 24 == 0xff)
        assertTrue("the button drew nothing at its end: ${hex(end)}", end ushr 24 == 0xff)
        assertTrue(
            "the container's start should be the scrim over the image, not ${hex(start)}",
            channels(start).all { it < 100 },
        )
        assertTrue(
            "the container's end should be the image through a faded scrim, not ${hex(end)} — " +
                "the texture or the image dimensions the scrim derives from did not resolve",
            channels(end).all { it > 200 },
        )
    }

    private fun channels(pixel: Int) =
        listOf((pixel shr 16) and 0xff, (pixel shr 8) and 0xff, pixel and 0xff)

    private fun hex(pixel: Int) = "#%08x".format(pixel)

    private fun render(fixture: String): Bitmap {
        val bytes =
            checkNotNull(javaClass.getResourceAsStream("/rc-fixtures/$fixture")) {
                    "missing fixture /rc-fixtures/$fixture"
                }
                .use { it.readBytes() }

        composeRule.setContent {
            val documentDensity = Density(DENSITY, LocalDensity.current.fontScale)
            CompositionLocalProvider(LocalDensity provides documentDensity) {
                Box(
                    Modifier.size(
                        with(documentDensity) { WIDTH.toDp() },
                        with(documentDensity) { HEIGHT.toDp() },
                    ),
                ) {
                    RemoteImageSupport.enableEncodedImageReferences()
                    ExperimentalRemoteDocumentPlayer(
                        document = RemoteDocument(bytes),
                        modifier = Modifier.fillMaxSize(),
                    )
                }
            }
        }
        composeRule.waitForIdle()

        val root = composeRule.activity.findViewById<ViewGroup>(android.R.id.content)
        root.measure(
            MeasureSpec.makeMeasureSpec(WIDTH, MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec(HEIGHT, MeasureSpec.EXACTLY),
        )
        root.layout(0, 0, WIDTH, HEIGHT)
        return Bitmap.createBitmap(WIDTH, HEIGHT, Bitmap.Config.ARGB_8888).also {
            root.draw(Canvas(it))
        }
    }

    private companion object {
        const val WIDTH = 454
        const val HEIGHT = 200
        const val DENSITY = 2f

        // Inside the pill's straight run on its centre row, clear of the rounded ends and the
        // label: (66, 62, 74) and (224, 224, 224) when the texture and scrim draw.
        const val START_X = 70
        const val END_X = 390
    }
}
