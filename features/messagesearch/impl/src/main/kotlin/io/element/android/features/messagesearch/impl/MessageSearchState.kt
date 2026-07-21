/*
 * Copyright (c) 2026 Element Creations Ltd.
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
 * Please see LICENSE files in the repository root for full details.
 */

package io.element.android.features.messagesearch.impl

import io.element.android.libraries.designsystem.components.avatar.AvatarData
import io.element.android.libraries.matrix.api.core.EventId
import io.element.android.libraries.matrix.api.core.RoomId
import kotlinx.collections.immutable.ImmutableList

data class MessageSearchState(
    val query: String,
    val results: ImmutableList<MessageSearchResultItem>,
    /** A keystroke has been made but the debounced query has not been handed to the SDK yet. */
    val isSearching: Boolean,
    val isPaginating: Boolean,
    val endReached: Boolean,
    /** True when this search is limited to a single room. */
    val isRoomScoped: Boolean,
    /** True when setting the query or loading another page failed. */
    val hasError: Boolean,
    /**
     * Room-scoped only: automatic pagination gave up before finding anything in this room, so the
     * user is offered the choice to keep looking rather than being shown an indefinite spinner.
     */
    val hasReachedAutoPaginationCap: Boolean,
    val eventSink: (MessageSearchEvents) -> Unit,
) {
    /** Nothing has been typed yet — prompt rather than claim there are no results. */
    val displayInitialState: Boolean = query.isBlank() && !hasError

    val displayErrorState: Boolean = hasError

    /** The query genuinely produced nothing and there is nothing left to load. */
    val displayEmptyState: Boolean = query.isNotBlank() &&
        results.isEmpty() &&
        !hasError &&
        !isSearching &&
        !isPaginating &&
        endReached

    /** Results are empty but pages remain — offer to keep loading instead of claiming "no results". */
    val displayKeepLoadingPrompt: Boolean = query.isNotBlank() &&
        results.isEmpty() &&
        !hasError &&
        !isSearching &&
        !isPaginating &&
        !endReached

    val displayLoadMoreIndicator: Boolean = results.isNotEmpty() && !endReached && !hasError
}

data class MessageSearchResultItem(
    val roomId: RoomId,
    val eventId: EventId,
    val senderAvatarData: AvatarData,
    val senderName: String,
    val preview: String,
    val formattedDate: String,
)
