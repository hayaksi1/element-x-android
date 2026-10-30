/*
 * Copyright (c) 2026 Element Creations Ltd.
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
 * Please see LICENSE files in the repository root for full details.
 */

package io.element.android.libraries.matrix.impl.search.backfill

import io.element.android.libraries.core.extensions.runCatchingExceptions
import io.element.android.libraries.matrix.api.core.RoomId
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.DateDividerMode
import org.matrix.rustcomponents.sdk.Membership
import org.matrix.rustcomponents.sdk.Room
import org.matrix.rustcomponents.sdk.TimelineConfiguration
import org.matrix.rustcomponents.sdk.TimelineFilter
import org.matrix.rustcomponents.sdk.TimelineFocus
import uniffi.matrix_sdk_ui.TimelineReadReceiptTracking
import org.matrix.rustcomponents.sdk.Timeline as InnerTimeline

/**
 * The only part of a room the sweep needs: a live timeline it can walk backwards and release.
 */
internal interface SweepTimeline : AutoCloseable {
    val hasMoreToLoad: Boolean

    /** Fetches one older page. Success carries whether the start of the room was reached. */
    suspend fun paginateBackwards(): Result<Boolean>
}

/**
 * A live SDK timeline opened straight from the SDK client, bypassing [io.element.android.libraries.matrix.impl.room.RustRoomFactory].
 *
 * The factory serialises every room construction on one lock and builds a full [io.element.android.libraries.matrix.api.room.JoinedRoom]
 * under it, so a sweep that went through it queued the user's own room opens behind up to 200 of its own. Only a live
 * focus reaches the search index: the SDK indexes from the room's linked chunk, and event-focused or thread timelines
 * write to a linked chunk of their own that the indexer ignores.
 */
internal class RustSweepTimeline private constructor(
    private val room: Room,
    private val timeline: InnerTimeline,
) : SweepTimeline {
    override var hasMoreToLoad: Boolean = true
        private set

    override suspend fun paginateBackwards(): Result<Boolean> {
        return runCatchingExceptions { timeline.paginateBackwards(PAGE_SIZE) }
            .onSuccess { reachedStart -> hasMoreToLoad = !reachedStart }
    }

    override fun close() {
        timeline.close()
        room.close()
    }

    companion object {
        private const val PAGE_SIZE: UShort = 50u

        /** Null when the room is unknown or not joined. Throws when the SDK refuses to build the timeline. */
        suspend fun open(client: Client, roomId: RoomId): RustSweepTimeline? {
            val room = client.getRoom(roomId.value) ?: return null
            if (room.membership() != Membership.JOINED) {
                room.close()
                return null
            }
            val timeline = runCatchingExceptions {
                room.timelineWithConfiguration(
                    TimelineConfiguration(
                        focus = TimelineFocus.Live(hideThreadedEvents = false),
                        filter = TimelineFilter.All,
                        internalIdPrefix = "search_backfill",
                        dateDividerMode = DateDividerMode.DAILY,
                        trackReadReceipts = TimelineReadReceiptTracking.DISABLED,
                        reportUtds = false,
                    )
                )
            }.onFailure { room.close() }.getOrThrow()
            return RustSweepTimeline(room, timeline)
        }
    }
}
