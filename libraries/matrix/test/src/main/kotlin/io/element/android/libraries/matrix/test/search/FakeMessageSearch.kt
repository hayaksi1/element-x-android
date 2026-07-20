/*
 * Copyright (c) 2026 Element Creations Ltd.
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
 * Please see LICENSE files in the repository root for full details.
 */

package io.element.android.libraries.matrix.test.search

import io.element.android.libraries.matrix.api.search.MessageSearch
import io.element.android.libraries.matrix.api.search.MessageSearchPaginationState
import io.element.android.libraries.matrix.api.search.MessageSearchResult
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

class FakeMessageSearch(
    private val setQueryResult: (String) -> Result<Unit> = { Result.success(Unit) },
    private val paginateResult: () -> Result<Unit> = { Result.success(Unit) },
) : MessageSearch {
    private val mutableResults = MutableStateFlow<ImmutableList<MessageSearchResult>>(persistentListOf())
    override val results: StateFlow<ImmutableList<MessageSearchResult>> = mutableResults

    private val mutablePaginationState = MutableStateFlow<MessageSearchPaginationState>(
        MessageSearchPaginationState.Idle(endReached = false)
    )
    override val paginationState: StateFlow<MessageSearchPaginationState> = mutablePaginationState

    var lastQuery: String? = null
        private set

    var setQueryCallCount = 0
        private set

    var paginateCallCount = 0
        private set

    override suspend fun setQuery(query: String): Result<Unit> {
        lastQuery = query
        setQueryCallCount++
        return setQueryResult(query)
    }

    override suspend fun paginate(): Result<Unit> {
        paginateCallCount++
        return paginateResult()
    }

    fun emitResults(results: ImmutableList<MessageSearchResult>) {
        mutableResults.value = results
    }

    fun emitPaginationState(state: MessageSearchPaginationState) {
        mutablePaginationState.value = state
    }
}
