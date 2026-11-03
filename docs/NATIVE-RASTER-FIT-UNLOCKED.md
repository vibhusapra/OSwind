# Fresh native capture on the current 2× display

Fresh actual attempts target only a generated two-color AppKit window. Baseline `87ddff0` and candidate `533b301` each save full, left and right captures in one attempt per case, with exact owned source identity. Full rasters are 1280×842; half rasters are 640×842. Both independently owned fixture children are reaped.

Both engines pass, and corresponding JPEG hashes are identical. The full capture retains both color fields and both authored OCR markers. Half captures retain the intended field/marker and omit the opposite marker. The original oracle inspects full width and the middle half of image height: strong opposite colors and central white padding are absent in the half captures. Five altered records reject.

An independent Pillow/ImageCms decoder reads the same retained six JPEGs, converts embedded color profiles to sRGB when present, and repeats that declared pixel oracle. It rejects swapped left/right images and a full image substituted for a crop. This is analysis of preserved captures, not a rerun of a successful live experiment. Candidate images were also visually inspected.

The older engine also passes, so the original padding/1× problem is **not reproduced on this display**. These observations do not prove a causal fix, all-pixel/arbitrary-surface privacy, automatic GUI scheduling, replay/audio correctness, power, 24-hour operation or whole-product performance. The earlier locked waiters and failed attempts remain unchanged.

[Fresh receipt](../benchmarks/native-raster-fit-unlocked-v1.json) · [Inputs](../benchmarks/native-raster-fit-unlocked-inputs-v1.json) · [Generated images, JSON and raw logs](../benchmarks/native-raster-fit-unlocked-raw-v1.zip) · [Original qualification and limitations](NATIVE-RASTER-FIT-WIP.md).
