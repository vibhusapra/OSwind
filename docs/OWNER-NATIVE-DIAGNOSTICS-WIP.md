# Owned owner-app vault diagnostics

PR165's original hosted native job failed the final detach assertion in `testNativeSavedApprovalSurvivesDetachAndUnlockReturnsOnlyRecovery`. Its benchmark job passed. The full failed log and uploaded artifact are retained locally. The artifact's digest matches CI, but its traces belong to the earlier core-native step; the failed owner-app step had no native observer. The cause remains unproved.

The app session now accepts an internal vault-construction dependency, whose default still constructs the ordinary public `LibraryVault`. Owned owner-addition fixtures supply the existing internal native-driver observer through that dependency, covering the application's real lock, unlock and status operations. No global observer or production environment switch is added.

Fixtures retain bounded native summaries, labelled operation phases and this process's handles belonging to the owned fixture or mounted volume. Inventory stdout is omitted. The exporter rejects generated credentials and redacts owned paths before writing. Successful teardown saves diagnostics before deleting the fixture; exceptional teardown preserves its report. CI exports these separately as `owned-owner-addition-vault`, including on failure. The final-detach assertion and its existing wait remain unchanged. Observation can perturb timing; a successful observed run does not explain the original failure.

Local development evidence before porting to the PR branch:

- An initial diagnostic assertion referenced the wrong result field and failed compilation. Its original source and log are retained; no runtime test was claimed.
- Corrected owner-app selection: **29 passed, one explicit component-render skip, zero failures**. Three real owned encrypted APFS/generated login-Keychain fixtures produced 176 native calls, all status zero. The saved-approval recovery's application final detach is present in its trace, status zero; its pre-mutation snapshot has zero mounted-volume handles.
- On the same retained binary, without rebuilding: **108 passed, five explicit skips, zero failures** across vault sessions, source-work sessions, peer membership and recording models. All pinned inputs and previously retained actual engines remained unchanged. These selections do not complete the whole suite or hosted qualification.

Actual engines, original failed compilation, source snapshots, input hashes, trace review and logs remain under `.artifacts/recording-session-links-v1/`. A current-head hosted result remains a separate gate; the old failure is not waived or described as fixed.
