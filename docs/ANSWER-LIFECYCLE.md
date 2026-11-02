# Answer lifetime and atomic conversation saving

Ask now owns its actual answer worker, conversation admission and actor completion through cancellation, wipe, plain Quit, library switching and encrypted-library locking. A queued call from a retired view can no longer start generation or save into its old library.

## Behavior

The answer operation joins the existing library worker registry. Drain closes launch admission before yielding, cancels actual work, and waits even if its caller is canceled. Before saving, an actor hop checks cancellation and library generation/availability. Privacy and answer-model configuration changes revoke captured work before attempting to persist settings. This is cooperative cancellation; it has no forced close or fixed completion deadline.

First-conversation creation and turn admission now share one transaction. Invalid, erased or changed evidence leaves neither a new empty conversation nor a turn. A caller's outer transaction retains ownership through a savepoint. An actual insert cancellation rolls the new conversation back; a turn that already committed remains committed.

Current cancellation after commit shows a generic saved-before-cancellation status and an explicit **Review saved answer** action. The answer is loaded only when the user chooses that action in the active library. Retired completions publish no answer, conversation selection, success status or saved identifier. The waiting/canceled status remains separate from an ordinary generation error. Native clicking and visual acceptance of this small UI addition remain open.

## Source-bound verification

Source `766cd3a` binds the [1,382-input receipt](../benchmarks/answer-lifecycle-v1.json). Full debug: **2,150 passes / 113 explicit skips**. Selected sanitizer and optimized: **919 passes / 55 skips each**, with no sanitizer race warning. All **225 mandatory controls** pass in every build; their source method definitions are unique. All **30 package/process stages** pass fresh, including **51 owned native/app-session methods without skips**. Full plus native covers **2,199 distinct methods**.

Independent review verifies every byte of the 34-file app/ZIP/extraction, strict ad hoc signatures, three retained migration crash states and 49 earlier app trees. That protection includes 48 previously qualified app/extraction trees and the retained failed query-setup candidate; preserving it does not turn its failed attempt into a pass.

Original evidence remains separate. One retired Ask method produced four failed assertions against published predecessor `485d811`: generation launched, a real old-library conversation persisted, and selection/evidence were published. A later changed-evidence test correctly rejected the turn but exposed a new empty conversation from separate creation/admission. The atomic transaction fixes that assertion. All original regression assertions remain required.

The first full run at `be3f50a` passed all 208 then-required controls but failed an existing voice fixture's aggregate exit-idle assertion after a short fake dictation. Its exact active job at that instant was not traced. The fixture did not settle independently owned startup readers. It now waits for those readers before the unchanged dictation assertions; a new held-reader control verifies that completed dictation still retains exit ownership until the actual reader returns. All 17 voice methods are now mandatory in all three builds. Prior sanitizer/optimized passes remain bound to their earlier source.

Two new encrypted-APFS tests hold the actual answer worker before conversation admission and after a real committed turn. Lock keeps the image mounted until release, then closes/detaches normally. Unlock preserves the expected conversation count and original source. Ordinary tests use the real Quit delegate and library switching. Core controls cover outer rollback, rejected nested admission, preserved committed follow-up history and cancellation inside the actual SQLite turn insert. Authored evidence-only responses do not measure model quality.

The predecessor [PR131 hosted follow-up](../benchmarks/source-work-lifecycle-hosted-v1.json) separately passes both jobs: 2,128 full passes / 114 skips, 49 native passes / no skips, and three named-clipboard methods. The published Ask head now also passes hosted CI, as recorded below. Earlier native inventory and busy-detach refusals remain causally unresolved.

## Remaining work

[Audio-file import ownership and off-thread admission](AUDIO-IMPORT-LIFECYCLE.md) now have a separate later source-bound receipt; they are not part of this Ask source. Detail/PII/search/index/model setup need individual lifetime audits. Actual provider and server-side cancellation, natural dialogue accuracy, native GUI/TCC/input, sustained power, complete personal sync F059 and collection epochs, actual providers/two Macs and notarized distribution remain open. Native schema 33 and wire formats are unchanged. All 83 feature statuses stay unchanged; no product parity or competitive rank follows.

## Hosted follow-up

Published predecessor head `5a098c7` separately passes both [hosted jobs](https://github.com/vibhusapra/OSwind/actions/runs/41386628144): **2,147 full passes / 116 skips**, **51 native passes / no skips**, and three named-clipboard methods. The [hosted receipt](../benchmarks/answer-lifecycle-hosted-v1.json) binds the checkout head and complete native log; the strict diagnostic ZIP review checks ten valid JSON files. Hosted/local counts remain separate. This does not qualify the later audio source or explain earlier native refusals.
