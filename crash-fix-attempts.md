# Crash Fix Attempts

Context: after commit `9ed5a21be10b7affe5319998d9a80a514466dd41` the editor started hanging/crashing after Enter and later when pasting a large markdown document such as `/Users/mishamyrt/Git/aurum/backend_geodock/refactor.md`.

The recurring crash stack for the paste case stays essentially unchanged:

```text
lookUpImpOrForward
_objc_msgSend_uncached
swift_getObjectType
swift_task_isMainExecutorImpl
swift::SerialExecutorRef::isMainExecutor()
swift_task_isCurrentExecutorWithFlagsImpl
_checkExpectedExecutor
-[NSTextView drawRect:]
...
NSViewBackingLayer display
CA::Transaction::commit()
```

## Attempts

1. Avoid carrying heading paragraph style through Enter.

   Change: in `MarkdownEditorView.updateTypingAttributesAtSelection`, heading paragraph style is no longer applied when the selection is at the end boundary of a heading span.

   Result: did not fix the crash.

2. Cancel deferred styling on user text changes.

   Change: `textDidChange` cancels `deferredStyleTask` before scheduling new work.

   Result: did not fix the crash by itself.

3. Remove synchronous attribute mutation from `textDidChange`.

   Change: removed `synchronizeStylesAfterTextChange()` path that called `applyStyleRanges()` directly from `textDidChange`.

   Result: fixed the Enter crash, but reintroduced style artifacts while typing because style span ranges were not updated until parse results arrived.

4. Update style ranges after edits without applying attributes.

   Change: `textDidChange` now updates `currentStyleSpans/currentStyleSource` without calling `beginEditing/endEditing` or mutating text attributes.

   Result: typing artifacts mostly disappeared and Enter remained stable, but large paste still crashed with the same `NSTextView.drawRect` / executor-check stack.

5. Capture edit deltas via `NSTextStorageDelegate`.

   Change: `MarkdownEditorView` records `editedRange` and `changeInLength`, and `MarkdownStyleRangeDiffer.translatedSpansAfterEdit` translates spans without diffing whole old/current source strings.

   Result: reduced main-thread work for edits and preserved typing behavior, but large paste still crashed with the same stack.

6. Expand spans for insertion inside an existing span.

   Change: pure insertion inside a style span expands that span instead of dropping it.

   Result: improved styling responsiveness while typing inside bold/headings, but did not affect the paste crash.

7. Remove class-level `@MainActor` from AppKit subclasses.

   Change: removed class-level `@MainActor` from `MarkdownTextView`, `EditorClipView`, and later `MarkdownEditorView`.

   Result: build required several conformance adjustments, but the large paste crash remained unchanged.

8. Remove main-actor command delegate existential from `MarkdownTextView`.

   Change: `MarkdownTextViewCommandDelegate` is no longer `@MainActor`; `MarkdownEditorView` conformance was marked `@preconcurrency`.

   Result: did not fix the paste crash.

9. Import AppKit as preconcurrency in editor subclass files.

   Change: `@preconcurrency import AppKit` in `MarkdownTextView.swift`, `MarkdownEditorView.swift`, and `EditorClipView.swift`.

   Result: did not fix the paste crash.

10. Disable dynamic actor isolation checks for the executable target.

    Change: added Swift compiler unsafe flag `-disable-dynamic-actor-isolation` in `Package.swift` for the `Markwasnice` executable target.

    Result: build/tests passed, but user reported the same paste crash still happened.

11. Remove manual NSTextView frame sizing and AppKit subclass overrides.

    Change:
    - Switched `NSTextView` to `isVerticallyResizable = true` and removed `updateTextDocumentSize()`.
    - Moved bottom padding to `scrollView.contentInsets.bottom` and top chrome padding to `textView.textContentInsets.top`.
    - Made `applyParsedStyles` fully deferred (50 ms) so paste doesn't trigger synchronous styling/layout.
    - Removed `mouseMoved`, `mouseEntered`, `cursorUpdate`, and `resetCursorRects` overrides from `MarkdownTextView`.
    - Deleted `EditorClipView` and switched back to a plain `NSClipView`.
    - Added defensive range guards in `MarkdownCodeBackgroundLayoutManager`.

    Result: app launched and ran stably; unit tests passed. However, user reported the large paste crash still occurs, and large documents now crash on open as well. The new crash stack still originates in `NSViewBackingLayer display` -> `NSTextView drawRect:` with AppKit's `_crashOnException:` on top, indicating the exception is now caught and re-raised by AppKit during layer display. The Swift concurrency executor-check frames are no longer visible, suggesting the previous executor-check symptom was a side effect rather than the root cause. Cursor exclusion over the top chrome regressed.

## Current Status

- Enter crash appears fixed after removing synchronous attribute mutation from `textDidChange`.
- Typing style artifacts appear fixed/improved after updating style ranges without applying attributes and using edit-based translation.
- Large paste crash remains unresolved.
- The paste crash stack is still inside AppKit's `-[NSTextView drawRect:]` with Swift concurrency executor-check frames, despite removing obvious actor isolation from the app's `NSTextView` subclass/delegates and disabling dynamic actor isolation for the target.

## Likely Remaining Directions

1. Verify whether the running binary actually contains the `-disable-dynamic-actor-isolation` build output, including app bundle builds via `make`, not only `swift run/build`.
2. Temporarily replace `MarkdownTextView` subclass with a plain `NSTextView` plus external delegates/closures to confirm whether any Swift subclass metadata is triggering the draw-time check.
3. Temporarily disable layer-backed drawing for the SwiftUI/AppKit bridge/editor subtree, since the stack runs through `NSViewBackingLayer display`.
4. Temporarily disable `BackdropBlurOverlay`/`CABackdropLayer` and top overlay, because it forces repeated redraw of the editor underneath during large visual updates.
5. Add a reproducible paste stress path or UI automation script so this can be tested locally rather than through manual crash reports.
