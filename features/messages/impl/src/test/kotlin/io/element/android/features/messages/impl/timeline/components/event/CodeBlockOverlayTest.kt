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
import org.robolectric.annotation.GraphicsMode

// Native graphics so that StaticLayout really measures and wraps text.
@GraphicsMode(GraphicsMode.Mode.NATIVE)
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
    fun `chrome grows only the block's first and last lines, not every wrapped line`() {
        // A single long source line that wraps across several layout lines: one paragraph, many lines.
        // The width is narrow enough that the block is guaranteed to wrap however text is measured.
        val code = "echo disabling swap and creating the new logical volume right now"
        val text = SpannableStringBuilder("intro\n$code\noutro")
        val start = 6
        val end = start + code.length
        text.markCodeBlock(start = start, end = end)

        val display = withCodeBlockChrome(text, headerPx = 96, footerPx = 120, languages = listOf("bash"))
        val plain = layoutOf(text, widthPx = NARROW_WIDTH_PX)
        val chromed = layoutOf(display, widthPx = NARROW_WIDTH_PX)

        assertThat(chromed.lineCount).isEqualTo(plain.lineCount)
        val firstBlockLine = chromed.getLineForOffset(start)
        val lastBlockLine = chromed.getLineForOffset(end - 1)
        // The premise of the test: the block really does wrap inside one paragraph.
        assertThat(lastBlockLine - firstBlockLine).isAtLeast(2)

        val heights = (0 until chromed.lineCount).map { line ->
            "line $line [${chromed.getLineStart(line)}..${chromed.getLineEnd(line)}) " +
                "height=${chromed.getLineBottom(line) - chromed.getLineTop(line)}"
        }
        val expectedHeights = (0 until plain.lineCount).map { line ->
            val plainHeight = plain.getLineBottom(line) - plain.getLineTop(line)
            val expectedHeight = when (line) {
                firstBlockLine -> plainHeight + 96
                lastBlockLine -> plainHeight + 120
                else -> plainHeight
            }
            "line $line [${plain.getLineStart(line)}..${plain.getLineEnd(line)}) height=$expectedHeight"
        }
        assertThat(heights).isEqualTo(expectedHeights)
    }

    @Test
    fun `a multi-line block grows only its first and last lines, not the lines in between`() {
        val text = SpannableStringBuilder("intro\none\ntwo\nthree\noutro")
        val start = 6
        val end = 19
        text.markCodeBlock(start = start, end = end)

        val display = withCodeBlockChrome(text, headerPx = 96, footerPx = 120, languages = listOf("bash"))
        val plain = layoutOf(text)
        val chromed = layoutOf(display)

        assertThat(chromed.lineCount).isEqualTo(plain.lineCount)
        val firstBlockLine = chromed.getLineForOffset(start)
        val lastBlockLine = chromed.getLineForOffset(end - 1)
        assertThat(lastBlockLine - firstBlockLine).isEqualTo(2)

        for (line in 0 until chromed.lineCount) {
            val plainHeight = plain.getLineBottom(line) - plain.getLineTop(line)
            val chromedHeight = chromed.getLineBottom(line) - chromed.getLineTop(line)
            val expectedHeight = when (line) {
                firstBlockLine -> plainHeight + 96
                lastBlockLine -> plainHeight + 120
                else -> plainHeight
            }
            assertThat(chromedHeight).isEqualTo(expectedHeight)
        }
    }

    @Test
    fun `a block without a language reserves no header, only the footer`() {
        val text = SpannableStringBuilder("intro\none\ntwo\noutro")
        val start = 6
        val end = 13
        text.markCodeBlock(start = start, end = end)

        val display = withCodeBlockChrome(text, headerPx = 96, footerPx = 120, languages = listOf(null))
        val plain = layoutOf(text)
        val chromed = layoutOf(display)

        val lastBlockLine = chromed.getLineForOffset(end - 1)
        for (line in 0 until chromed.lineCount) {
            val plainHeight = plain.getLineBottom(line) - plain.getLineTop(line)
            val chromedHeight = chromed.getLineBottom(line) - chromed.getLineTop(line)
            val expectedHeight = if (line == lastBlockLine) plainHeight + 120 else plainHeight
            assertThat(chromedHeight).isEqualTo(expectedHeight)
        }
    }

    @Test
    fun `a block whose first and last characters share a line grows it by header and footer at once`() {
        val text = SpannableStringBuilder("intro\ncode\noutro")
        val start = 6
        val end = 10
        text.markCodeBlock(start = start, end = end)

        val display = withCodeBlockChrome(text, headerPx = 96, footerPx = 120, languages = listOf("bash"))
        val plain = layoutOf(text)
        val chromed = layoutOf(display)

        val blockLine = chromed.getLineForOffset(start)
        for (line in 0 until chromed.lineCount) {
            val plainHeight = plain.getLineBottom(line) - plain.getLineTop(line)
            val chromedHeight = chromed.getLineBottom(line) - chromed.getLineTop(line)
            val expectedHeight = if (line == blockLine) plainHeight + 96 + 120 else plainHeight
            assertThat(chromedHeight).isEqualTo(expectedHeight)
        }
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

    private fun layoutOf(text: CharSequence, widthPx: Int = WIDTH_PX): Layout {
        return StaticLayout.Builder
            .obtain(text, 0, text.length, TextPaint(), widthPx)
            .build()
    }

    private companion object {
        const val WIDTH_PX = 400

        /** Narrow enough that a long code line has to wrap, whatever the test font measures. */
        const val NARROW_WIDTH_PX = 24
    }
}
