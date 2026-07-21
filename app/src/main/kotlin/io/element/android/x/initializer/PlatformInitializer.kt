/*
 * Copyright (c) 2025 Element Creations Ltd.
 * Copyright 2022-2025 New Vector Ltd.
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
 * Please see LICENSE files in the repository root for full details.
 */

package io.element.android.x.initializer

import android.annotation.SuppressLint
import android.content.Context
import android.system.Os
import android.util.Log
import androidx.startup.Initializer
import io.element.android.features.rageshake.api.logs.createWriteToFilesConfiguration
import io.element.android.libraries.architecture.bindings
import io.element.android.libraries.core.extensions.runCatchingExceptions
import io.element.android.libraries.featureflag.api.FeatureFlags
import io.element.android.libraries.matrix.api.tracing.TracingConfiguration
import io.element.android.x.di.AppBindings
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import timber.log.Timber

private const val ELEMENT_X_TARGET = "elementx"

// The SDK sets no global log level, and `matrix_sdk_search` is absent from its default target list,
// so without this directive every log line from the message search index is silently dropped.
// The indexing task itself lives under `matrix_sdk::event_cache`, so enable the Event Cache trace
// log pack as well to follow a message from sync into the index.
// Debuggable builds only: the SDK logs the full message body at debug level, and release logs can be
// uploaded via rageshake.
private const val MATRIX_SDK_SEARCH_TARGET = "matrix_sdk_search"

class PlatformInitializer : Initializer<Unit> {
    override fun create(context: Context) {
        // Init the SDK with the Android Context, so it can be used with rustls and other Android specific features
        runCatchingExceptions {
            org.matrix.rustsdk.Android.init(context)
        }.onFailure {
            // We can't log this to Timber since the logs aren't initialized yet, so we log it to Logcat instead
            @SuppressLint("LogNotTimber")
            Log.e("PlatformInitializer", "Failed to init the SDK with an Android Context. The app probably won't work properly.", it)
        }

        val appBindings = context.bindings<AppBindings>()
        val tracingService = appBindings.tracingService()
        val platformService = appBindings.platformService()
        val bugReporter = appBindings.bugReporter()
        Timber.plant(tracingService.createTimberTree(ELEMENT_X_TARGET))
        val preferencesStore = appBindings.preferencesStore()
        val featureFlagService = appBindings.featureFlagService()
        val logLevel = runBlocking { preferencesStore.getTracingLogLevelFlow().first() }
        val tracingConfiguration = TracingConfiguration(
            writesToLogcat = runBlocking { featureFlagService.isFeatureEnabled(FeatureFlags.PrintLogsToLogcat) },
            writesToFilesConfiguration = bugReporter.createWriteToFilesConfiguration(),
            logLevel = logLevel,
            extraTargets = buildList {
                add(ELEMENT_X_TARGET)
                if (appBindings.buildMeta().isDebuggable) {
                    add(MATRIX_SDK_SEARCH_TARGET)
                }
            },
            traceLogPacks = runBlocking { preferencesStore.getTracingLogPacksFlow().first() },
            sdkSentryDsn = appBindings.sentrySdkDsn()?.value?.takeIf { it.isNotBlank() },
        )
        bugReporter.setCurrentTracingLogLevel(logLevel.name)

        // Init the tracing service with the configuration so we have logging enabled as soon as possible
        platformService.init(tracingConfiguration)
        // Also set env variable for rust back trace
        Os.setenv("RUST_BACKTRACE", "1", true)
    }

    override fun dependencies(): List<Class<out Initializer<*>>> = mutableListOf()
}
