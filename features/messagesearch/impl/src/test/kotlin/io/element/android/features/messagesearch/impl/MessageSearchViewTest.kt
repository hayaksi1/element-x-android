/*
 * Copyright (c) 2026 Element Creations Ltd.
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
 * Please see LICENSE files in the repository root for full details.
 */

@file:OptIn(ExperimentalTestApi::class)

package io.element.android.features.messagesearch.impl

import androidx.activity.ComponentActivity
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.v2.runAndroidComposeUiTest
import com.google.common.truth.Truth.assertThat
import io.element.android.libraries.ui.strings.CommonStrings
import io.element.android.tests.testutils.robolectric.RobolectricTest
import org.junit.Test

class MessageSearchViewTest : RobolectricTest() {
    @Test
    fun `generic search error is rendered`() = runAndroidComposeUiTest<ComponentActivity> {
        setContent {
            MessageSearchView(
                state = aMessageSearchState(
                    query = "a private search query",
                    hasError = true,
                ),
                onResultClick = {},
                onBackClick = {},
            )
        }

        onNodeWithText(activity!!.getString(CommonStrings.screen_message_search_error)).assertExists()
    }

    @Test
    fun `an exhausted search reports no results`() = runAndroidComposeUiTest<ComponentActivity> {
        setContent {
            MessageSearchView(
                state = aMessageSearchState(
                    query = "a word with no matches",
                    endReached = true,
                ),
                onResultClick = {},
                onBackClick = {},
            )
        }

        onNodeWithText(activity!!.getString(CommonStrings.common_no_results)).assertExists()
    }

    @Test
    fun `load-more footer triggers once until the results change`() = runAndroidComposeUiTest<ComponentActivity> {
        var loadMoreCallCount = 0
        var state by mutableStateOf(
            aMessageSearchState(
                query = "hello",
                results = aMessageSearchResultItemList(),
                eventSink = { event ->
                    if (event == MessageSearchEvents.LoadMore) {
                        loadMoreCallCount++
                    }
                },
            )
        )
        setContent {
            MessageSearchView(
                state = state,
                onResultClick = {},
                onBackClick = {},
            )
        }
        waitForIdle()
        assertThat(loadMoreCallCount).isEqualTo(1)

        runOnIdle {
            state = state.copy(isPaginating = true)
        }
        waitForIdle()

        assertThat(loadMoreCallCount).isEqualTo(1)
    }
}
