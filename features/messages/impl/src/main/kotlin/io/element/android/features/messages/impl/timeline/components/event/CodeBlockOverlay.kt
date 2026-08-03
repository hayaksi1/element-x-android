/*
 * Copyright (c) 2025 Element Creations Ltd.
 * Copyright 2023-2025 New Vector Ltd.
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
 * Please see LICENSE files in the repository root for full details.
 */

package io.element.android.features.messages.impl.timeline.components.event

import android.content.ClipData
import android.content.ClipboardManager
import android.graphics.Paint
import android.os.Build
import android.text.Layout
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.LineHeightSpan
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.core.content.getSystemService
import io.element.android.compound.theme.ElementTheme
import io.element.android.compound.tokens.generated.CompoundIcons
import io.element.android.libraries.designsystem.theme.components.HorizontalDivider
import io.element.android.libraries.designsystem.theme.components.Icon
import io.element.android.libraries.designsystem.theme.components.Text
import io.element.android.libraries.designsystem.utils.snackbar.LocalSnackbarDispatcher
import io.element.android.libraries.designsystem.utils.snackbar.SnackbarMessage
import io.element.android.libraries.ui.strings.CommonStrings
import io.element.android.wysiwyg.view.spans.CodeBlockSpan
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.toImmutableList
import org.jsoup.nodes.Document

internal val CodeBlockHeaderHeight = 30.dp
internal val CodeBlockFooterHeight = 40.dp

private val COPY_ICON_SIZE = 16.dp
private val COPY_LABEL_SPACING = 8.dp
private val CODE_BLOCK_HORIZONTAL_INSET = 12.dp
private const val LANGUAGE_CLASS_PREFIX = "language-"

/**
 * A code block found in a rendered message, together with the bounds of the box it is drawn in.
 *
 * The pixel values are in the coordinate space of the [Layout] the block was measured in, and
 * already include the space reserved by [withCodeBlockChrome].
 */
internal data class CodeBlockOverlay(
    val code: String,
    val language: String?,
    val blockTopPx: Int,
    val blockBottomPx: Int,
    val blockRightPx: Int,
)

/**
 * The language of each code block in [document], in document order, or null where none is declared.
 *
 * The language only exists in the HTML (`<pre><code class="language-kotlin">`) and is dropped by the
 * time the DOM becomes spans, so it is read from the DOM and matched back up by position.
 */
internal fun codeBlockLanguages(document: Document?): List<String?> {
    document ?: return emptyList()
    return document.select("pre").map { pre ->
        pre.selectFirst("code")
            ?.classNames()
            ?.firstOrNull { it.startsWith(LANGUAGE_CLASS_PREFIX) }
            ?.removePrefix(LANGUAGE_CLASS_PREFIX)
            ?.takeIf { it.isNotBlank() }
    }
}

/**
 * Reserves room inside every code block for its header and copy row.
 *
 * A message is rendered by a single `TextView`, so the only way to make a block's own background
 * taller is to make its first and last lines taller. [LineHeightSpan]s do that without changing the
 * message's character offsets or what gets copied. The header is only reserved for blocks that
 * declare a language, so an unlabelled block does not gain an empty strip.
 */
internal fun withCodeBlockChrome(
    text: CharSequence,
    headerPx: Int,
    footerPx: Int,
    languages: List<String?>,
): CharSequence {
    if (!hasCodeBlock(text)) return text
    val spanned = text as Spanned
    val builder = SpannableStringBuilder(spanned)
    val spans = builder.getSpans(0, builder.length, CodeBlockSpan::class.java)
        .sortedBy { builder.getSpanStart(it) }
    for ((index, span) in spans.withIndex()) {
        val start = builder.getSpanStart(span)
        val end = builder.getSpanEnd(span)
        if (languages.getOrNull(index) != null) {
            builder.setSpan(
                CodeBlockChromeSpan(extraAscentPx = headerPx, extraDescentPx = 0),
                start,
                (start + 1).coerceAtMost(end),
                Spanned.SPAN_EXCLUSIVE_EXCLUSIVE,
            )
        }
        builder.setSpan(
            CodeBlockChromeSpan(extraAscentPx = 0, extraDescentPx = footerPx),
            (end - 1).coerceAtLeast(start),
            end,
            Spanned.SPAN_EXCLUSIVE_EXCLUSIVE,
        )
    }
    return builder
}

/** Whether [text] contains a code block at all. */
internal fun hasCodeBlock(text: CharSequence): Boolean {
    val spanned = text as? Spanned ?: return false
    return spanned.getSpans(0, spanned.length, CodeBlockSpan::class.java).isNotEmpty()
}

/**
 * Finds every code block in [text] and measures the box it is drawn in.
 *
 * The blocks are returned in document order, which is also how [languages] is matched back on.
 */
internal fun computeCodeBlockOverlays(
    text: CharSequence,
    layout: Layout,
    languages: List<String?> = emptyList(),
): ImmutableList<CodeBlockOverlay> {
    val spanned = text as? Spanned ?: return persistentListOf()
    return spanned.getSpans(0, spanned.length, CodeBlockSpan::class.java)
        .map { span -> spanned.getSpanStart(span) to spanned.getSpanEnd(span) }
        .sortedBy { (start, _) -> start }
        .mapIndexedNotNull { index, (start, end) ->
            if (start < 0 || end > spanned.length || start >= end) return@mapIndexedNotNull null
            val firstLine = layout.getLineForOffset(start)
            val lastLine = layout.getLineForOffset(end - 1)
            CodeBlockOverlay(
                code = spanned.subSequence(start, end).toString(),
                language = languages.getOrNull(index),
                blockTopPx = layout.getLineTop(firstLine),
                blockBottomPx = layout.getLineBottom(lastLine),
                // A block's box is only as wide as its widest line, not as wide as the message.
                blockRightPx = (firstLine..lastLine).maxOf { layout.getLineRight(it) }.toInt(),
            )
        }
        .toImmutableList()
}

/**
 * Draws the chrome of a code block: a language label and separator at the top, and a copy row at the
 * bottom, both inside the block's own box and within the space [withCodeBlockChrome] reserved.
 */
@Composable
internal fun BoxScope.CodeBlockCopyButtons(
    overlays: ImmutableList<CodeBlockOverlay>,
) {
    if (overlays.isEmpty()) return
    val context = LocalContext.current
    val snackbarDispatcher = LocalSnackbarDispatcher.current
    val copyLabel = stringResource(CommonStrings.action_copy)
    val density = LocalDensity.current
    for (overlay in overlays) {
        val blockWidth = with(density) { overlay.blockRightPx.toDp() }
        val separatorColor = ElementTheme.colors.borderInteractiveSecondary

        if (overlay.language != null) {
            Column(
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .offset { IntOffset(x = 0, y = overlay.blockTopPx) }
                    .width(blockWidth)
                    .height(CodeBlockHeaderHeight),
            ) {
                Text(
                    modifier = Modifier
                        .weight(1f)
                        .padding(horizontal = CODE_BLOCK_HORIZONTAL_INSET),
                    text = overlay.language,
                    style = ElementTheme.typography.fontBodySmMedium,
                    color = ElementTheme.colors.textSecondary,
                )
                HorizontalDivider(color = separatorColor)
            }
        }

        Column(
            modifier = Modifier
                .align(Alignment.TopStart)
                .offset {
                    IntOffset(x = 0, y = overlay.blockBottomPx - CodeBlockFooterHeight.roundToPx())
                }
                .width(blockWidth)
                .height(CodeBlockFooterHeight),
        ) {
            HorizontalDivider(color = separatorColor)
            Row(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .clickable(role = Role.Button, onClickLabel = copyLabel) {
                        context.getSystemService<ClipboardManager>()
                            ?.setPrimaryClip(ClipData.newPlainText("", overlay.code))
                        // Android 13+ shows its own clipboard confirmation.
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                            snackbarDispatcher.post(SnackbarMessage(CommonStrings.common_copied_to_clipboard))
                        }
                    },
                horizontalArrangement = Arrangement.Center,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    modifier = Modifier.size(COPY_ICON_SIZE),
                    imageVector = CompoundIcons.Copy(),
                    contentDescription = null,
                    tint = ElementTheme.colors.textSecondary,
                )
                Spacer(modifier = Modifier.width(COPY_LABEL_SPACING))
                Text(
                    text = copyLabel,
                    style = ElementTheme.typography.fontBodySmMedium,
                    color = ElementTheme.colors.textSecondary,
                )
            }
        }
    }
}

/** Makes a code block's first or last line taller so its chrome has somewhere to live. */
private class CodeBlockChromeSpan(
    private val extraAscentPx: Int,
    private val extraDescentPx: Int,
) : LineHeightSpan {
    override fun chooseHeight(
        text: CharSequence?,
        start: Int,
        end: Int,
        spanstartv: Int,
        lineHeight: Int,
        fm: Paint.FontMetricsInt?,
    ) {
        fm ?: return
        fm.ascent -= extraAscentPx
        fm.top -= extraAscentPx
        fm.descent += extraDescentPx
        fm.bottom += extraDescentPx
    }
}
