# Review a memory-backed draft, then insert it

OSwind's Ask view already offers local evidence, Apple on-device generation,
Ollama, and explicitly configured BYOK adapters. **Review draft…** turns any
answer into an editable, ephemeral copy. It preserves citation markers and
keeps the original answer and its source cards available for inspection.
It does not start a second generation request or silently change providers.

1. Focus the intended text field in another app, with the desired caret or
   selection, and press **⇧⌘Space**. OSwind checks that field before opening.
2. Ask a question or use **Draft a standup**, then choose **Review draft…**.
   Edit the result and check its evidence. The target app, window, and selection
   length are shown. A captured destination expires after five minutes.
3. Choose **Insert into [app]**. OSwind activates that app, allows 300 ms for
   activation, then checks the destination again and makes one selected-text
   write. There is no automatic retry. Inspect the result before saving or
   sending it. **Copy draft** is available without a selected destination.

If a draft is already open, focusing another app and pressing ⇧⌘Space refreshes
its destination without replacing the draft. Ordinary app opening, menu-bar
opening and Cmd-K do not inspect another app's text field.

## Scope and guards

- Accessibility permission is required for insertion. No permission prompt or
  settings change is issued by this feature. Screen Recording is not required.
- Only fields reporting `AXTextField` or `AXTextArea` with a settable
  `AXSelectedText` attribute qualify. No full field value is read or replaced.
  Password/secure subroles in the complete field-to-window ancestor chain,
  secure event input, locked sessions, unknown or cyclic ancestry, wrong
  process identities and incomplete metadata cause refusal.
- The destination binds a running application, launch identity, exact AX window
  and element, window title, role, character count, UTF-16 selection range and
  SHA-256 of the selected text. The selected text is read only after role,
  ancestor, privacy and range checks; its raw text is not retained. Each native
  observation has a 500 ms cooperative budget with per-message timeouts up to
  40 ms and at most 16 ancestor elements.
- Current app/title exclusions apply at capture and insertion. Browser
  destinations are refused even when browser-context policy is disabled:
  URL/private-window qualification is still open. Known terminal and IDE
  bundles are refused because command panes require separate safety work.
  This is not a universal classifier for every shell or embedded browser.
- Immediately before writing, OSwind rechecks frontmost PID and focused AX
  field/window. It never posts keyboard events, presses Send/Enter, performs a
  full-value replacement, or uses the clipboard as an insertion fallback.
  A failed AX acknowledgement can hide a completed write, so the destination
  is consumed and an explicit fresh shortcut is required for another attempt.
- Drafts allow up to 64 KiB of UTF-8 text. NUL, C0/C1 control characters other
  than tab, CR and LF are refused. These checks apply to both Copy and Insert.
- Copy and Insert first recheck each original source's current evidence hash
  and exclusions in the selected library. Missing, changed or newly excluded
  evidence refuses handoff. This is a preflight, not an atomic transaction
  spanning the library and another app. Concurrent same-length edits outside
  the selected span and focus changes inside the final cross-process IPC
  window cannot be ruled out by these metadata checks.
- Library switching, locking, history-erasure preparation, successful pruning,
  source deletion through OSwind, privacy changes and session suspension clear
  the draft and revoke pending handoffs. Explicit Copy replaces the user's
  clipboard; successful insertion leaves the clipboard untouched. Drafts are
  not saved as a new database record. Saved original chats retain their
  established storage/erasure rules.

## Qualification boundary

`ContextualDraftTests` exercises admission, bounded text, selected-span and
metadata changes, expiry, evidence revision/privacy checks with a real owned
store, single-attempt behavior, uncertain acknowledgements, cancellation,
recapture, Copy and library lifecycle clearing. It uses an injected transport
and does **not** write into live desktop applications.

A synthetic SwiftUI component render checks layout only. Live signed-app
TextEdit insertion, selected replacement, read-only targets, protected fields,
permission denial/recovery, OS lock during activation, global shortcut,
VoiceOver and native undo remain acceptance gates. Do not call this feature
universally supported or release-qualified on the basis of model tests.

The OSpr insertion transport was inspected as a behavioral reference. No OSpr
source was copied; the implementation here uses one AX transport and explicit
Copy, with no clipboard or keyboard-event insertion fallback.

Frozen-source qualification is recorded in
[the contract report](../benchmarks/contextual-drafts-v1.json):891 full-suite
passes, one physical-audio skip,105 focused TSan passes and14 ordered operations.
The [light](../assets/contextual-draft-light.png) and
[dark](../assets/contextual-draft-dark.png) images are authored sample component
renders, not live editor delivery evidence.
