/*
 * Copyright (c) 2026 Element Creations Ltd.
 *
 * SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
 * Please see LICENSE files in the repository root for full details.
 */

package io.element.android.libraries.matrix.impl.search

import com.google.common.truth.Truth.assertThat
import org.junit.Test

/**
 * Expectations here were checked against tantivy 0.26.1's own `QueryParser` — the version
 * `matrix-sdk-search` compiles against — not inferred from the grammar. Each case notes the query it
 * parses to, because "does not throw" is not the same as "searches for what the user typed".
 */
class TantivyQueryEscaperTest {
    @Test
    fun `an ordinary multi-word query is passed through untouched`() {
        // The no-regression case. tantivy's parser is OR-by-default, so this stays
        // BooleanQuery[Should design, Should review, Should notes] exactly as it is today.
        assertThat("design review notes".escapeForTantivy()).isEqualTo("design review notes")
    }

    @Test
    fun `a pasted URL no longer parses as a field lookup`() {
        // The bug: unescaped, tantivy resolves `https` as a field name and fails the WHOLE search
        // with FieldDoesNotExist. Only the colon needs escaping; the slashes are not leading.
        assertThat("https://github.com/foo".escapeForTantivy()).isEqualTo("https\\://github.com/foo")
    }

    @Test
    fun `a real indexed field name is escaped too`() {
        // `date` IS in the schema, as a DATE field, so this fails differently and more confusingly:
        // DateFormatError rather than FieldDoesNotExist. The fix is not only about unknown fields.
        assertThat("date:2020".escapeForTantivy()).isEqualTo("date\\:2020")
    }

    @Test
    fun `a matrix id is escaped`() {
        // The second most likely paste after a URL. `@` and `.` are ordinary characters.
        assertThat("@alice:matrix.org".escapeForTantivy()).isEqualTo("@alice\\:matrix.org")
    }

    @Test
    fun `a colon separated from its field name by a space is still escaped`() {
        // The grammar allows whitespace between a field name and its colon, so `time: 12` would also
        // be read as a field access. Per-token escaping defeats the spaced form as well.
        assertThat("time: 12:30".escapeForTantivy()).isEqualTo("time\\: 12\\:30")
    }

    @Test
    fun `a leading hyphen is escaped`() {
        // `-` is the negation operator and is forbidden as the first character of a bare word, so a
        // stray leading hyphen hard-fails today.
        assertThat("-cats".escapeForTantivy()).isEqualTo("\\-cats")
    }

    @Test
    fun `an elastic range operator is escaped`() {
        // A genuine second failure class the desktop colon-only fix would have missed: unescaped,
        // `>5` fails with UnsupportedQuery("Range query need to target a specific field.").
        assertThat(">5".escapeForTantivy()).isEqualTo("\\>5")
    }

    @Test
    fun `quotes are escaped, which deliberately drops phrase search`() {
        // Documents the cost: a typed phrase search becomes two OR'd terms. Accepted because a
        // MISbalanced quote is a hard failure and the UI never advertised phrase syntax.
        assertThat("\"quoted phrase\"".escapeForTantivy()).isEqualTo("\\\"quoted phrase\\\"")
    }

    @Test
    fun `an unclosed quote no longer fails the search`() {
        // Why quotes are escaped at all: an odd number of quotes is a syntax error today, and
        // half-typed quotes happen constantly on a mobile keyboard.
        assertThat("\"unclosed phrase".escapeForTantivy()).isEqualTo("\\\"unclosed phrase")
    }

    @Test
    fun `parentheses are escaped`() {
        // An unbalanced paren is a hard parse failure, and parens are common in ordinary prose.
        assertThat("(a b)".escapeForTantivy()).isEqualTo("\\(a b\\)")
    }

    @Test
    fun `a backslash the user typed is doubled`() {
        // Guards the escaper against itself: without this the user's backslash would escape the one
        // we appended and shift the whole token. This is why escaping is a single forward pass.
        assertThat("foo\\bar".escapeForTantivy()).isEqualTo("foo\\\\bar")
    }

    @Test
    fun `a plus is left alone when it is not leading`() {
        // `+` is only an operator in leading position. Confirms the escaper is not over-broad.
        assertThat("C++".escapeForTantivy()).isEqualTo("C++")
    }

    @Test
    fun `a date with slashes is left alone`() {
        // Slashes are only escaped when leading, where they would open a regex literal.
        assertThat("1/2/2024".escapeForTantivy()).isEqualTo("1/2/2024")
    }

    @Test
    fun `a bare-word boolean operator is neutralised`() {
        // A uniformity choice rather than purely an error fix: the query is literal text, so
        // `a AND b` searches for three words instead of silently switching to boolean AND.
        assertThat("hello NOT".escapeForTantivy()).isEqualTo("hello \\NOT")
    }

    @Test
    fun `a punctuation-only query is escaped rather than failing`() {
        // The residual cost, recorded honestly: this no longer errors, but it tokenises to nothing
        // and becomes EmptyQuery — zero results, silently. Better than killing the search, not good.
        assertThat(":::".escapeForTantivy()).isEqualTo("\\:\\:\\:")
    }

    @Test
    fun `a lone star matches nothing instead of everything`() {
        // A real behaviour delta: `*` alone is AllQuery today and EmptyQuery after this change.
        // Neither is a sensible search, but the change should be pinned rather than discovered.
        assertThat("*".escapeForTantivy()).isEqualTo("\\*")
    }

    @Test
    fun `runs of whitespace collapse and the query is trimmed`() {
        // Semantically neutral to tantivy — whitespace is only a separator — but it is an
        // observable change to the string we hand over, so it is pinned.
        assertThat("   spaced   out  ".escapeForTantivy()).isEqualTo("spaced out")
    }

    @Test
    fun `an empty query stays empty`() {
        assertThat("".escapeForTantivy()).isEqualTo("")
        assertThat("   ".escapeForTantivy()).isEqualTo("")
    }
}
