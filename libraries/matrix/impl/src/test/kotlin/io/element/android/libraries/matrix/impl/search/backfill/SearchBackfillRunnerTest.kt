/*
 * Copyright (c) 2026 Element Creations Ltd.
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
 * Please see LICENSE files in the repository root for full details.
 */

package io.element.android.libraries.matrix.impl.search.backfill

import com.google.common.truth.Truth.assertThat
import io.element.android.libraries.matrix.api.core.RoomId
import io.element.android.libraries.matrix.api.search.RoomSweepOutcome
import io.element.android.libraries.matrix.api.search.SearchBackfillCursor
import io.element.android.libraries.matrix.api.search.SearchBackfillStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import org.junit.Test
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds

/**
 * These tests pin the LOOP SHAPE and nothing more.
 *
 * They cannot show that a single message becomes searchable: the chain from `paginate()` through the
 * SDK event cache into tantivy has no app-level observation point, and no index API exists over FFI.
 * A fully green file here means the loop iterated correctly over fakes. It is not evidence the
 * feature works, and it must never be cited as such.
 */
class SearchBackfillRunnerTest {
    @Test
    fun `each room is paginated until it reports the start of the room`() = runTest {
        val timeline = fakeTimeline(reachStartAfter = 3)
        val runner = runner(rooms = listOf(A_ROOM), timelines = mapOf(A_ROOM to timeline))

        val cursor = runner.runOnce()

        assertThat(timeline.paginateCallCount).isEqualTo(3)
        assertThat(cursor.outcomes[A_ROOM.value]).isEqualTo(RoomSweepOutcome.REACHED_START)
        assertThat(cursor.isDrained).isTrue()
    }

    @Test
    fun `a room that cannot paginate is never asked to`() = runTest {
        // The regression test for the silent no-op: paginate() THROWS CannotPaginate when the status
        // says it cannot, so calling it unguarded would turn "nothing to fetch" into a fake failure.
        val timeline = fakeTimeline(canPaginate = false)
        val runner = runner(rooms = listOf(A_ROOM), timelines = mapOf(A_ROOM to timeline))

        val cursor = runner.runOnce()

        assertThat(timeline.paginateCallCount).isEqualTo(0)
        assertThat(cursor.outcomes[A_ROOM.value]).isEqualTo(RoomSweepOutcome.REACHED_START)
    }

    @Test
    fun `pagination stops at the per-room page cap`() = runTest {
        val timeline = fakeTimeline(reachStartAfter = Int.MAX_VALUE)
        val runner = runner(
            rooms = listOf(A_ROOM),
            timelines = mapOf(A_ROOM to timeline),
            budget = SearchBackfillBudget(maxPagesPerRoom = 4),
        )

        val cursor = runner.runOnce()

        assertThat(timeline.paginateCallCount).isEqualTo(4)
        assertThat(cursor.outcomes[A_ROOM.value]).isEqualTo(RoomSweepOutcome.PAGE_CAP)
    }

    @Test
    fun `a room is abandoned after repeated failures and the sweep continues`() = runTest {
        val failing = fakeTimeline(failEvery = true)
        val healthy = fakeTimeline(reachStartAfter = 1)
        val runner = runner(
            rooms = listOf(A_ROOM, B_ROOM),
            timelines = mapOf(A_ROOM to failing, B_ROOM to healthy),
            budget = SearchBackfillBudget(maxFailuresPerRoom = 2),
        )

        val cursor = runner.runOnce()

        assertThat(failing.paginateCallCount).isEqualTo(2)
        assertThat(cursor.outcomes[A_ROOM.value]).isEqualTo(RoomSweepOutcome.FAILED)
        // The important half: one bad room must not sink the sweep.
        assertThat(cursor.outcomes[B_ROOM.value]).isEqualTo(RoomSweepOutcome.REACHED_START)
    }

    @Test
    fun `a room that is no longer joined is skipped without paginating`() = runTest {
        val runner = runner(rooms = listOf(A_ROOM), timelines = emptyMap())

        val cursor = runner.runOnce()

        assertThat(cursor.outcomes[A_ROOM.value]).isEqualTo(RoomSweepOutcome.NOT_JOINED)
    }

    @Test
    fun `a room the SDK cannot open is recorded as failed and the sweep continues`() = runTest {
        val healthy = fakeTimeline(reachStartAfter = 1)
        val runner = SearchBackfillRunner(
            store = InMemoryStore(),
            roomsProvider = { listOf(A_ROOM, B_ROOM) },
            openTimeline = { roomId -> if (roomId == A_ROOM) error("no timeline for you") else healthy },
            currentTimeMillis = { 0L },
        )

        val cursor = runner.runOnce()

        assertThat(cursor.outcomes[A_ROOM.value]).isEqualTo(RoomSweepOutcome.FAILED)
        assertThat(cursor.outcomes[B_ROOM.value]).isEqualTo(RoomSweepOutcome.REACHED_START)
    }

    @Test
    fun `an empty queue asks for another execution instead of reporting completion`() = runTest {
        // A headless start right after the caches were cleared can see an empty room list. Reading
        // that as "all done" would park the sweep until the next app start with nothing indexed.
        val runner = runner(rooms = emptyList(), timelines = emptyMap())

        val cursor = runner.runOnce()

        assertThat(cursor.needsAnotherExecution).isTrue()
    }

    @Test
    fun `a drained queue with visited rooms does not ask for another execution`() = runTest {
        val runner = runner(
            rooms = listOf(A_ROOM),
            timelines = mapOf(A_ROOM to fakeTimeline(reachStartAfter = 1)),
        )

        val cursor = runner.runOnce()

        assertThat(cursor.needsAnotherExecution).isFalse()
    }

    @Test
    fun `the timeline is always released, including when pagination fails`() = runTest {
        // 200 rooms of un-closed Rust handles would be a slow leak with no symptom until it hurts.
        val timeline = fakeTimeline(failEvery = true)
        val runner = runner(
            rooms = listOf(A_ROOM),
            timelines = mapOf(A_ROOM to timeline),
            budget = SearchBackfillBudget(maxFailuresPerRoom = 1),
        )

        runner.runOnce()

        assertThat(timeline.isClosed).isTrue()
    }

    @Test
    fun `the execution page budget stops the sweep early and is recorded`() = runTest {
        val timelines = (1..5).associate { index ->
            RoomId("!room$index:server") to fakeTimeline(reachStartAfter = Int.MAX_VALUE)
        }
        val runner = runner(
            rooms = timelines.keys.toList(),
            timelines = timelines,
            budget = SearchBackfillBudget(maxPagesPerRoom = 10, maxPagesPerExecution = 15),
        )

        val cursor = runner.runOnce()

        assertThat(cursor.pagesIssued).isAtMost(15)
        assertThat(cursor.stoppedByBudget).isTrue()
        assertThat(cursor.isDrained).isFalse()
    }

    @Test
    fun `a stored cursor resumes where it stopped and does not revisit earlier rooms`() = runTest {
        val first = fakeTimeline(reachStartAfter = 1)
        val second = fakeTimeline(reachStartAfter = 1)
        val store = InMemoryStore(
            SearchBackfillCursor(
                generation = 1,
                queue = listOf(A_ROOM.value, B_ROOM.value),
                index = 1,
            )
        )
        val runner = SearchBackfillRunner(
            store = store,
            roomsProvider = { error("must not rebuild the queue while one is in progress") },
            openTimeline = mapOf(A_ROOM to first, B_ROOM to second)::get,
            currentTimeMillis = { 0L },
        )

        val cursor = runner.runOnce()

        assertThat(first.paginateCallCount).isEqualTo(0)
        assertThat(second.paginateCallCount).isEqualTo(1)
        assertThat(cursor.isDrained).isTrue()
    }

    @Test
    fun `a drained cursor starts a new generation only when asked to`() = runTest {
        val store = InMemoryStore(
            SearchBackfillCursor(generation = 4, queue = listOf(A_ROOM.value), index = 1)
        )
        val runner = SearchBackfillRunner(
            store = store,
            roomsProvider = { listOf(B_ROOM) },
            openTimeline = { null },
            currentTimeMillis = { 0L },
        )

        val cursor = runner.runOnce(restartWhenDrained = true)

        assertThat(cursor.generation).isEqualTo(5)
        assertThat(cursor.queue).isEqualTo(listOf(B_ROOM.value))
    }

    @Test
    fun `a routine run leaves a drained generation alone`() = runTest {
        val drained = SearchBackfillCursor(generation = 4, queue = listOf(A_ROOM.value), index = 1, finishedAt = 42L)
        val store = InMemoryStore(drained)
        val runner = SearchBackfillRunner(
            store = store,
            roomsProvider = { error("must not build a new queue after the previous one drained") },
            openTimeline = { error("must not touch any room after the previous generation drained") },
            currentTimeMillis = { 0L },
        )

        val cursor = runner.runOnce()

        assertThat(cursor).isEqualTo(drained)
        assertThat(store.writes).isEqualTo(0)
    }

    @Test
    fun `a routine run retries a generation that found no rooms`() = runTest {
        val store = InMemoryStore(SearchBackfillCursor(generation = 1, queue = emptyList(), finishedAt = 42L))
        val timeline = fakeTimeline(reachStartAfter = 1)
        val runner = SearchBackfillRunner(
            store = store,
            roomsProvider = { listOf(A_ROOM) },
            openTimeline = { timeline },
            currentTimeMillis = { 0L },
        )

        val cursor = runner.runOnce()

        assertThat(cursor.generation).isEqualTo(2)
        assertThat(timeline.paginateCallCount).isEqualTo(1)
    }

    @Test
    fun `the room on screen is moved behind the others and left for later while it stays open`() = runTest {
        val onScreen = fakeTimeline(reachStartAfter = 1)
        val other = fakeTimeline(reachStartAfter = 1)
        val runner = runner(
            rooms = listOf(A_ROOM, B_ROOM),
            timelines = mapOf(A_ROOM to onScreen, B_ROOM to other),
            visibleRoomId = { A_ROOM },
        )

        val cursor = runner.runOnce()

        assertThat(onScreen.paginateCallCount).isEqualTo(0)
        assertThat(other.paginateCallCount).isEqualTo(1)
        assertThat(cursor.queue).isEqualTo(listOf(B_ROOM.value, A_ROOM.value))
        assertThat(cursor.index).isEqualTo(1)
        assertThat(cursor.needsAnotherExecution).isTrue()
    }

    @Test
    fun `a room opened while it is being swept is left for later`() = runTest {
        val opened = fakeTimeline(reachStartAfter = Int.MAX_VALUE)
        val other = fakeTimeline(reachStartAfter = 1)
        val runner = runner(
            rooms = listOf(A_ROOM, B_ROOM),
            timelines = mapOf(A_ROOM to opened, B_ROOM to other),
            visibleRoomId = { if (opened.paginateCallCount >= 2) A_ROOM else null },
        )

        val cursor = runner.runOnce()

        assertThat(opened.paginateCallCount).isEqualTo(2)
        assertThat(opened.isClosed).isTrue()
        assertThat(other.paginateCallCount).isEqualTo(1)
        assertThat(cursor.queue).isEqualTo(listOf(B_ROOM.value, A_ROOM.value))
        assertThat(cursor.pagesIssued).isEqualTo(3)
        assertThat(cursor.isDrained).isFalse()
    }

    @Test
    fun `the room on screen is swept once it is closed`() = runTest {
        var visible: RoomId? = A_ROOM
        val onScreen = fakeTimeline(reachStartAfter = 1)
        val other = fakeTimeline(reachStartAfter = 1)
        val runner = runner(
            rooms = listOf(A_ROOM, B_ROOM),
            timelines = mapOf(A_ROOM to onScreen, B_ROOM to other),
            visibleRoomId = { visible.also { visible = null } },
        )

        val cursor = runner.runOnce()

        assertThat(other.paginateCallCount).isEqualTo(1)
        assertThat(onScreen.paginateCallCount).isEqualTo(1)
        assertThat(cursor.isDrained).isTrue()
        assertThat(cursor.outcomes.keys).containsExactly(A_ROOM.value, B_ROOM.value)
    }

    @Test
    fun `progress is persisted after every room`() = runTest {
        val store = InMemoryStore()
        val timelines = mapOf(
            A_ROOM to fakeTimeline(reachStartAfter = 1),
            B_ROOM to fakeTimeline(reachStartAfter = 1),
        )
        val runner = runner(rooms = listOf(A_ROOM, B_ROOM), timelines = timelines, store = store)

        runner.runOnce()

        // Two rooms plus the final write: process death costs at most one room of progress.
        assertThat(store.writes).isAtLeast(3)
        assertThat(store.getCursor()?.isDrained).isTrue()
    }

    @Test
    fun `the execution deadline stops the sweep between rooms`() = runTest {
        // Every other test freezes the clock, so without this the time budgets are never exercised
        // at all and a wrong comparison would pass silently.
        val timelines = (1..5).associate { index ->
            RoomId("!room$index:server") to fakeTimeline(reachStartAfter = 1)
        }
        // Advances 40s per reading, so the 1-minute deadline trips after the first room.
        var now = 0L
        val runner = SearchBackfillRunner(
            store = InMemoryStore(),
            roomsProvider = { timelines.keys.toList() },
            openTimeline = timelines::get,
            budget = SearchBackfillBudget(executionDeadline = 1.minutes),
            currentTimeMillis = { now.also { now += 40_000 } },
        )

        val cursor = runner.runOnce()

        assertThat(cursor.stoppedByBudget).isTrue()
        assertThat(cursor.isDrained).isFalse()
        // Later rooms must be left untouched for the next execution to resume into.
        assertThat(timelines.values.count { it.paginateCallCount > 0 }).isLessThan(timelines.size)
    }

    @Test
    fun `the per-room time limit stops that room and moves on`() = runTest {
        val slow = fakeTimeline(reachStartAfter = Int.MAX_VALUE)
        var now = 0L
        val runner = SearchBackfillRunner(
            store = InMemoryStore(),
            roomsProvider = { listOf(A_ROOM) },
            openTimeline = { slow },
            budget = SearchBackfillBudget(maxPagesPerRoom = 100, maxRoomDuration = 10.seconds),
            currentTimeMillis = { now.also { now += 4_000 } },
        )

        val cursor = runner.runOnce()

        assertThat(cursor.outcomes[A_ROOM.value]).isEqualTo(RoomSweepOutcome.PAGE_CAP)
        // Time, not the page cap of 100, is what stopped it.
        assertThat(slow.paginateCallCount).isLessThan(100)
    }

    @Test
    fun `an empty room list finishes without touching any room`() = runTest {
        val runner = runner(rooms = emptyList(), timelines = emptyMap())

        val cursor = runner.runOnce()

        assertThat(cursor.queue).isEmpty()
        assertThat(cursor.finishedAt).isNotNull()
    }
}

private val A_ROOM = RoomId("!a:server")
private val B_ROOM = RoomId("!b:server")

private fun runner(
    rooms: List<RoomId>,
    timelines: Map<RoomId, CountingTimeline>,
    budget: SearchBackfillBudget = SearchBackfillBudget(),
    store: SearchBackfillStore = InMemoryStore(),
    visibleRoomId: () -> RoomId? = { null },
): SearchBackfillRunner {
    return SearchBackfillRunner(
        store = store,
        roomsProvider = { rooms },
        openTimeline = timelines::get,
        visibleRoomId = visibleRoomId,
        budget = budget,
        // Fixed clock: these tests assert page counts, never elapsed time.
        currentTimeMillis = { 0L },
    )
}

private fun fakeTimeline(
    reachStartAfter: Int = 1,
    canPaginate: Boolean = true,
    failEvery: Boolean = false,
): CountingTimeline = CountingTimeline(reachStartAfter, canPaginate, failEvery)

/**
 * Counts pagination calls, which is the only thing these tests can observe.
 */
private class CountingTimeline(
    private val reachStartAfter: Int,
    override val hasMoreToLoad: Boolean,
    private val failEvery: Boolean,
) : SweepTimeline {
    var paginateCallCount = 0
        private set

    var isClosed = false
        private set

    override suspend fun paginateBackwards(): Result<Boolean> {
        paginateCallCount++
        if (failEvery) return Result.failure(IllegalStateException("network"))
        return Result.success(paginateCallCount >= reachStartAfter)
    }

    override fun close() {
        isClosed = true
    }
}

private class InMemoryStore(
    private var cursor: SearchBackfillCursor? = null,
) : SearchBackfillStore {
    var writes = 0
        private set

    private val flow = MutableStateFlow(cursor)

    override fun cursorFlow(): Flow<SearchBackfillCursor?> = flow

    override suspend fun getCursor(): SearchBackfillCursor? = cursor

    override suspend fun setCursor(cursor: SearchBackfillCursor) {
        writes++
        this.cursor = cursor
        flow.value = cursor
    }

    override suspend fun clear() {
        cursor = null
        flow.value = null
    }
}
