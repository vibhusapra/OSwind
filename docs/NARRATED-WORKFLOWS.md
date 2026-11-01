# Source-linked narrated workflows

Build a walkthrough from retained screen images or exact stored replay frames. Edit the titles, narration and order before explicitly exporting. The v0 bounds are eight steps and 120 measured seconds, with 1280×720 H264/AAC video. Editing never starts narration or rendering. This is a partial F081 implementation; the [803-input qualification](../benchmarks/narrated-workflows-v1.json) passes all 21 local stages. Native interaction and fresh-machine setup remain open.

## In the app

1. In **Memories**, open a retained screen card’s menu and select **Add to workflow**. Text-only records and historical read-only evidence cannot substitute for retained pixels.
2. In **Workflows**, edit the walkthrough title and each step’s title and script. Select an exact stored replay frame where available. Move steps up/down or remove them. **Open source** opens the current complete source; **Refresh frame** deliberately reviews and binds the current retained frame while preserving your edited script.
3. Choose the installed local `kokoro-narrate` executable in narration setup if it differs from `~/.local/bin/kokoro-narrate`. An executable being found does not prove that its model is ready. The model must already be cached locally; export uses offline Hugging Face/Transformers settings and refuses missing preparation or invalid output.
4. Select **Export walkthrough…**, then choose a new folder outside the source library. This makes an independent, unencrypted copy. Existing destinations are refused. The app displays preparation, per-step narration, combination, encoding, verification, copying and publication stages; it does not estimate a false percentage.
5. Review the completed movie with the paused player or show the exported folder. No autoplay, upload or external publication occurs. Later changes or erasure in OSwind do not update independent exports.

Drafts live in memory. Privacy changes, sleep/session departure and library retirement clear their source previews; lock/switch/quit join active workers. Pause cancels active work, and a later deliberate source/export operation can run while capture remains paused. These operations never resume screen or microphone capture. Saved JSON manifests contain the draft, but v0 does not yet offer durable draft management or a native draft-import workflow.

Narration uses stock Kokoro `af_heart` at speed `1.0`, with no background music, voice cloning or cloud fallback. Scripts describe selected source material; a still image does not prove a sequence of clicks or user actions. The user writes the script and reviews its accuracy. This v0 has no automatic action reconstruction or generated-script accuracy claim.

## Portable folder

The new folder contains `workflow.mp4`, the exact `narration.txt` and original `narration.wav`, measured combined timing, per-step scripts/WAVs/timing, selected frame PNGs, WebVTT captions, a static `index.html`, `README.txt` and `workflow.json`.

The manifest records source/library/frame bindings, original pixel hashes and source revisions, the measured timeline, the verified movie receipt and hashes for the other payloads. It does not include the database, settings, provider secrets or source-library filesystem paths. Timing JSON uses relative WAV filenames; it also records the original measured timing hash before portable path rewriting. Caption timing is per step, not word-level forced alignment. A static local HTML file is included, but browser permission/track loading and arbitrary player seeking are not yet accepted across platforms.

The output includes source titles, selected pixels and the reviewed script. Treat it as an ordinary independent document with its own access and deletion lifecycle. It is not an encrypted backup, nor a promise that later library erasure can revoke a copied video.

## CLI

Use a selected existing library or an already-unlocked vault:

```sh
oswindctl --data /path/to/library workflow frame MEMORY_ID --frame 0 > frame.json
```

The JSON contains inspected source metadata, available frame ordinals and a `draft`. Save and edit that `draft` object as a separate JSON file; populate every step’s narration. Then:

```sh
oswindctl --data /path/to/library workflow export \
  --draft /path/to/draft.json --output /path/to/NEW-Walkthrough \
  --helper /absolute/path/to/kokoro-narrate
```

The helper option is optional when installed at the default path. Draft input must be a regular JSON file no larger than 128 KiB, with valid bounded Core fields. No server/MCP method or model agent automatically publishes workflows. The first Ctrl-C requests cancellation and joins actual work; a second Ctrl-C exits immediately. A completed atomic publication is reported even if cancellation arrives afterward. Process death can leave a private abandoned workspace, which the next workflow preparation recovers after its real owner/children release the lease.

## Admission and lifecycle

Each step binds its library directory identity, source ID/revision, original media SHA256, media kind and exact frame ordinal/time. Export reacquires and checks all bindings. Missing replay video cannot be replaced by a poster; missing frames cannot be invented. Image dimensions and preview bytes are bounded before allocation/encoding.

Current retention/exclusion/browser rules, known-secret detection, redacted-source refusal, fresh OCR and the selected optional local learned PII scanner apply. A selected scanner must finish; missing or differently configured scanning cannot silently fall back. OCR/text inspection is not a universal guarantee that pixels contain no sensitive information.

Private frame pins, script/WAV staging and intermediate encoding live on the active library volume, including an encrypted vault. Directory/media/settings leases remain owned through actual narration, decode, encode and copy work. Cancel revokes new admission immediately but keeps busy state and reservations until workers return. Source deletion, explicit retention cleanup, full erasure, library switch and quit join the workflow worker before proceeding. Automatic maintenance defers while it is busy.

Fresh checks immediately before atomic publication validate source revisions/pixels, the original library alias, current settings and the pinned destination-parent identity/ancestry. Output is a new folder outside the library. There is no asynchronous model work under the short final admission locks. Late cancellation cannot roll back a folder whose publication already completed.

## Media verification and retained failures

The helper’s measured receipt must match the exact saved script, model/voice/speed, 24 kHz mono PCM16 audio, complete contiguous chunks, sample count, file hashes and non-silence bounds. Combined narration copies every PCM sample without truncation or resampling. Hardware-required H264 video follows the measured step boundaries; one native MP4 writer combines compressed video with PCM-to-AAC encoding.

Verification decodes all authored audio frames, checks unshifted correlation with the source WAV, and independently parses bounded MP4 edit metadata to validate AAC priming/trailing coverage without assuming a universal fixed priming offset. Earlier native-only checks accepted a movie that independent FFmpeg decoding showed was shifted; that bad movie/source pair remains a mandatory regression fixture. A separate actual full export exposed a one-still backpressure timeout. Finishing each input promptly was insufficient until empty native edit/drain markers were consumed before timestamp ordering. Both red runs remain retained; an eight-second one-still regression and real local speech pass after the correction. Apple documents why exhausted writer inputs must be [marked finished to prevent other streams stalling](https://developer.apple.com/documentation/avfoundation/avassetwriterinput/markasfinished%28%29).

An owned complete Core export currently measures 7.775 seconds/186,600 source frames. Independent FFmpeg decoding returns all 186,600 frames at unshifted correlation 0.99716. Local Whisper recovers the words with the product name segmented as “O Swind”; the original strict word-equality failure and explicit brand correction remain documented. Its decoded first frame is readable and matches the factual blue-rectangle/white-background script. Post-input FFmpeg seeking initially produced no image for this one-still source; arbitrary seek behavior remains open.

The app’s 14 workflow model cases cover explicit editing/order/frame selection, eight-step bounds, missing helper/lock/retirement, held-worker cancellation, immutable export snapshots, privacy changes, pause, source opening/deletion, full erasure, root replacement, real AppSession switching and the real AppDelegate quit callback. An actual owned encrypted APFS case exports, normally locks, independently checks attachment absence, reopens sentinel history and normally locks again. The final signed release CLI passes 35 authored fixture checks, including local speech, SIGINT, SIGKILL, orphan recovery, stale-source/overwrite/inside-library refusal and portable payload hashes. Its retained media association is deliberately installed by an owned SQL fixture, not claimed as live ingestion.

The final [source/Git/package receipt](../benchmarks/narrated-workflows-v1.json) qualifies `415db23` over 803 inputs with 24 earlier app trees unchanged. All 21 stages pass: 1,883 full passes/93 opt-in skips, 60 sanitizer and 60 optimized passes/16 explicit skips each, all 58 workflow methods with local-model opt-ins and no skips, all 39 owned native vault cases with no skips, signed CLI/API/MCP/SDK/backup and interruption checks, six reviewed layouts, and strict 34-file archive/extraction equality. Every one of the 54 mandatory new software methods passes in all three builds. General/native/actual-speech runs cover 1,924 distinct methods; the receipt enumerates the remaining 52 opt-in methods.

The first final real-model group assigned one explicit output folder to both spoken and synthetic fixtures. The second correctly refused overwrite, so the group was retained as failed. A separate continuation rechecked the frozen source, prior stage hashes and protected apps, then ran all 58 workflow cases using exact class names and independent output destinations. The separately retained spoken component also passed. A continuation bootstrap guard initially double-counted `error:` within one XCTest line and refused before mutation; it was corrected to count error lines. These harness failures do not become product failures or disappear from the receipt.

F081 now moves from TODO to partial. Native clicks, permission UX, fresh-machine Kokoro installation/model download, durable drafts, long/multilingual/complex-script quality, arbitrary seeking, long-running power and whole-product/competitor ranking remain open. Hosted checks are separate from this local source-bound receipt; consult the pull request for their result.
