# Source worker lifetime

This component owns the actual quick-note, recap, statistics and storage workers through cancellation, plain Quit, library switching and encrypted-library lock. It also denies several delayed actions from a retired workspace. Audio file import, Ask and the remaining reader/model-setup audit are separate open work.

## Behavior

The main-actor registry tracks each actual detached worker and its actor completion together. A drain closes admission before yielding, cancels both tasks, waits for actual work and its completion, and continues waiting even if its caller is canceled. Exit ownership includes these jobs before they obtain a library reservation. Wipe waits for the registry after retiring the old generation. This is cooperative cancellation, without a force-close or a fixed shutdown deadline.

Quick notes and source-linked recaps cannot launch after retirement, store closure or while the global drain owns admission. A changed privacy policy cancels both actual workers before trying to save settings, so a settings-write failure does not leave those captured-policy workers running unchecked. Import-only experimental PII settings continue to apply to imports; changing them does not revoke an explicit manual note/recap. The existing JSON import worker/drain architecture is preserved with the same retired launch guard.

A source already committed remains committed. Cancellation does not invent a rollback. Retired completions do not publish a source or success; current canceled recap completions explicitly distinguish an already committed save. Normal successful saves may refresh the current workspace. Privacy cancellation remains cooperative: it cannot undo a transaction that has already crossed admission/commit.

Statistics and disk scans now have actual registry ownership. Their completions validate cancellation, library generation and current admission before publishing or scheduling another scan. Forced statistics requests still coalesce. Cancellation or storage failure keeps the last good byte estimate; failure does not mark a partial walk as complete.

The new storage estimate counts logical sizes of regular files. It holds a supported shared media reservation for the whole traversal, opens directories relative to verified descriptors, does not follow symlinks, and checks the root identity before and after. Cancellation, inaccessible entries, path/depth bounds and overflow throw instead of returning a partial successful estimate. Disappearing entries can be skipped during a concurrent walk. The estimate is not an atomic snapshot, allocated APFS space or physical disk usage. The legacy retention/CLI disk counter remains unchanged.

The tested retired entry points are favorite toggles, chat deletion, API startup, search refresh and source opening. Guards also cover related detail watches and recheck library availability after export/import file dialogs. Tests do not operate those dialogs or establish real native UI acceptance. This is not a claim that every public action or reader has completed its lifetime audit.

## Verification

Source `141375c` binds the [1,374-input receipt](../benchmarks/source-work-lifecycle-v1.json). Full debug: **2,131 passed / 111 skipped**. Selected sanitizer: **884 passed / 53 skipped**, no race warning. Selected optimized: **884 passed / 53 skipped**. All **190 mandatory controls** pass in every build. All **30 required package/process stages** pass across 16 retained successful executions and 14 new stages, including **49 owned native APFS/app-session methods without skips**. Full plus native covers **2178 distinct methods**. Independent review verifies every byte of 34 app/ZIP/extracted files, strict ad hoc signatures, three retained migration crash states and 46 unchanged earlier app trees.

Skips include opt-in/child-only fixtures and a visual-admission check requiring an unlocked session and allowed thermal state. None are counted as passes.

Six additional owned encrypted-APFS cases hold actual note, recap, statistics and storage workers before admission, and note/recap workers after real commit. Lock waits with the image mounted until release, normally closes/detaches, and unlock preserves the correct committed source count. Eight ordinary tests use the actual Quit delegate and library switch across all four worker types. No real model-quality, UI/TCC, physical power or bounded shutdown-time claim follows.

The first packaged query-interruption setup refused an unexpected backing-device inventory before any signal trial; normal recovery detached its owned fixture. A single fresh same-code attempt passes with unchanged guards. Its cause remains unknown, the failed log stays retained; 16 successful stages are reused with verified hashes, and the original candidate app remains byte-identical.

The predecessor [PR130 hosted follow-up](../benchmarks/pending-media-scheduler-hosted-v1.json) separately passes both jobs: 2,087 full passes/108 skips, 43 native passes/no skips and three named-clipboard methods. This does not qualify the new source or explain PR128's earlier busy failure.

Original reproductions remain separate: three retired note/recap/JSON-import methods produced seven failed assertions against the published predecessor; two reader methods produced six, showing early drain acknowledgement and late publication/restart; five direct-action methods produced six, showing actual old-library favorite/chat mutations, query/source publication and API start/relabel attempts. The API assertion is not evidence that a listening socket successfully bound. A first session-test fixture supplied settings without the required existing SQLite library; production correctly refused it. Creating an owned library corrected that fixture. The original regression assertions remain required.

Core storage checks exercise an actual traversal-held shared reservation blocking both exclusive admission and store closure, then cancellation releasing it. A root is moved/replaced without canceling the worker: the original descriptor walk must fail final identity validation without visiting the replacement. Other controls cover external symlinks, unreadable directories, pre-entry cancellation, staging buckets and closed stores.

The first native 49-method attempt passed 48 and failed one newly added storage snapshot assertion: independent statistics legitimately completed between its pre-lock snapshot and retirement. The snapshot baseline now starts after cancellation proves retirement. The held-worker, mounted-image, no-late-publication and reopened-source assertions remain intact. The corrected native case passes in isolation. Earlier source-bound software receipts remain separate; the final qualification runs against the corrected test source.

## Remaining work

Audio import still lacks AppModel exit/drain ownership despite Core cancellation propagation. Code inspection also finds Ask needs a retired-launch guard and actual operation ownership; its reproduction/fix is separate work. Detail/PII/search/index/model setup need individual actual-resource audits. Complete personal sync F059, collection epochs, actual providers/two Macs, native TCC/input, sustained capture/physical power and signed/notarized distribution remain open. Native schema 33 and wire formats are unchanged. All 83 feature statuses stay unchanged; no whole-product parity or competitive rank follows.
