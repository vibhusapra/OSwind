# Desktop shortcut setup

OSwind asks macOS to register **⇧⌘Space** at ordinary app launch. It opens
search and, when supported, selects the currently focused native field as a
draft destination before OSwind activates. Dock/menu opening and in-app Cmd-K
open search without selecting another application's field.

Settings → Capture shows registration status first. When registration fails,
the workspace shows **Review shortcut**, which opens that section. A reported
key conflict gets a distinct message; other failures retain a stage/status
diagnostic. **Retry shortcut** releases the previous owned resources before
attempting a new registration. Dock, menu bar and explicit draft Copy remain
available while the shortcut is unavailable.

“Registered with macOS” confirms the native API accepted the handler and key.
It does not establish that a particular keyboard event reached OSwind, that
Accessibility access is granted, or that an editor supports guarded insertion.
Test destination capture from an editable field; see [draft support and
limits](CONTEXTUAL-DRAFTS.md). The registration mode/key combination is unchanged.

The handler is installed before the key. Only successful native calls transfer
handle ownership. Error out-parameters are discarded; cleanup never treats
them as owned registrations. Failed cleanup retains known resources for retry
and prevents duplicate installation. Each attempt has a fresh event ID, so a
queued event from an old registration cannot select a later destination.
Signature/type/size checks precede routing. Quit revokes routing before cleanup.

Component-only DEBUG renders return before registration. Unit tests inject
native calls and do not register a real hotkey, emit keyboard events, change
focus or read another application. Native keyboard delivery, conflicts with
other installed tools and end-to-end editor insertion require separate live
acceptance; earlier draft observations remain partial.
