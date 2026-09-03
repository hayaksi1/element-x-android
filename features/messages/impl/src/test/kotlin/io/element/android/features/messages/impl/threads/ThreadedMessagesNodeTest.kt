/*
 * Copyright (c) 2026 Element Creations Ltd.
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
 * Please see LICENSE files in the repository root for full details.
 */

@file:OptIn(ExperimentalTestApi::class)

package io.element.android.features.messages.impl.threads

import androidx.activity.ComponentActivity
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.AndroidComposeUiTest
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.v2.runAndroidComposeUiTest
import androidx.lifecycle.Lifecycle
import com.bumble.appyx.core.modality.BuildContext
import com.bumble.appyx.testing.unit.common.helper.nodeTestHelper
import io.element.android.features.messages.impl.MessagesNavigator
import io.element.android.features.messages.impl.MessagesPresenter
import io.element.android.features.messages.impl.actionlist.ActionListPresenter
import io.element.android.features.messages.impl.actionlist.ActionListState
import io.element.android.features.messages.impl.actionlist.model.TimelineItemActionPostProcessor
import io.element.android.features.messages.impl.attachments.Attachment
import io.element.android.features.messages.impl.messagecomposer.MessageComposerPresenter
import io.element.android.features.messages.impl.messagecomposer.MessageComposerState
import io.element.android.features.messages.impl.timeline.TimelineController
import io.element.android.features.messages.impl.timeline.TimelinePresenter
import io.element.android.features.messages.impl.timeline.TimelineState
import io.element.android.features.messages.impl.timeline.di.aFakeTimelineItemPresenterFactories
import io.element.android.features.messages.impl.timeline.model.TimelineItem
import io.element.android.features.roommembermoderation.api.ModerationAction
import io.element.android.features.roommembermoderation.api.RoomMemberModerationRenderer
import io.element.android.features.roommembermoderation.api.RoomMemberModerationState
import io.element.android.libraries.architecture.Presenter
import io.element.android.libraries.emoji.api.picker.NoOpEmojiPickerRenderer
import io.element.android.libraries.matrix.api.core.EventId
import io.element.android.libraries.matrix.api.core.RoomId
import io.element.android.libraries.matrix.api.core.ThreadId
import io.element.android.libraries.matrix.api.core.UserId
import io.element.android.libraries.matrix.api.core.asEventId
import io.element.android.libraries.matrix.api.permalink.PermalinkData
import io.element.android.libraries.matrix.api.room.JoinedRoom
import io.element.android.libraries.matrix.api.room.errors.FocusEventException
import io.element.android.libraries.matrix.api.timeline.Timeline
import io.element.android.libraries.matrix.api.timeline.item.TimelineItemDebugInfo
import io.element.android.libraries.matrix.api.user.MatrixUser
import io.element.android.libraries.matrix.test.A_THREAD_ID
import io.element.android.libraries.matrix.test.permalink.FakePermalinkParser
import io.element.android.libraries.matrix.test.room.FakeJoinedRoom
import io.element.android.libraries.ui.strings.CommonStrings
import io.element.android.services.analytics.test.FakeAnalyticsService
import io.element.android.services.appnavstate.test.FakeAppNavigationStateService
import io.element.android.tests.testutils.robolectric.RobolectricTest
import io.element.android.tests.testutils.setSafeContent
import kotlinx.collections.immutable.ImmutableList
import org.junit.Test
import org.robolectric.shadows.ShadowLooper

class ThreadedMessagesNodeTest : RobolectricTest() {
    @Test
    fun `when the thread root event cannot be found, an error dialog is displayed`() = runAndroidComposeUiTest {
        val room = FakeJoinedRoom(
            createTimelineResult = { Result.failure(FocusEventException.EventNotFound(A_THREAD_ID.asEventId())) },
        )
        val node = createThreadedMessagesNode(room = room)
        node.nodeTestHelper().moveTo(Lifecycle.State.CREATED)
        ShadowLooper.runUiThreadTasksIncludingDelayedTasks()
        setSafeContent(clearAndroidUiDispatcher = true) {
            node.View(Modifier)
        }
        onNodeWithText(activity!!.getString(CommonStrings.error_message_not_found)).assertIsDisplayed()
    }

    private fun AndroidComposeUiTest<ComponentActivity>.createThreadedMessagesNode(
        room: JoinedRoom,
    ): ThreadedMessagesNode {
        return ThreadedMessagesNode(
            buildContext = BuildContext.root(savedStateMap = null),
            plugins = listOf(
                ThreadedMessagesNode.Inputs(threadRootEventId = A_THREAD_ID, focusedEventId = null),
                FakeThreadedMessagesNodeCallback(),
            ),
            room = room,
            analyticsService = FakeAnalyticsService(),
            messageComposerPresenterFactory = object : MessageComposerPresenter.Factory {
                override fun create(timelineController: TimelineController, navigator: MessagesNavigator, threadRoot: ThreadId?): MessageComposerPresenter {
                    error("Not expected to be called")
                }
            },
            timelinePresenterFactory = object : TimelinePresenter.Factory {
                override fun create(timelineController: TimelineController, navigator: MessagesNavigator): TimelinePresenter {
                    error("Not expected to be called")
                }
            },
            presenterFactory = object : MessagesPresenter.Factory {
                override fun create(
                    navigator: MessagesNavigator,
                    composerPresenter: Presenter<MessageComposerState>,
                    timelinePresenter: Presenter<TimelineState>,
                    actionListPresenter: Presenter<ActionListState>,
                    timelineController: TimelineController,
                ): MessagesPresenter {
                    error("Not expected to be called")
                }
            },
            actionListPresenterFactory = object : ActionListPresenter.Factory {
                override fun create(postProcessor: TimelineItemActionPostProcessor, timelineMode: Timeline.Mode): ActionListPresenter {
                    error("Not expected to be called")
                }
            },
            timelineItemPresenterFactories = aFakeTimelineItemPresenterFactories(),
            permalinkParser = FakePermalinkParser(),
            appNavigationStateService = FakeAppNavigationStateService(),
            roomMemberModerationRenderer = object : RoomMemberModerationRenderer {
                @Composable
                override fun Render(
                    state: RoomMemberModerationState,
                    onSelectAction: (ModerationAction, MatrixUser) -> Unit,
                    onAvatarClick: (MatrixUser) -> Unit,
                    modifier: Modifier,
                ) = Unit
            },
            emojiPickerRenderer = NoOpEmojiPickerRenderer,
        )
    }
}

private class FakeThreadedMessagesNodeCallback : ThreadedMessagesNode.Callback {
    override fun handleEventClick(timelineMode: Timeline.Mode, event: TimelineItem.Event, canUseOverlay: Boolean) = false
    override fun handleGalleryItemClick(timelineMode: Timeline.Mode, event: TimelineItem.Event, galleryItemIndex: Int, canUseOverlay: Boolean) = false
    override fun navigateToPreviewAttachments(attachments: ImmutableList<Attachment>, inReplyToEventId: EventId?, caption: String?) = Unit
    override fun navigateToRoomMemberDetails(userId: UserId) = Unit
    override fun handlePermalinkClick(data: PermalinkData) = Unit
    override fun navigateToEventDebugInfo(eventId: EventId?, debugInfo: TimelineItemDebugInfo) = Unit
    override fun handleForwardEventClick(eventId: EventId) = Unit
    override fun navigateToReportMessage(eventId: EventId, senderId: UserId) = Unit
    override fun navigateToSendLocation() = Unit
    override fun navigateToCreatePoll() = Unit
    override fun navigateToEditPoll(eventId: EventId) = Unit
    override fun navigateToCurrentLiveLocation() = Unit
    override fun navigateToRoomCall(roomId: RoomId, isAudioCall: Boolean) = Unit
    override fun navigateToThread(threadRootId: ThreadId, focusedEventId: EventId?) = Unit
    override fun navigateToDeveloperSettings() = Unit
    override fun navigateToAvatarPreview(username: String, avatarUrl: String) = Unit
}
