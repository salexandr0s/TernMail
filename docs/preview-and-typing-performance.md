# Attachment preview and draft typing performance

This pass improves the time to the chosen attachment's preview and reduces document conversion during typing in large formatted drafts.

## Attachment previews

The attachment library downloads the chosen file first and presents it as soon as that download completes. Remaining selected files prepare one at a time and join Quick Look in their original list order. Adding a file does not assign the selection again, so navigation stays with the file the user chose.

The selected-file download releases command busy state when the preview appears. Secondary preparation has its own request identity and cancellation lifetime. Closing the preview, hiding its destination, changing account access, replacing an account runtime, canceling the caller or starting another preview rejects stale publication. A failed chosen-file download retains the original selection for Retry; secondary failures are skipped without replacing a newer command's error or retry state.

Received-file downloads query current preview protection immediately before cache pruning. The attachment library includes its current selected URL, and both application download entry points honor the existing active-preview registry. Open preview files and the incoming file survive pruning; ordinary cached files remain subject to the existing eviction policy. Closing a preview makes its file eligible for a later prune.

## Draft typing

The editor keeps a projection of converted paragraphs and their UTF-16 ranges. Each processed text-storage edit reconverts the affected paragraphs and adjacent boundaries. Unchanged paragraphs keep their existing styled runs. Invalid range assumptions fall back to full conversion.

The projection preserves the full converter's handling of paragraph separators, explicit trailing empty blocks, list markers, links, inline images and adjacent styled runs. Undo, redo, paste, native Markdown insertion, marked-text composition and external document replacements use the same synchronous publication path. Loading a document does not publish an edit.

The draft binding updates during processed storage edits, including marked text, so immediate save, send and close actions read the current body. Placeholder visibility uses an exact equivalent of `plainText().isEmpty` without constructing the whole plain-text output. Whitespace, multiple empty paragraphs, empty list markers, image references and links retain their previous behavior.

Paragraph-range shifts, value-array copying and downstream model equality can still take work proportional to paragraph count. A single enormous paragraph still requires converting that paragraph. The change bounds attributed-text conversion; it does not make every part of editing constant time.

## Controlled measurements

The optimized native-editor probe uses actual `ComposeTextView.insertText`, normalization, a retained binding value, body equality and feedback equality. Each case has eight warmups and 60 measured edits. Both versions disable spell checking, grammar checking and automatic link detection. The editor sources compile with Swift `-O`; supporting Core objects come from the existing Debug build.

| Formatted draft | Edit position | Before median | After median |
| --- | --- | ---: | ---: |
| 500 paragraphs, 5,000 styled runs | Middle | 35.879 ms | 0.618 ms |
| 500 paragraphs, 5,000 styled runs | End | 43.153 ms | 0.585 ms |
| 2,000 paragraphs, 20,000 styled runs | Middle | 150.681 ms | 1.006 ms |
| 2,000 paragraphs, 20,000 styled runs | End | 170.921 ms | 0.965 ms |

Final documents matched the full converter. These are controlled editor-pipeline timings; they exclude a complete application window, persistence, spell checking, GPU presentation and end-to-end keystroke latency. Raw timing samples were not retained. Captured summaries, fixture details, source snapshots and commands are in `build/Verification/preview-typing/editor/`.

Gated download regressions verify that the chosen preview is visible while other downloads remain blocked. Verification passed: 74 app tests, 322 Core tests and one separately enabled native Quick Look acceptance test. That test verified selected-first presentation and navigation, then used actual computer input on the visible close control and checked that a late download did not reopen the panel. Real model checks saved, sent and closed immediately after native typing and retained the complete edited body.

Tests ran in an isolated snapshot based on `43db196`; a subsequent Debug integration build passed against `9c64e18` plus these changes. The checks use synthetic accounts, messages and files. Evidence is under `build/Verification/preview-typing/`; the installed Release app was not replaced.
