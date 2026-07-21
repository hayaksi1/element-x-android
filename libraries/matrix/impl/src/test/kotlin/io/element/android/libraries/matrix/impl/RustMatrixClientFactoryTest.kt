/*
 * Copyright (c) 2025 Element Creations Ltd.
 * Copyright 2024, 2025 New Vector Ltd.
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
 * Please see LICENSE files in the repository root for full details.
 */

package io.element.android.libraries.matrix.impl

import com.google.common.truth.Truth.assertThat
import io.element.android.libraries.featureflag.api.FeatureFlags
import io.element.android.libraries.featureflag.test.FakeFeatureFlagService
import io.element.android.libraries.matrix.api.core.SessionId
import io.element.android.libraries.matrix.impl.auth.FakeProxyProvider
import io.element.android.libraries.matrix.impl.room.FakeTimelineEventFilterFactory
import io.element.android.libraries.matrix.impl.storage.FakeSqliteStoreBuilderProvider
import io.element.android.libraries.network.useragent.SimpleUserAgentProvider
import io.element.android.libraries.sessionstorage.api.SessionStore
import io.element.android.libraries.sessionstorage.test.InMemorySessionStore
import io.element.android.libraries.sessionstorage.test.aSessionData
import io.element.android.libraries.workmanager.api.WorkManagerRequestBuilder
import io.element.android.libraries.workmanager.test.FakeWorkManagerScheduler
import io.element.android.services.analytics.test.FakeAnalyticsService
import io.element.android.services.toolbox.test.systemclock.FakeSystemClock
import io.element.android.tests.testutils.lambda.lambdaRecorder
import io.element.android.tests.testutils.testCoroutineDispatchers
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Test
import java.io.File

class RustMatrixClientFactoryTest {
    @Test
    fun test() = runTest {
        val scheduleVacuumLambda = lambdaRecorder<WorkManagerRequestBuilder, Unit> {}
        val workManagerScheduler = FakeWorkManagerScheduler(submitLambda = scheduleVacuumLambda)
        val sut = createRustMatrixClientFactory(workManagerScheduler = workManagerScheduler)

        val result = sut.create(aSessionData())

        assertThat(result.sessionId).isEqualTo(SessionId("@alice:server.org"))
        scheduleVacuumLambda.assertions().isCalledOnce()
        result.destroy()
    }

    @Test
    fun `create - message search is unavailable when the client secret is missing`() = runTest {
        val featureFlagService = FakeFeatureFlagService(
            initialState = mapOf(FeatureFlags.MessageSearch.key to true),
        )
        val sut = createRustMatrixClientFactory(
            featureFlagService = featureFlagService,
            workManagerScheduler = FakeWorkManagerScheduler(submitLambda = {}),
        )

        val result = sut.create(aSessionData().copy(passphrase = null))

        assertThat(result.isMessageSearchAvailable).isFalse()
        result.destroy()
    }

    @Test
    fun `create - message search availability uses the client builder decision`() = runTest {
        val featureFlagService = FakeFeatureFlagService(
            initialState = mapOf(FeatureFlags.MessageSearch.key to true),
        )
        val sut = createRustMatrixClientFactory(
            featureFlagService = featureFlagService,
            workManagerScheduler = FakeWorkManagerScheduler(submitLambda = {}),
        )

        val result = sut.create(aSessionData().copy(passphrase = "aSecret"))

        assertThat(result.isMessageSearchAvailable).isTrue()
        featureFlagService.setFeatureEnabled(FeatureFlags.MessageSearch, false)
        assertThat(result.isMessageSearchAvailable).isTrue()
        result.destroy()
    }
}

fun TestScope.createRustMatrixClientFactory(
    cacheDirectory: File = File("/cache"),
    sessionStore: SessionStore = InMemorySessionStore(
        updateUserProfileResult = { _, _, _ -> },
    ),
    clientBuilderProvider: ClientBuilderProvider = FakeClientBuilderProvider(),
    workManagerScheduler: FakeWorkManagerScheduler = FakeWorkManagerScheduler(),
    contentScannerUrlProvider: ContentScannerUrlProvider = { Result.success(null) },
    featureFlagService: FakeFeatureFlagService = FakeFeatureFlagService(),
) = RustMatrixClientFactory(
    cacheDirectory = cacheDirectory,
    appCoroutineScope = backgroundScope,
    coroutineDispatchers = testCoroutineDispatchers(),
    sessionStore = sessionStore,
    userAgentProvider = SimpleUserAgentProvider(),
    proxyProvider = FakeProxyProvider(),
    clock = FakeSystemClock(),
    analyticsService = FakeAnalyticsService(),
    featureFlagService = featureFlagService,
    timelineEventFilterFactory = FakeTimelineEventFilterFactory(),
    clientBuilderProvider = clientBuilderProvider,
    sqliteStoreBuilderProvider = FakeSqliteStoreBuilderProvider(),
    workManagerScheduler = workManagerScheduler,
    clientBuilderEnterpriseHook = { builder, _ -> builder },
)
