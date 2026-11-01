# Optional clipboard context

Status: **work in progress; F082 remains TODO**. The policy/settings foundation has nine passing owned tests. Automatic observation, native adapter, lifecycle/import wiring and UI are not implemented yet. No personal pasteboard was read and no permission was changed.

Collection will default off. Starting or resuming must baseline the current change count and ignore existing contents; only new eligible plain-text changes can be admitted. Quiet restore resets the choice to off. Global pause, sleep/lock, settings changes, erasure and library departure must invalidate pending observations. Current-policy admission and active imports must join before SQLite closes or the app exits.

The policy admits one bounded UTF-8 plain-text item, rejects known confidential/transient/generated/restored/Handoff/file/image/PDF markers, and always drops recognized secret patterns. Both fresh foreground observations must agree, be nonsecure and pass app/title/domain rules. Browser context without a usable URL refuses. A mismatched or explicitly unknown source marker refuses; a matching marker does not prove origin. Saved text labels foreground app/window as observed context, never verified origin. Event identity is stable, and the deduplication state needs only a32-byte digest.

macOS15.4+ exposes per-app pasteboard access behavior. Background polling must respect it and never repeatedly prompt or change System Settings. Any permission request belongs to an explicit user action. Source: [Apple API](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum) and the installed SDK NSPasteboard.h, checked November1,2026.

The marker registry treats source as informational and defines confidentiality/transience signals. These are useful refusals, not complete protection or authenticated attribution. Source: [NSPasteboard marker specification](https://nspasteboard.org/), checked November1,2026.

Native reads should stay off the main thread and use one process-wide worker. A stuck provider must not create a thread per poll or hold library descriptors. The waiter needs a cancellation/deadline path that can discard a late response. AppKit may allocate provider data before its size can be rejected; the saved64KiB bound is not a provider-allocation bound. This limitation must remain explicit until an independently verified isolation strategy improves it.

Remaining work: native/injected IO, polling and power/idle backoff, baseline/no-backfill/dedup, current snapshot plus optional learned PII import, settings/status UI and global pause/quit wiring, actual owned named-pasteboard checks, focused/full/sanitizer/optimized/package/quiet-restore qualification, and a reviewable PR stacked on117. The Mac is currently locked; do not retry or bypass the refused native UI path.
