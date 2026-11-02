# Native sync in the app — prepared-session ownership

The app now owns a prepared `PersonalSyncSession` across Quit, workspace changes, encrypted lock and local wipe. The app-facing actor exposes progress and pause/stop controls; it has no public constructor and exposes no group key, peer list, wire record or erasure authority. Public enrollment is still unfinished. F059 remains TODO.

`PersonalSyncModel` serializes configuration requests, coalesces obsolete intents and owns the status consumer and shared terminal stop. Retirement closes admission synchronously. The existing AppModel/AppSession departure paths await actual sync work before SQLite close, wipe or vault detach. A canceled drain caller still waits. Local wipe leaves the old session terminal; reconnection requires a freshly prepared session and its applicable authority checks.

Status uses a bounded push stream, without UI polling or a forwarding worker. Canceling one observer does not cancel other observers or the service. Idle identical states do not invalidate the UI. The Connect section displays native status and network pause/resume for a prepared session. Public setup and enrollment still require their own workflow.

Network pause joins provider work while local preparation continues. Processing suspension joins the whole tick for onboarding/sleep. Resume honors the existing connection's intent; it does not start capture, audio or the local API. Concurrent reconfiguration, suspension and terminal stops retain actual worker ownership. Overlapping stops share a promise that joins both the loop and its metadata close. The private inbox directory handle closes before the owner can unmount its encrypted vault.

Tests hold actual native SQL and positively observe the sync tick's shared media lease with an exclusive-probe refusal. Quit, switch, canceled drains and wipe must wait for that actual tick. An owned APFS lock test keeps the image attached while sync is blocked, then checks SQLite close, image detach and source preservation after reopening. The fixtures use the actual service workers and production policy/media adapters.

Remaining: public create/join, device membership/signatures/capabilities, key recovery/revocation and rollback authority; received group-erase producer-drain/application/renewal UI; cold offline binding, raw-queue overflow/reconciliation, assigned denied immutable operations, storage pressure, resumable large graphs, selective spool GC and backup semantics; physical provider/two-Mac, live UX, sustained power and notarized distribution. Prepared-session ownership is not complete public sync or a whole-product parity/ranking result.

## Source-bound verification

Source `71c4c04` binds [all 1,455 tracked inputs](../benchmarks/sync-app-owner-inputs-v1.json) and the [qualification receipt](../benchmarks/sync-app-owner-v1.json). Full debug: **2,326 passed / 126 skipped**. Selected Thread Sanitizer: **1,266 passed / 72 skipped**; optimized: **1,266 passed / 72 skipped**. All **485 required regular methods**, including **11 new owner/session cases**, and **19 additional owner-qualified backend controls** pass in each build, with no race warning. The five frozen-client compatibility methods pass in the original broad runners with both pinned executable paths supplied.

The native stage passes **63 methods without skips**: 62 inherited native cases and the actual sync-held encrypted lock case. An independent post-suite `hdiutil info -plist` observation finds no attached images with the owned sync fixture prefix; unrelated image paths are not retained. Three fresh immutable readers inspect reopened-library fixtures across the software builds: all 13 native kinds, 21 exact wire bodies, native/historical-original citation joins, cursor 21, one completed answer binding and no receiver echo.

These results qualify source code and owned APFS fixtures. They include no new packaged app/signing inspection, live public pairing, actual two-Mac/provider acceptance, physical energy measurement, notarized distribution, whole-product parity or ranking. The earlier source-bound receipts and PR136's causally unresolved missing-vault-session failure remain separate.

## Previous published-head CI

[Completed hosted CI at `f6dd459`](../benchmarks/sync-library-service-hosted-f6dd-v1.json) passes both jobs: full **2,311 / 129 skips**, native **62 / no skips** and named clipboard **3 / no skips**. All 81 native-job steps succeed and the actual merge checkout tree equals the published head. This qualifies the preceding `dd68dfa` runtime, not the app-owner source above. The unchanged missing-image case passes here; PR136's separate missing-vault-session failure remains causally unresolved.
