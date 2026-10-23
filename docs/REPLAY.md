# Sampled visual replay

OSwind can retain focused-window visual history as short HEVC clips, with frame times, local Vision OCR and accessibility text. Choose **Settings → Capture → Visual memory → Replay**, then use the existing Resume action. Snapshots remain the default. No capture starts as part of installation or a model download.

Light samples at 1280 px / 5 seconds; Balanced at 1920 px / 1 second; Detailed at 2560 px / 0.5 second. Low Power Mode and serious/critical thermal pressure each multiply the interval by three. Sleep, lock, excluded contexts and two minutes of inactivity suspend automatic capture. ScreenCaptureKit emits changed complete frames; unchanged frames and dropped frames are omitted. OCR uses one consumer and a newest-one-frame buffer, so processing cannot create an unbounded pixel queue. This is sampled history, not a recording of every transition or 60 fps video.

The stream binds an unambiguous focused window using its owner and focused accessibility window bounds/title. An explicit focus mismatch is rejected even if only one other window is shareable; the same rule applies to snapshots. It rechecks privacy/context before and after OCR. Allowed pixels enter an AVFoundation encoder with the VideoToolbox hardware requirement enabled. Encoding readiness has a two-second limit; finalization has a ten-second timeout. Failures surface in capture status and back off before retrying. No silent software encoder fallback runs during normal capture.

Force quit or a crash can lose an uncommitted clip; sustained fault recovery remains an acceptance gate.

A clip is finalized on a source/window change, a timing gap or size bound, periodically around five seconds, and when paused. Light/low-power sampling can produce longer clip intervals, and busy processing can delay visibility. Every committed clip owns its video and thumbnail; there are no shared video files spanning independently deleted records. Secret matching suppresses raw retention and clears OCR boxes, preserving sanitized text only. Existing app/domain/title/secure-field rules apply before pixels reach disk. Pattern-based secret and browser-context checks remain best effort. Turning off retained visuals stores extracted text without screenshots or replay video.

Settings changes, library switches and Delete everything invalidate a publication barrier shared with finalizing chunks. The barrier covers media copies and database insertion, preventing a late encoder callback from recreating erased evidence. Pause normally preserves already admitted evidence. Database schema 12 prevents older writers opening a replay library; the schema-11 reliability trial uses its separate, pinned library.

Open a REPLAY source to play/pause, scrub, select an OCR frame time or show the current frame's boxes. Search and answer passages select their matching frame when opened. Retrieved answer evidence adds clip-relative frame times over literal source ranges. Those times are annotations, not proof that the text remained visible between samples. Full JSON exports retain timed text but strip media paths on import; complete library backups include and validate video files, thumbnails and source records. Retention, source deletion and Delete everything remove owned replay media.

## Reproduce component and live checks

```bash
swift test --filter 'VisualRecordingTests|VideoReplayTests'
swift build -c release
.build/release/oswindctl probe-visual-replay --output /absolute/path/to/new-generated-probe
# Explicit software H264 fixture path for CI/VMs:
.build/release/oswindctl probe-visual-replay --output /absolute/path/to/new-software-probe --software
# Explicit bounded device capture; existing permissions, unlocked session:
.build/release/oswindctl --data /absolute/path/to/isolated-library \
  capture-replay --seconds 12 --app-bundle org.example.your-synthetic-fixture
```

The generated probe uses only its own desktop-like pixels, real Vision OCR, the actual encoder and every-frame AVFoundation decode. It checks both authored ownership phrases and a strict unique frame token in the original and decoded OCR, so a wrong-frame seek cannot pass on dimensions alone. It compares retained video plus thumbnail bytes against JPEGs of the same pixels at quality 0.75; it excludes database/metadata bytes. It refuses an existing output directory and preserves failed output for diagnosis. A bounded live command fails if it saves no evidence; it does not prompt for permissions or switch to another application if the chosen target is absent.

On Apple M5 Max/macOS 26.6.2, the initial 12-frame 1280×720 probe preserved all OCR checks and decoded all frames. HEVC used 59,969 bytes plus 31,236 thumbnail bytes, versus 572,784 JPEG bytes: ratio 0.159. This small static synthetic fixture is not a daily storage, energy or competitor comparison. A separate 12-second ScreenCaptureKit run against an isolated changing native window saved 12 frames in four HEVC clips. Native app interaction opened the saved source, sought a frame, advanced playback and enabled timed OCR boxes. The latest three packaged release trials also preserve every authored original/decoded ownership phrase and unique frame token. The original live capture/player observations were pinned to parent `dc9abf8`. A subsequent strict-selector retest on `cddb6bf` captured 12 frames in four 1920×1290 HEVC clips with zero errors. Every stored frame decoded with the exact same frame number and both authored ownership phrases. Native search for Frame 21 opened visible Frame 21 at its sampled time; the frame-zero button sought visible Frame 19, and Play advanced the clock. This exposed an oversized excerpt ahead of the player and letterboxed OCR boxes mapped to the wrong width. Code `32ce579` puts replay first and maps boxes to the actual aspect-fit image; 363 tests pass with five opt-in skips, including pillarbox/letterbox geometry and AVPlayer completion/restart. Its signed installed package passes replay CLI/HTTP/MCP/backup/erase checks. Final corrected native alignment and play/pause/end/restart acceptance remain pending because the Mac locked before reopening. See [current scoped evidence](../benchmarks/visual-replay-native-v2.json). Logs/screenshots remain under the local artifacts directory; [public benchmark summaries](../benchmarks/visual-replay-native-v1.json) identify their scope.

## Remaining acceptance gates

- All-display replay; it currently uses the existing masked snapshot path, with an explicit settings explanation.
- Natural desktop workloads, moving video, fast text changes, multilingual OCR and independent visual fidelity measurements.
- Physical sleep/lock/unlock recovery, permission revocation, long hardware capture and older Mac/macOS coverage.
- Measured battery/CPU/storage growth against matched competitor app workloads.
- Visual semantic embeddings, cross-clip continuous scrubbing and frame-level date filtering within a clip. Source filters currently use clip start time.

A retained probe diagnostic initially failed strict heading equality because the decoded heading read numeral “0” as letter “O”; ownership and the unique `visual-000` frame token remained intact. The identity gate now uses the authored unique token with exact digits and the known global frame index. No numeric substitutions or fuzzy token matches are accepted.

The broad parity and top-three product goals remain open. The separate 24-hour synthetic component soak is not a replay/device/power trial.
