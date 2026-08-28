# Test fixtures

## `rr-glued-brace/`

The real preimage and postimage of rerere cache entry
`f8cb8ae9ac82a7eae4becc1b969f835425763750`, recovered from the pre-purge backup
of `$GITDIR/rr-cache`. This entry was replaying a resolution of
`ToHtmlDocument.kt` that had lost the `withHeadingsAsBoldParagraphs` fast-path
guard and glued the function's closing brace onto its `return`:

    return document.body().html()    }

It carried no conflict marker, was not empty, was not an LFS pointer, and its
braces balanced — so all three rules the cache audit had at the time passed it,
and `check-integration.py` reported zero problems. It was found by accident, not
by audit, which is the whole reason `.fork/lib/rr_semantic.py` exists.

## `rr-sound-sibling/`

Entry `ff722e81b25db186e7cde861d6becd22b958ab11`: the **correct** resolution of
the same conflict in the same file, composing both sides
(`html.withHeadingsAsBoldParagraphs().withSummariesAsParagraphs()`) with no
glued brace.

The pair is the negative control. A rule that fires on `rr-glued-brace` but not
on `rr-sound-sibling` is discriminating between a broken and a sound resolution
of one conflict, rather than merely reacting to the file.
