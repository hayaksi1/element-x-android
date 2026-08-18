/*
 * Copyright (c) 2025 Element Creations Ltd.
 * Copyright 2024, 2025 New Vector Ltd.
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
 * Please see LICENSE files in the repository root for full details.
 */

@file:OptIn(ExperimentalCoroutinesApi::class)

package io.element.android.libraries.matrix.impl

import com.google.common.truth.Truth.assertThat
import io.element.android.libraries.core.coroutine.CoroutineDispatchers
import io.element.android.libraries.core.data.bytes
import io.element.android.libraries.featureflag.api.FeatureFlags
import io.element.android.libraries.featureflag.test.FakeFeatureFlagService
import io.element.android.libraries.matrix.api.paths.SessionPaths
import io.element.android.libraries.matrix.impl.fixtures.fakes.FakeFfiClient
import io.element.android.libraries.matrix.impl.fixtures.fakes.FakeFfiSyncService
import io.element.android.libraries.matrix.impl.room.FakeTimelineEventFilterFactory
import io.element.android.libraries.matrix.impl.search.backfill.SearchBackfillRequestBuilder
import io.element.android.libraries.matrix.test.AN_AVATAR_URL
import io.element.android.libraries.matrix.test.A_DEVICE_ID
import io.element.android.libraries.matrix.test.A_ROOM_ID
import io.element.android.libraries.matrix.test.A_USER_ID
import io.element.android.libraries.matrix.test.A_USER_NAME
import io.element.android.libraries.matrix.test.scanner.FakeContentScanner
import io.element.android.libraries.sessionstorage.api.SessionStore
import io.element.android.libraries.sessionstorage.test.InMemorySessionStore
import io.element.android.libraries.sessionstorage.test.aSessionData
import io.element.android.libraries.workmanager.api.WorkManagerRequestBuilder
import io.element.android.libraries.workmanager.test.FakeWorkManagerScheduler
import io.element.android.services.analytics.test.FakeAnalyticsService
import io.element.android.services.toolbox.test.systemclock.FakeSystemClock
import io.element.android.tests.testutils.lambda.lambdaRecorder
import io.element.android.tests.testutils.lambda.value
import io.element.android.tests.testutils.testCoroutineDispatchers
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Test
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.CreateRoomParameters
import org.matrix.rustcomponents.sdk.RoomHistoryVisibility
import org.matrix.rustcomponents.sdk.StoreSizes
import org.matrix.rustcomponents.sdk.UserProfile
import java.io.File

private const val AN_ACCOUNT_DATA_EVENT_TYPE = "org.example.custom"
private const val AN_ACCOUNT_DATA_CONTENT = """{"key":"value"}"""

class RustMatrixClientTest {
    @Test
    fun `ensure that sessionId and deviceId can be retrieved from the client`() = runTest {
        createRustMatrixClient().run {
            assertThat(sessionId).isEqualTo(A_USER_ID)
            assertThat(deviceId).isEqualTo(A_DEVICE_ID)
            destroy()
        }
    }

    @Test
    fun `clear cache invokes the method clearCaches from the client and close it`() = runTest {
        val clearCachesResult = lambdaRecorder<Unit> { }
        val closeResult = lambdaRecorder<Unit> { }
        val client = createRustMatrixClient(
            client = FakeFfiClient(
                clearCachesResult = clearCachesResult,
                closeResult = closeResult,
            )
        )
        client.clearCache()
        clearCachesResult.assertions().isCalledOnce()
        closeResult.assertions().isCalledOnce()
        client.destroy()
    }

    @Test
    fun `retrieving the UserProfile updates the database`() = runTest {
        val profilePersisted = CompletableDeferred<Unit>()
        val updateUserProfileResult = lambdaRecorder<String, String?, String?, Unit> { _, _, _ -> profilePersisted.complete(Unit) }
        val sessionStore = InMemorySessionStore(
            initialList = listOf(
                aSessionData(
                    sessionId = A_USER_ID.value,
                    userDisplayName = null,
                    userAvatarUrl = null,
                )
            ),
            updateUserProfileResult = updateUserProfileResult,
        )
        val client = createRustMatrixClient(
            client = FakeFfiClient(
                getProfileResult = { userId ->
                    UserProfile(
                        userId = userId,
                        displayName = A_USER_NAME,
                        avatarUrl = AN_AVATAR_URL,
                        status = null,
                        call = null,
                    )
                },
            ),
            sessionStore = sessionStore,
        )
        profilePersisted.await()
        updateUserProfileResult.assertions().isCalledOnce()
            .with(
                value(A_USER_ID.value),
                value(A_USER_NAME),
                value(AN_AVATAR_URL),
            )
        client.destroy()
    }

    @Test
    fun `getDatabaseSizes returns the database sizes`() = runTest {
        val client = createRustMatrixClient(
            client = FakeFfiClient(getStoreSizesResult = { StoreSizes(null, 10uL, 11uL, 12uL) })
        )

        client.getDatabaseSizes().getOrThrow().run {
            assertThat(cryptoStore).isNull()
            assertThat(stateStore).isEqualTo(10.bytes)
            assertThat(eventCacheStore).isEqualTo(11.bytes)
            assertThat(mediaStore).isEqualTo(12.bytes)
        }
    }

    @Test
    fun `createDM overrides room history visibility to invited`() = runTest {
        var createParameters: CreateRoomParameters? = null
        val createRoomLambda = lambdaRecorder<CreateRoomParameters, String> {
            createParameters = it
            A_ROOM_ID.value
        }
        val client = createRustMatrixClient(
            client = FakeFfiClient(createRoomResult = createRoomLambda)
        )

        client.createDM(userId = A_USER_ID, isEncrypted = true)

        createRoomLambda.assertions().isCalledOnce()
        assertThat(createParameters?.historyVisibilityOverride).isEqualTo(RoomHistoryVisibility.Invited)
    }

    @Test
    fun `enabling message search mid-session schedules the backfill`() = runTest {
        val submissions = mutableListOf<WorkManagerRequestBuilder>()
        val featureFlagService = FakeFeatureFlagService()
        // Unconfined main: the flag collector lives in sessionCoroutineScope (a child of
        // backgroundScope on the main dispatcher), and the standard dispatcher's scheduler does
        // not reliably resume background tasks from advanceUntilIdle. io stays standard because
        // the client wraps it in limitedParallelism, which unconfined does not support.
        val client = createRustMatrixClient(
            featureFlagService = featureFlagService,
            workManagerScheduler = FakeWorkManagerScheduler(submitLambda = { submissions += it }),
            isMessageSearchAvailable = true,
            dispatchers = CoroutineDispatchers(
                io = StandardTestDispatcher(testScheduler),
                computation = StandardTestDispatcher(testScheduler),
                main = UnconfinedTestDispatcher(testScheduler),
            ),
        )
        assertThat(submissions.filterIsInstance<SearchBackfillRequestBuilder>()).isEmpty()

        featureFlagService.setFeatureEnabled(FeatureFlags.MessageSearch, true)

        // The index is always attached, so a mid-session enable only needs the backfill kicked
        // off — no restart involved.
        assertThat(submissions.filterIsInstance<SearchBackfillRequestBuilder>()).hasSize(1)
        client.destroy()
    }

    @Test
    fun `getAccountData returns the raw content provided by the client`() = runTest {
        val accountDataResult = lambdaRecorder<String, String?> { AN_ACCOUNT_DATA_CONTENT }
        val client = createRustMatrixClient(
            client = FakeFfiClient(accountDataResult = accountDataResult)
        )

        assertThat(client.getAccountData(AN_ACCOUNT_DATA_EVENT_TYPE).getOrThrow()).isEqualTo(AN_ACCOUNT_DATA_CONTENT)
        accountDataResult.assertions().isCalledOnce().with(value(AN_ACCOUNT_DATA_EVENT_TYPE))
        client.destroy()
    }

    @Test
    fun `setAccountData forwards the event type and the raw content to the client`() = runTest {
        val setAccountDataResult = lambdaRecorder<String, String, Unit> { _, _ -> }
        val client = createRustMatrixClient(
            client = FakeFfiClient(setAccountDataResult = setAccountDataResult)
        )

        assertThat(client.setAccountData(AN_ACCOUNT_DATA_EVENT_TYPE, AN_ACCOUNT_DATA_CONTENT).isSuccess).isTrue()
        setAccountDataResult.assertions().isCalledOnce().with(value(AN_ACCOUNT_DATA_EVENT_TYPE), value(AN_ACCOUNT_DATA_CONTENT))
        client.destroy()
    }

    private fun TestScope.createRustMatrixClient(
        client: Client = FakeFfiClient(),
        sessionStore: SessionStore = InMemorySessionStore(
            updateUserProfileResult = { _, _, _ -> },
        ),
        featureFlagService: FakeFeatureFlagService = FakeFeatureFlagService(),
        workManagerScheduler: FakeWorkManagerScheduler = FakeWorkManagerScheduler(submitLambda = {}),
        isMessageSearchAvailable: Boolean = false,
        dispatchers: CoroutineDispatchers = testCoroutineDispatchers(),
    ) = RustMatrixClient(
        innerClient = client,
        sessionPaths = SessionPaths(fileDirectory = File("files"), cacheDirectory = File("cache")),
        sessionStore = sessionStore,
        appCoroutineScope = backgroundScope,
        sessionDelegate = aRustClientSessionDelegate(
            sessionStore = sessionStore,
        ),
        innerSyncService = FakeFfiSyncService(),
        dispatchers = dispatchers,
        baseCacheDirectory = File(""),
        clock = FakeSystemClock(),
        timelineEventFilterFactory = FakeTimelineEventFilterFactory(),
        featureFlagService = featureFlagService,
        analyticsService = FakeAnalyticsService(),
        workManagerScheduler = workManagerScheduler,
        contentScanner = FakeContentScanner(),
        isMessageSearchAvailable = isMessageSearchAvailable,
    )
}
