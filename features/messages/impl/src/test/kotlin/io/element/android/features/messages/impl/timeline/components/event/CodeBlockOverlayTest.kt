/*
 * Copyright 2026 hayaksi1
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
 * Please see LICENSE files in the repository root for full details.
 */

package io.element.android.features.messages.impl.timeline.components.event

import android.text.Layout
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.StaticLayout
import android.text.TextPaint
import com.google.common.truth.Truth.assertThat
import io.element.android.tests.testutils.robolectric.RobolectricTest
import io.element.android.wysiwyg.view.spans.CodeBlockSpan
import org.jsoup.Jsoup
import org.junit.Test

class CodeBlockOverlayTest : RobolectricTest() {
    @Test
    fun `a plain CharSequence yields no code blocks`() {
        val text = "no spans here"
        assertThat(computeCodeBlockOverlays(text, layoutOf(text))).isEmpty()
    }

    @Test
    fun `a Spanned without a code block yields no code blocks`() {
        val text = SpannableStringBuilder("just some text")
        assertThat(computeCodeBlockOverlays(text, layoutOf(text))).isEmpty()
    }

    @Test
    fun `a single code block yields its code and its top edge`() {
        val text = SpannableStringBuilder("before\ncode line\nafter")
        text.markCodeBlock(start = 7, end = 16)
        val layout = layoutOf(text)

        val overlays = computeCodeBlockOverlays(text, layout)

        assertThat(overlays).hasSize(1)
        assertThat(overlays.first().code).isEqualTo("code line")
        assertThat(overlays.first().blockTopPx).isEqualTo(layout.getLineTop(layout.getLineForOffset(7)))
    }

    @Test
    fun `several code blocks are returned in document order`() {
        val text = SpannableStringBuilder("aaa\nfirst\nbbb\nsecond\nccc")
        text.markCodeBlock(start = 14, end = 20)
        text.markCodeBlock(start = 4, end = 9)

        val overlays = computeCodeBlockOverlays(text, layoutOf(text))

        assertThat(overlays.map { it.code }).containsExactly("first", "second").inOrder()
    }

    @Test
    fun `a code block keeps its inner line breaks so the copied code stays intact`() {
        val text = SpannableStringBuilder("intro\none\ntwo\noutro")
        text.markCodeBlock(start = 6, end = 13)

        val overlays = computeCodeBlockOverlays(text, layoutOf(text))

        assertThat(overlays.single().code).isEqualTo("one\ntwo")
    }

    @Test
    fun `chrome is only reserved for messages that actually contain a code block`() {
        assertThat(hasCodeBlock("plain text")).isFalse()
        assertThat(hasCodeBlock(SpannableStringBuilder("still no spans"))).isFalse()

        val withBlock = SpannableStringBuilder("intro\ncode\noutro")
        withBlock.markCodeBlock(start = 6, end = 10)
        assertThat(hasCodeBlock(withBlock)).isTrue()
    }

    @Test
    fun `reserving chrome leaves the text and the copied code untouched`() {
        val original = SpannableStringBuilder("intro\none\ntwo\noutro")
        original.markCodeBlock(start = 6, end = 13)

        val display = withCodeBlockChrome(original, headerPx = 96, footerPx = 120, languages = listOf("kotlin"))

        assertThat(display.toString()).isEqualTo(original.toString())
        assertThat(computeCodeBlockOverlays(display, layoutOf(display)).single().code).isEqualTo("one\ntwo")
    }

    @Test
    fun `a message with no code block is returned unchanged rather than copied`() {
        val plain = "nothing to reserve"
        assertThat(withCodeBlockChrome(plain, headerPx = 96, footerPx = 120, languages = emptyList())).isSameInstanceAs(plain)
    }

    @Test
    fun `the language is read off the code element's class, in document order`() {
        val document = Jsoup.parse(
            """
            <p>intro</p>
            <pre><code class="language-kotlin">val x = 1</code></pre>
            <pre><code>no language here</code></pre>
            <pre><code class="language-python">print(1)</code></pre>
            """.trimIndent()
        )

        assertThat(codeBlockLanguages(document)).containsExactly("kotlin", null, "python").inOrder()
    }

    @Test
    fun `a message with no html has no languages`() {
        assertThat(codeBlockLanguages(null)).isEmpty()
    }

    private fun SpannableStringBuilder.markCodeBlock(start: Int, end: Int) {
        setSpan(CodeBlockSpan(0, 0), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
    }

    private fun layoutOf(text: CharSequence): Layout {
        return StaticLayout.Builder
            .obtain(text, 0, text.length, TextPaint(), WIDTH_PX)
            .build()
    }

    private companion object {
        const val WIDTH_PX = 400
    }
}
