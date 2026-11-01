# Native external tools workspace

Status: **work in progress**, based on the qualified manual client. Source builds and37 focused checks pass (11 core connection/source,19 controller,7 application/workspace cases). Actual AppSession departure waits for pending tool work before SQLite close. First renders exposed result visibility and code alignment issues; all12 revised light/dark component renders were inspected after fixes. Result/save visibility and top-left review code are corrected; compact forms scroll and action footers stay visible. Inactive exporter buttons are gray; native interaction remains unverified. Full/sanitizer/release/package qualification and a native workspace PR are still pending. This is not native platform acceptance.

## User flow

1. Open Tools, or Settings → Connect → Open tools workspace. Add up to eight named local stdio connections. Enter an absolute executable, a JSON array of arguments and optional credential variable names. Saving never launches a server.
2. Save credential values separately in Keychain, under a connection-specific account. They are never stored in settings or copied from model-provider accounts. Starting a server can expose filesystem/network access with the Mac account's authority; the isolated working directory and filtered environment are not a sandbox.
3. Review the complete command before discovery. Choose a returned tool, enter a strict JSON argument object, then review the exact command/tool/arguments before running. Tool definitions and read-only annotations remain untrusted claims. No automatic model calls, external writes or retries occur.
4. Inspect the returned text/raw JSON. Save text to memory only when explicitly requested. Import uses the existing collector, current settings snapshot, pattern/optional learned PII handling, source exclusions and media-write admission. The record identifies it as an unverified external result, with command/definition/arguments fingerprints. Arguments, credentials, executable paths and raw/binary result content are omitted.
5. Saved text is searchable and available to Ask; Open saved source uses the normal complete-source viewer. A call has one stable collector key, so a retry cannot silently add duplicate original sources.

The server may access files itself; OSwind does not automatically attach its memory library to requests. URLs, icons and resource links are not fetched. The current transport is local stdio; HTTP/auth and model-driven tools remain open.

## Lifecycle and authority

- Loading settings and opening Tools never read credentials or start a process. Each discovery/call has a fresh review token, invalidated by changed arguments, connection bytes, credentials, privacy, pause, lock, onboarding or library departure. Canonically equivalent Unicode arguments are compared by exact UTF-8 bytes.
- Stop keeps the operation busy until its worker finishes. Late results from cancellation-ignoring fixtures cannot republish into a changed scope. External outcomes can be unknown; no action is automatically resumed.
- Global Pause includes tool-only work. Resume capture never repeats an external call. Sleep/session notifications clear visible result/review/argument/credential drafts; vault/library transitions join actual external work and imports before closing the store.
- Quiet restore clears connection choices. The existing history-wipe behavior retains settings and saved credentials; it stops/clears tool work without silently restarting it.
- Removing a connection explicitly removes only its named credential accounts. Keychain success or no matching entry is required before reporting removal. Failures retain the profile for retry; Keychain and settings are not one transaction, so earlier entries may already have been removed.

## Current evidence and remaining checks

Owned tests cover no launch/read before consent, exact argument review, malformed input, canonical-byte edits, credential namespaces, secret-draft clearing, stale result refusal, worker drain, current-policy source admission, duplicate-save identity, direct source search/open, privacy changes during actual import preparation, global pause and actual AppSession library switching. They use injected credentials/runners; no real user keys or calendars are read.

The debug exporter renders the actual components with authored data and an injected server. It does not establish native mouse/keyboard/VoiceOver behavior, real Keychain access, real third-party account behavior, or physical power. Native full/debug/TSan/optimized/package/API/MCP/archive checks and final source manifests still need completion; earlier compiler and visual failures remain retained.
