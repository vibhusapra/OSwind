# Scheduled routines

Routines turn a saved prompt and source window into a citation-backed conversation. Create a day recap, standup or action review in **Routines**. The provider/model are copied from current model settings and saved with the routine; **Use current model settings** updates that selection. Start with Evidence only, Apple Intelligence or local Ollama. No model download, capture or automatic schedule starts merely by creating a routine.

Enable **Run schedules while OSwind is open** to execute enabled definitions. **Run now** also works while automatic schedules or an individual schedule are paused. Results appear under Recent runs and in Ask conversation history; **Open result** preserves source cards, warnings, follow-ups and existing Markdown export. The normal recap path samples up to 24 timeline sources with bounded excerpts (fewer for Apple Intelligence). Its coverage warning remains visible; this is not an exhaustive analysis of every recorded moment.

## Scheduling and recovery

Choose either a time/weekday calendar schedule or a fixed elapsed-minute interval (one minute to one week). Calendar schedules save an IANA time zone. A nonexistent spring-forward time moves to the next valid time; a repeated fall-back time runs on its first occurrence. Intervals align to fixed UTC epoch-minute boundaries and do not duplicate a slot during a time-zone/DST change. Source windows are Today so far, Yesterday, Last hour, Last 24 hours or Last 7 days, optionally scoped by application, source kind and tag. Yesterday follows calendar-day boundaries; elapsed-hour windows stay fixed across DST.

The app polls every 30 seconds with timer tolerance and checks again on wake. It does not wake the Mac or install a daemon. OSwind must be open, optionally through its existing user-selected login item. On restart/wake it coalesces missed occurrences into the latest slot. A latest slot older than 24 hours is recorded as skipped; intervening slots are not replayed. The next due occurrence advances atomically with the durable run claim. Failures are consumed rather than retried automatically. A run still unfinished after 15 minutes becomes interrupted when another claim is attempted. A late result cannot publish after that interruption.

Only one active claim is admitted per library. Atomic SQLite writer transactions and a unique scheduled-slot index prevent competing app/CLI processes from saving duplicate results for the same occurrence. Editing a definition increments its revision; cancellation and a publication-time revision check discard obsolete results. A crash can occur after a model request and before its result is saved: this is not an exactly-once guarantee for an external inference service.

## Context and data controls

Remote providers require permission both on the routine and in current Models settings, as well as the saved provider configuration. No API keys are stored in routine definitions or run rows. Credentials use the existing provider/Keychain path. Scheduled outputs have the same evidence-revision checks and deletion behavior as ordinary answers. Removing source evidence erases dependent generated text; history then shows that its result was removed. Deleting a routine removes its run history and saved result conversations. Delete everything also clears all definitions and runs. Erasure does not delete separately saved exports or backups.

Complete backups retain definitions, revisions, next occurrences, history and cited conversations. Restore uses trusted schema reconstruction and validation, marks archived in-flight jobs interrupted, and keeps automatic scheduling off. JSON memory interchange continues to cover memory records rather than routines; use a complete backup for routine portability. Source schema is now 13. Older writers refuse the newer library; the independently pinned schema-11 component soak is never opened with this binary.

## CLI

```bash
oswindctl --data /path/to/library routine template > /path/to/routine.json
# Edit the definition, including prompt, schedule and provider/model.
oswindctl --data /path/to/library routine put /path/to/routine.json
oswindctl --data /path/to/library routine list
oswindctl --data /path/to/library routine preview ROUTINE_ID
oswindctl --data /path/to/library routine scheduler on
oswindctl --data /path/to/library routine tick
oswindctl --data /path/to/library routine run ROUTINE_ID
oswindctl --data /path/to/library routine history ROUTINE_ID
oswindctl --data /path/to/library routine delete ROUTINE_ID
```

Updating an existing definition requires `put FILE --revision N`; conflicting edits are preserved. `tick` processes at most one due occurrence and does not create a background service. `--at ISO8601` supplies an explicit eligibility/scope clock for replayable tests and previews; production normally uses the actual clock. Avoid interpreting explicit-clock fixtures as a physical sleep/wake or timing measurement.

## Verification scope

Core contracts cover DST, intervals, time windows, conflicting revisions, two concurrent database connections, stale claims, bounded catch-up, cancellation, evidence changes, remote gates, erasure and backup restoration. Native controller tests exercise a real short Timer, enable/pause/stop, overlapping actions and an automatically claimed run edited during generation. `scripts/routines-smoke.py` exercises real isolated CLI processes, eight-way contention, evidence-backed results, backup/restore and erasure. Its optional `--chat-model` runs the existing local Ollama server on a small authored ownership/deadline fixture, without altering or downloading models.

Synthetic light/dark native views are rendered independently of physical controls. Mouse/keyboard/VoiceOver acceptance, real system sleep/wake, long-running multi-process faults and broad recap quality remain open. Arbitrary cron expressions, multi-step tool actions and external notification delivery are not implemented. This milestone does not establish full feature parity, daily power budgets or competitor superiority.
