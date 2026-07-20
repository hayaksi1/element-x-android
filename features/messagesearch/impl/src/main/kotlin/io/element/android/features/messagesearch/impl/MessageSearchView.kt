/*
 * Copyright (c) 2026 Element Creations Ltd.
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
 * Please see LICENSE files in the repository root for full details.
 */

package io.element.android.features.messagesearch.impl

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.TextFieldColors
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.PreviewParameter
import androidx.compose.ui.unit.dp
import io.element.android.compound.theme.ElementTheme
import io.element.android.compound.tokens.generated.CompoundIcons
import io.element.android.libraries.designsystem.components.avatar.Avatar
import io.element.android.libraries.designsystem.components.avatar.AvatarType
import io.element.android.libraries.designsystem.components.button.BackButton
import io.element.android.libraries.designsystem.preview.ElementPreview
import io.element.android.libraries.designsystem.preview.PreviewsDayNight
import io.element.android.libraries.designsystem.theme.components.CircularProgressIndicator
import io.element.android.libraries.designsystem.theme.components.FilledTextField
import io.element.android.libraries.designsystem.theme.components.Icon
import io.element.android.libraries.designsystem.theme.components.IconButton
import io.element.android.libraries.designsystem.theme.components.Scaffold
import io.element.android.libraries.designsystem.theme.components.Text
import io.element.android.libraries.designsystem.theme.components.TextButton
import io.element.android.libraries.designsystem.theme.components.TopAppBar
import io.element.android.libraries.testtags.TestTags
import io.element.android.libraries.ui.strings.CommonStrings
import kotlinx.collections.immutable.ImmutableList

@Composable
fun MessageSearchView(
    state: MessageSearchState,
    onResultClick: (MessageSearchResultItem) -> Unit,
    onBackClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Scaffold(
        modifier = modifier,
        topBar = {
            MessageSearchTopBar(onBackClick = onBackClick)
        },
        content = { padding ->
            MessageSearchContent(
                state = state,
                onResultClick = onResultClick,
                modifier = Modifier
                    .padding(padding)
                    .consumeWindowInsets(padding)
            )
        }
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MessageSearchTopBar(
    onBackClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    TopAppBar(
        modifier = modifier,
        navigationIcon = {
            BackButton(onClick = onBackClick)
        },
        titleStr = stringResource(CommonStrings.screen_message_search_title),
    )
}

@Composable
private fun MessageSearchContent(
    state: MessageSearchState,
    onResultClick: (MessageSearchResultItem) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier) {
        SearchTextField(
            query = state.query,
            onQueryChange = { state.eventSink(MessageSearchEvents.QueryChanged(it)) },
            placeholder = stringResource(CommonStrings.action_search),
            modifier = Modifier.fillMaxWidth(),
        )
        when {
            state.displayInitialState -> {
                CenteredMessage(text = stringResource(CommonStrings.screen_message_search_index_notice))
            }
            state.displayEmptyState -> {
                CenteredMessage(text = stringResource(CommonStrings.common_no_results))
            }
            state.displayKeepLoadingPrompt -> {
                KeepLookingPrompt(
                    isRoomScoped = state.isRoomScoped,
                    onLoadMoreClick = { state.eventSink(MessageSearchEvents.LoadMore) },
                )
            }
            else -> {
                MessageSearchResultList(
                    results = state.results,
                    displayLoadMoreIndicator = state.displayLoadMoreIndicator,
                    onResultClick = onResultClick,
                    onReachedLoadMore = { state.eventSink(MessageSearchEvents.LoadMore) },
                )
            }
        }
    }
}

@Composable
private fun MessageSearchResultList(
    results: ImmutableList<MessageSearchResultItem>,
    displayLoadMoreIndicator: Boolean,
    onResultClick: (MessageSearchResultItem) -> Unit,
    onReachedLoadMore: () -> Unit,
    modifier: Modifier = Modifier,
) {
    LazyColumn(modifier = modifier) {
        items(results) { result ->
            MessageSearchResultRow(
                result = result,
                onClick = { onResultClick(result) },
            )
        }
        if (displayLoadMoreIndicator) {
            item {
                LoadMoreIndicator(modifier = Modifier.fillMaxWidth())
                LaunchedEffect(onReachedLoadMore) {
                    onReachedLoadMore()
                }
            }
        }
    }
}

@Composable
private fun CenteredMessage(
    text: String,
    modifier: Modifier = Modifier,
) {
    Text(
        text = text,
        style = ElementTheme.typography.fontBodyLgRegular,
        color = ElementTheme.colors.textSecondary,
        textAlign = TextAlign.Center,
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 32.dp, vertical = 24.dp),
    )
}

@Composable
private fun KeepLookingPrompt(
    isRoomScoped: Boolean,
    onLoadMoreClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 32.dp, vertical = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = if (isRoomScoped) {
                stringResource(CommonStrings.screen_message_search_room_no_results_yet)
            } else {
                stringResource(CommonStrings.common_no_results)
            },
            style = ElementTheme.typography.fontBodyLgRegular,
            color = ElementTheme.colors.textSecondary,
            textAlign = TextAlign.Center,
        )
        TextButton(
            text = stringResource(CommonStrings.action_load_more),
            onClick = onLoadMoreClick,
        )
    }
}

@Composable
private fun LoadMoreIndicator(modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .wrapContentHeight()
            .padding(24.dp),
        contentAlignment = Alignment.Center,
    ) {
        CircularProgressIndicator(
            strokeWidth = 2.dp,
        )
    }
}

@Composable
private fun SearchTextField(
    query: String,
    onQueryChange: (String) -> Unit,
    placeholder: String,
    modifier: Modifier = Modifier,
    colors: TextFieldColors = TextFieldDefaults.colors(
        focusedContainerColor = Color.Transparent,
        unfocusedContainerColor = Color.Transparent,
        unfocusedPlaceholderColor = ElementTheme.colors.textSecondary,
        focusedPlaceholderColor = ElementTheme.colors.textSecondary,
        focusedTextColor = ElementTheme.colors.textPrimary,
        unfocusedTextColor = ElementTheme.colors.textPrimary,
        focusedIndicatorColor = ElementTheme.colors.borderInteractiveSecondary,
        unfocusedIndicatorColor = ElementTheme.colors.borderInteractiveSecondary,
    ),
) {
    val focusManager = LocalFocusManager.current
    FilledTextField(
        modifier = modifier.testTag(TestTags.searchTextField.value),
        textStyle = ElementTheme.typography.fontBodyLgRegular,
        singleLine = true,
        value = query,
        onValueChange = onQueryChange,
        keyboardActions = KeyboardActions(
            onSearch = {
                focusManager.clearFocus()
            }
        ),
        colors = colors,
        placeholder = { Text(placeholder) },
        trailingIcon = {
            if (query.isNotEmpty()) {
                IconButton(
                    onClick = {
                        onQueryChange("")
                    }
                ) {
                    Icon(
                        imageVector = CompoundIcons.Close(),
                        contentDescription = stringResource(CommonStrings.action_clear),
                    )
                }
            } else {
                Icon(
                    imageVector = CompoundIcons.Search(),
                    contentDescription = stringResource(CommonStrings.action_search),
                )
            }
        },
    )
}

@Composable
private fun MessageSearchResultRow(
    result: MessageSearchResultItem,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(
                top = 12.dp,
                bottom = 12.dp,
                start = 16.dp,
                end = 16.dp,
            )
            .height(IntrinsicSize.Min),
    ) {
        Avatar(
            avatarData = result.senderAvatarData,
            avatarType = AvatarType.User,
            modifier = Modifier.align(Alignment.CenterVertically),
        )
        Column(
            modifier = Modifier
                .weight(1f)
                .padding(horizontal = 16.dp)
        ) {
            Row(modifier = Modifier.fillMaxWidth()) {
                Text(
                    text = result.senderName,
                    maxLines = 1,
                    style = ElementTheme.typography.fontBodyLgMedium,
                    color = ElementTheme.colors.textPrimary,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    text = result.formattedDate,
                    maxLines = 1,
                    style = ElementTheme.typography.fontBodySmRegular,
                    color = ElementTheme.colors.textSecondary,
                )
            }
            Text(
                text = result.preview,
                maxLines = 2,
                style = ElementTheme.typography.fontBodyMdRegular,
                color = ElementTheme.colors.textSecondary,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@PreviewsDayNight
@Composable
internal fun MessageSearchViewPreview(@PreviewParameter(MessageSearchStateProvider::class) state: MessageSearchState) = ElementPreview {
    MessageSearchView(
        state = state,
        onResultClick = {},
        onBackClick = {},
    )
}
