/*
 * Copyright (c) 2026 Element Creations Ltd.
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
 * Please see LICENSE files in the repository root for full details.
 */

package io.element.android.features.messagesearch.impl

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import dev.zacsweers.metro.Assisted
import dev.zacsweers.metro.AssistedFactory
import dev.zacsweers.metro.AssistedInject
import io.element.android.libraries.architecture.Presenter
import io.element.android.libraries.dateformatter.api.DateFormatter
import io.element.android.libraries.dateformatter.api.DateFormatterMode
import io.element.android.libraries.designsystem.components.avatar.AvatarData
import io.element.android.libraries.designsystem.components.avatar.AvatarSize
import io.element.android.libraries.eventformatter.api.RoomLatestEventFormatter
import io.element.android.libraries.matrix.api.MatrixClient
import io.element.android.libraries.matrix.api.core.RoomId
import io.element.android.libraries.matrix.api.roomlist.LatestEventValue
import io.element.android.libraries.matrix.api.search.MessageSearchPaginationState
import io.element.android.libraries.matrix.api.search.MessageSearchResult
import io.element.android.libraries.matrix.api.timeline.item.event.getAvatarUrl
import io.element.android.libraries.matrix.api.timeline.item.event.getDisambiguatedDisplayName
import kotlinx.collections.immutable.toImmutableList
import kotlinx.coroutines.delay

/**
 * iOS uses 250 ms and it feels right; long enough to skip intermediate keystrokes, short enough
 * that the list does not feel laggy.
 */
private const val DEBOUNCE_MILLIS = 250L

/**
 * Room-scoped searches filter a globally-ranked result set client-side, so a room with few matches
 * can need several pages before anything surfaces. We paginate automatically up to this many pages,
 * then hand the decision back to the user rather than spinning forever.
 */
internal const val MAX_AUTO_PAGINATIONS = 5

@AssistedInject
class MessageSearchPresenter(
    @Assisted private val roomId: RoomId?,
    private val matrixClient: MatrixClient,
    private val roomLatestEventFormatter: RoomLatestEventFormatter,
    private val dateFormatter: DateFormatter,
) : Presenter<MessageSearchState> {
    @AssistedFactory
    fun interface Factory {
        fun create(roomId: RoomId?): MessageSearchPresenter
    }

    @Composable
    override fun present(): MessageSearchState {
        val coroutineScope = rememberCoroutineScope()
        // One cursor per screen. Cancelling the scope releases the underlying Rust service.
        val messageSearch = remember(coroutineScope) {
            matrixClient.messageSearchService.createMessageSearch(coroutineScope, roomId)
        }

        var query by rememberSaveable { mutableStateOf("") }
        var isSearching by remember { mutableStateOf(false) }
        var hasError by remember { mutableStateOf(false) }
        var autoPaginationCount by remember { mutableIntStateOf(0) }
        var loadMoreCount by remember { mutableIntStateOf(0) }
        var handledLoadMoreCount by remember { mutableIntStateOf(0) }

        val results by messageSearch.results.collectAsState()
        val paginationState by messageSearch.paginationState.collectAsState()

        LaunchedEffect(query) {
            // A new query invalidates the previous pagination budget.
            autoPaginationCount = 0
            loadMoreCount = 0
            handledLoadMoreCount = 0
            hasError = false
            if (query.isBlank()) {
                isSearching = false
                return@LaunchedEffect
            }
            // Flip the indicator on the raw keystroke, not the debounced one, so the empty state
            // does not flash while the first search is still pending.
            isSearching = true
            // Relaunching this effect cancels the previous one, so a still-pending query is
            // superseded by the newer one — the user typing again always wins.
            delay(DEBOUNCE_MILLIS)
            hasError = messageSearch.setQuery(query).isFailure
            isSearching = false
        }

        // Explicit load-more performs one page. Room-scoped searches then keep pulling pages while
        // this room has nothing to show, up to a cap. The loop owns each page until it completes,
        // so updating the completed-page budget cannot cancel the in-flight SDK call.
        LaunchedEffect(roomId, query, isSearching, loadMoreCount) {
            if (query.isBlank() || isSearching || hasError) return@LaunchedEffect

            suspend fun paginate(): Boolean {
                val result = messageSearch.paginate()
                hasError = result.isFailure
                return result.isSuccess
            }

            if (loadMoreCount > handledLoadMoreCount) {
                handledLoadMoreCount = loadMoreCount
                if (!paginate()) return@LaunchedEffect
            }

            if (roomId == null) return@LaunchedEffect
            while (messageSearch.results.value.isEmpty() && autoPaginationCount < MAX_AUTO_PAGINATIONS) {
                val idle = messageSearch.paginationState.value as? MessageSearchPaginationState.Idle ?: break
                if (idle.endReached || !paginate()) break
                autoPaginationCount++
            }
        }

        val items = remember(results) {
            results.map { it.toResultItem() }.toImmutableList()
        }

        fun handleEvent(event: MessageSearchEvents) {
            when (event) {
                is MessageSearchEvents.QueryChanged -> {
                    query = event.query
                }
                MessageSearchEvents.LoadMore -> {
                    // Lift the automatic cap for another budget's worth of pages.
                    hasError = false
                    autoPaginationCount = 0
                    loadMoreCount++
                }
            }
        }

        return MessageSearchState(
            query = query,
            results = items,
            isSearching = isSearching,
            isPaginating = paginationState is MessageSearchPaginationState.Loading,
            endReached = (paginationState as? MessageSearchPaginationState.Idle)?.endReached == true,
            isRoomScoped = roomId != null,
            hasError = hasError,
            hasReachedAutoPaginationCap = roomId != null &&
                results.isEmpty() &&
                !hasError &&
                autoPaginationCount >= MAX_AUTO_PAGINATIONS,
            eventSink = ::handleEvent,
        )
    }

    private fun MessageSearchResult.toResultItem(): MessageSearchResultItem {
        val senderName = senderProfile.getDisambiguatedDisplayName(senderId)
        return MessageSearchResultItem(
            roomId = roomId,
            eventId = eventId,
            senderAvatarData = AvatarData(
                id = senderId.value,
                name = senderName,
                url = senderProfile.getAvatarUrl(),
                size = AvatarSize.UserListItem,
            ),
            senderName = senderName,
            // RoomLatestEventFormatter, not TimelineEventFormatter: the latter deliberately
            // error()s on MessageContent in debuggable builds, and a search hit is always a message.
            preview = roomLatestEventFormatter.format(
                latestEvent = LatestEventValue.Remote(
                    timestamp = timestamp,
                    content = content,
                    senderId = senderId,
                    senderProfile = senderProfile,
                    isOwn = senderId == matrixClient.sessionId,
                ),
                isDmRoom = false,
            )?.toString().orEmpty(),
            formattedDate = dateFormatter.format(
                timestamp = timestamp,
                mode = DateFormatterMode.TimeOrDate,
                useRelative = true,
            ),
        )
    }
}
