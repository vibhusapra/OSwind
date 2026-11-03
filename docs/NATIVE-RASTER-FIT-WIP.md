# Native capture raster fit

The preceding generated-window pilot produced a 1280×842 JPEG whose dark window ended at pixel959, leaving320 blank pixels on the right. This is a measured padding observation, not proof of a crop leak. ScreenCaptureKit defaults to scalesToFit=false. The earlier renderer also assumed2 pixels per point even on the observed1×source.

Source `533b301913002f68a0eac8072435033ca984e43d` uses the filter's actual pointPixelScale to cap snapshot, display-region and replay resolution. Independent-window snapshots and replay explicitly fill the requested integer raster, omit shadows/cursor and avoid letterboxing before normalized bitmap cropping. Replay retains even dimensions. Display crop coordinates remain in source points. Invalid scales, dimensions and sources without a complete output pixel refuse. [Apple scaling configuration](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/scalestofit) and [native point/pixel scale](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/pointpixelscale) describe the relevant controls.

The input-bound run qualifies694 committed runtime/test/dependency files: full Debug **2550pass /156conditional skips**, affected Thread Sanitizer and optimized **181pass /6skips each**, zero failures/race diagnostics. Six new methods cover1×/Retina/fractional/portrait output, native/profile caps, even replay, invalid inputs and unchanged display crop points. Six altered-log controls reject. All688 unchanged preceding inputs and472 earlier benchmark/feature/landscape publications remain unchanged.

- [Reviewed receipt](../benchmarks/native-raster-fit-v1.json)
- [Committed input hashes](../benchmarks/native-raster-fit-inputs-v1.json)
- [Raw source, logs and observation receipts](../benchmarks/native-raster-fit-raw-v1.zip)

The successful optimized test stage is retained. A following `swift build -c release --build-tests` failed because its module lacked testability for @testable imports. A separate normal production release build and fresh app package pass without repeating the successful tests. The release CLI and packaged CLI match in every byte before their code signatures after normalizing only the signature-size and LINKEDIT-size fields altered by signing. The fresh package passes strict ad-hoc signature verification. This does not qualify production signing or notarization. The initial review's signed/unsigned byte-equality assertion failure remains in the raw archive.

Actual full/left/right captures against an owned green/magenta window are pending the existing unlocked Mac session. The original controller refuses while locked; a separately scoped SDK diagnostic also refuses before producing images. Neither refusal is a native pixel pass. The one-shot old-runtime baseline and copied new-debug candidate wait in separate owned roots, preserve their results and never change permissions, unlock state or keep-awake settings.

The separate24-hour manual-target run continues from its original frozen old-runtime worker; it does not test this new raster implementation. Its lock deferrals remain in coverage counters. Actual new-runtime crop boundaries, automatic GUI cadence, display/hardware variants, sustained energy, complete sync and distribution remain open. All83feature statuses are unchanged; v0 and top-three ranking remain unqualified.
