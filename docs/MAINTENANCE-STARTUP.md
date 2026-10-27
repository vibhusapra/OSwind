# Automatic maintenance starts with the active library

Automatic retention can remove historical sources and their retained media.
Its scheduler now follows the library's lifecycle:

- A model prepared with `startServices: false` has no maintenance timer.
- A configured startup requests the scheduler; onboarding keeps it paused.
  Dismissing onboarding starts a previously requested scheduler.
- Reopening onboarding pauses the scheduler until it closes.
- Library-switch preparation clears that request and stops the timer. A queued
  automatic callback checks lifecycle state before starting any database work.
- Explicit **Clean up now** remains available. Active automatic cleanup uses
  the library's existing retention and storage policy.

Settings → Data shows when an enabled policy is paused for a quiet-opened
library. **Resume automatic cleanup** starts its five-minute checks. Enabling
the retention toggle uses the same path. This does not call the general
configured-services startup; configured API/capture services stay paused.
Disabling retention keeps historical sources while the active scheduler can
still checkpoint its search cache, as before.

The guard uses main-actor lifecycle state. SQLite admission and pruning run on
the existing utility worker, preserving atomic source/media cleanup and closed
store refusal without adding a synchronous database lock check to the UI path.
Already committed cleanup follows the existing erasure semantics.

The authored regression invokes the same automatic-maintenance entry point as
the timer. Before the fix, quiet preparation, open onboarding and a queued call
after switch preparation all delete the owned historical note: three cases,
four failed assertions. Configured active cleanup and explicit manual cleanup
already pass. The fixture contains no normal user history.

Imported sources keep their original dates. Active retention applies to those
dates, so review the policy before importing an old archive. The Limitless API
import pane makes this relationship explicit.

This lifecycle fix does not audit or recover earlier default-library activity
from the [native QA cleanup incident](../benchmarks/contextual-drafts-native-v1.json).
That preserved database passed a read-only integrity check; no source rows were
selected. Broader quiet-start visual-index/wake behavior and physical power
remain separate qualification work.
