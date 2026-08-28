/*
 * Copyright (c) 2026 Element Creations Ltd.
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
 * Please see LICENSE files in the repository root for full details.
 */

package io.element.android.x.share

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import java.io.File

/**
 * The system reads the share targets through manifest and resource declarations only, so the Direct Share row goes
 * silently empty if either half is dropped. The category has to stay in step with the one
 * DefaultNotificationConversationService puts on every shortcut it publishes.
 */
class ConversationShareTargetTest {
    private val manifest = File("src/main/AndroidManifest.xml").readText()
    private val shortcuts = File("src/main/res/xml/shortcuts.xml").readText()

    @Test
    fun `the activity receiving shares points at the share targets`() {
        assertThat(manifest).contains("android:name=\"android.app.shortcuts\"")
        assertThat(manifest).contains("android:resource=\"@xml/shortcuts\"")
    }

    @Test
    fun `the share target routes to the activity receiving shares`() {
        assertThat(shortcuts).contains("android:targetClass=\"io.element.android.x.MainActivity\"")
    }

    @Test
    fun `the share target declares the category the published shortcuts carry`() {
        assertThat(shortcuts).contains("android:name=\"io.element.android.category.SHARE_TARGET\"")
    }
}
