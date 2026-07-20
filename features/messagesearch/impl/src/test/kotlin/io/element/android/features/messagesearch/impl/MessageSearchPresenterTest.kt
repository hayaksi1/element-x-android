/*
 * Copyright (c) 2026 Element Creations Ltd.
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
 * Please see LICENSE files in the repository root for full details.
 */

package io.element.android.features.messagesearch.impl

import com.google.common.truth.Truth.assertThat
import io.element.android.libraries.dateformatter.api.DateFormatter
import io.element.android.libraries.dateformatter.test.FakeDateFormatter
import io.element.android.libraries.eventformatter.api.RoomLatestEventFormatter
import io.element.android.libraries.eventformatter.test.FakeRoomLatestEventFormatter
import io.element.android.libraries.matrix.api.core.EventId
import io.element.android.libraries.matrix.api.core.RoomId
import io.element.android.libraries.matrix.api.search.MessageSearchPaginationState
import io.element.android.libraries.matrix.api.search.MessageSearchResult
import io.element.android.libraries.matrix.api.timeline.item.event.ProfileDetails
import io.element.android.libraries.matrix.test.A_ROOM_ID
import io.element.android.libraries.matrix.test.A_USER_ID
import io.element.android.libraries.matrix.test.FakeMatrixClient
import io.element.android.libraries.matrix.test.search.FakeMessageSearch
import io.element.android.libraries.matrix.test.search.FakeMessageSearchService
import io.element.android.libraries.matrix.test.timeline.aMessageContent
import io.element.android.tests.testutils.test
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class MessageSearchPresenterTest {
    @Test
    fun `present - initial state`() = runTest {
        val presenter = createMessageSearchPresenter()
        presenter.test {
            val initialState = awaitItem()
            assertThat(initialState.query).isEmpty()
            assertThat(initialState.results).isEmpty()
            assertThat(initialState.isSearching).isFalse()
            assertThat(initialState.displayInitialState).isTrue()
            assertThat(initialState.isRoomScoped).isFalse()
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `present - the search is scoped to the room it was created for`() = runTest {
        val service = FakeMessageSearchService()
        val presenter = createMessageSearchPresenter(
            roomId = A_ROOM_ID,
            matrixClient = FakeMatrixClient(messageSearchService = service),
        )
        presenter.test {
            awaitItem().also { state ->
                assertThat(state.isRoomScoped).isTrue()
            }
            cancelAndIgnoreRemainingEvents()
        }
        assertThat(service.lastRoomId).isEqualTo(A_ROOM_ID)
        assertThat(service.createMessageSearchCallCount).isEqualTo(1)
    }

    @Test
    fun `present - a global search passes no room to the service`() = runTest {
        val service = FakeMessageSearchService()
        val presenter = createMessageSearchPresenter(
            roomId = null,
            matrixClient = FakeMatrixClient(messageSearchService = service),
        )
        presenter.test {
            awaitItem()
            cancelAndIgnoreRemainingEvents()
        }
        assertThat(service.lastRoomId).isNull()
    }

    @Test
    fun `present - typing marks the state as searching before the debounce elapses`() = runTest {
        val messageSearch = FakeMessageSearch()
        val presenter = createMessageSearchPresenter(messageSearch = messageSearch)
        presenter.test {
            awaitItem().also { state ->
                state.eventSink(MessageSearchEvents.QueryChanged("hello"))
            }
            awaitItem().also { state ->
                assertThat(state.query).isEqualTo("hello")
            }
            // The indicator is driven by the raw keystroke, so it is already on while the
            // debounced query is still pending — this is what stops the empty state flashing.
            awaitItem().also { state ->
                assertThat(state.isSearching).isTrue()
                assertThat(state.displayEmptyState).isFalse()
            }
            assertThat(messageSearch.lastQuery).isNull()

            advanceUntilIdle()
            assertThat(messageSearch.lastQuery).isEqualTo("hello")
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `present - a newer query supersedes one still inside the debounce window`() = runTest {
        val messageSearch = FakeMessageSearch()
        val presenter = createMessageSearchPresenter(messageSearch = messageSearch)
        presenter.test {
            awaitItem().also { state ->
                state.eventSink(MessageSearchEvents.QueryChanged("hel"))
            }
            skipItems(1)
            awaitItem().also { state ->
                state.eventSink(MessageSearchEvents.QueryChanged("hello"))
            }
            advanceUntilIdle()
            // Only the final query ever reached the SDK.
            assertThat(messageSearch.lastQuery).isEqualTo("hello")
            assertThat(messageSearch.setQueryCallCount).isEqualTo(1)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `present - clearing the query returns to the initial state without searching`() = runTest {
        val messageSearch = FakeMessageSearch()
        val presenter = createMessageSearchPresenter(messageSearch = messageSearch)
        presenter.test {
            awaitItem().also { state ->
                state.eventSink(MessageSearchEvents.QueryChanged(""))
            }
            advanceUntilIdle()
            assertThat(messageSearch.lastQuery).isNull()
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `present - results are mapped for display`() = runTest {
        val messageSearch = FakeMessageSearch()
        val formatter = FakeRoomLatestEventFormatter().apply { givenFormatResult("a formatted preview") }
        val presenter = createMessageSearchPresenter(
            messageSearch = messageSearch,
            roomLatestEventFormatter = formatter,
        )
        presenter.test {
            awaitItem().also { state ->
                state.eventSink(MessageSearchEvents.QueryChanged("hello"))
            }
            advanceUntilIdle()
            messageSearch.emitResults(persistentListOf(aMessageSearchResult()))
            advanceUntilIdle()

            expectMostRecentItem().also { state ->
                assertThat(state.results).hasSize(1)
                val item = state.results.first()
                assertThat(item.eventId).isEqualTo(EventId("\$anEventId"))
                assertThat(item.roomId).isEqualTo(A_ROOM_ID)
                assertThat(item.preview).isEqualTo("a formatted preview")
                assertThat(item.senderName).isEqualTo(A_USER_ID.value)
            }
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `present - a room-scoped search auto-paginates while its room has nothing to show`() = runTest {
        val messageSearch = FakeMessageSearch()
        val presenter = createMessageSearchPresenter(roomId = A_ROOM_ID, messageSearch = messageSearch)
        presenter.test {
            awaitItem().also { state ->
                state.eventSink(MessageSearchEvents.QueryChanged("hello"))
            }
            advanceUntilIdle()
            cancelAndIgnoreRemainingEvents()
        }
        // Globally-ranked results mean this room's matches may be pages deep, so we keep pulling —
        // but only up to the cap, never forever.
        assertThat(messageSearch.paginateCallCount).isEqualTo(MAX_AUTO_PAGINATIONS)
    }

    @Test
    fun `present - auto-pagination stops at the cap and offers to keep looking`() = runTest {
        val messageSearch = FakeMessageSearch()
        val presenter = createMessageSearchPresenter(roomId = A_ROOM_ID, messageSearch = messageSearch)
        presenter.test {
            awaitItem().also { state ->
                state.eventSink(MessageSearchEvents.QueryChanged("hello"))
            }
            advanceUntilIdle()
            expectMostRecentItem().also { state ->
                assertThat(state.hasReachedAutoPaginationCap).isTrue()
                // Never claim "no results" while pages remain unread.
                assertThat(state.displayEmptyState).isFalse()
                assertThat(state.displayKeepLoadingPrompt).isTrue()
            }
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `present - auto-pagination stops as soon as the room has a result`() = runTest {
        val messageSearch = FakeMessageSearch()
        val presenter = createMessageSearchPresenter(roomId = A_ROOM_ID, messageSearch = messageSearch)
        presenter.test {
            awaitItem().also { state ->
                state.eventSink(MessageSearchEvents.QueryChanged("hello"))
            }
            messageSearch.emitResults(persistentListOf(aMessageSearchResult()))
            advanceUntilIdle()
            cancelAndIgnoreRemainingEvents()
        }
        assertThat(messageSearch.paginateCallCount).isEqualTo(0)
    }

    @Test
    fun `present - a global search never auto-paginates`() = runTest {
        val messageSearch = FakeMessageSearch()
        val presenter = createMessageSearchPresenter(roomId = null, messageSearch = messageSearch)
        presenter.test {
            awaitItem().also { state ->
                state.eventSink(MessageSearchEvents.QueryChanged("hello"))
            }
            advanceUntilIdle()
            cancelAndIgnoreRemainingEvents()
        }
        // Global results are already ranked across every room, so there is nothing to skip past.
        assertThat(messageSearch.paginateCallCount).isEqualTo(0)
    }

    @Test
    fun `present - auto-pagination does not run once the end has been reached`() = runTest {
        val messageSearch = FakeMessageSearch().apply {
            emitPaginationState(MessageSearchPaginationState.Idle(endReached = true))
        }
        val presenter = createMessageSearchPresenter(roomId = A_ROOM_ID, messageSearch = messageSearch)
        presenter.test {
            awaitItem().also { state ->
                state.eventSink(MessageSearchEvents.QueryChanged("hello"))
            }
            advanceUntilIdle()
            awaitItem().also { state ->
                // Everything has been searched and this room genuinely has no match.
                assertThat(state.displayEmptyState).isTrue()
                assertThat(state.displayKeepLoadingPrompt).isFalse()
            }
            cancelAndIgnoreRemainingEvents()
        }
        assertThat(messageSearch.paginateCallCount).isEqualTo(0)
    }

    @Test
    fun `present - an explicit load more lifts the cap for another budget of pages`() = runTest {
        val messageSearch = FakeMessageSearch()
        val presenter = createMessageSearchPresenter(roomId = A_ROOM_ID, messageSearch = messageSearch)
        presenter.test {
            awaitItem().also { state ->
                state.eventSink(MessageSearchEvents.QueryChanged("hello"))
            }
            advanceUntilIdle()
            assertThat(messageSearch.paginateCallCount).isEqualTo(MAX_AUTO_PAGINATIONS)

            awaitItem().also { state ->
                state.eventSink(MessageSearchEvents.LoadMore)
            }
            advanceUntilIdle()
            cancelAndIgnoreRemainingEvents()
        }
        // The explicit page plus a fresh automatic budget.
        assertThat(messageSearch.paginateCallCount).isEqualTo(MAX_AUTO_PAGINATIONS * 2 + 1)
    }
}

private fun aMessageSearchResult(
    eventId: EventId = EventId("\$anEventId"),
    roomId: RoomId = A_ROOM_ID,
) = MessageSearchResult(
    roomId = roomId,
    eventId = eventId,
    senderId = A_USER_ID,
    senderProfile = ProfileDetails.Unavailable,
    content = aMessageContent(body = "hello world"),
    timestamp = 0L,
)

internal fun createMessageSearchPresenter(
    roomId: RoomId? = null,
    messageSearch: FakeMessageSearch = FakeMessageSearch(),
    matrixClient: FakeMatrixClient = FakeMatrixClient(
        messageSearchService = FakeMessageSearchService(messageSearch = messageSearch),
    ),
    roomLatestEventFormatter: RoomLatestEventFormatter = FakeRoomLatestEventFormatter(),
    dateFormatter: DateFormatter = FakeDateFormatter { _, _, _ -> "12:34" },
): MessageSearchPresenter {
    return MessageSearchPresenter(
        roomId = roomId,
        matrixClient = matrixClient,
        roomLatestEventFormatter = roomLatestEventFormatter,
        dateFormatter = dateFormatter,
    )
}
