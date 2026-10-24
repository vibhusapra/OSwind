#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = ["torch==2.7.0", "transformers==4.57.1", "sentencepiece==0.2.1", "Pillow==11.3.0", "safetensors==0.6.2", "numpy==2.2.6"]
# ///
"""Evaluate the native encoder against original PyTorch on a deterministic
100-image COCO 2017 validation subset. --prepare explicitly downloads public
annotations/images to the private work directory. Nothing is added to OSwind.
No media, captions, predictions or absolute local paths enter summary.json.
"""
import argparse
import collections
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import random
import re
import platform
import subprocess
import signal
import time
import urllib.request
import zipfile

BASE = "https://s3.amazonaws.com/images.cocodataset.org/"
ANNOTATION_BYTES = 252907541
ANNOTATION_SHA = "113a836d90195ee1f884e704da6304dfaaecff1f023f49b6ca93c4aaae470268"


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def fetch(url, path, maximum):
    if path.exists():
        if path.is_symlink() or not path.is_file() or path.stat().st_size > maximum:
            raise ValueError("Invalid existing dataset file")
        return
    partial = path.with_name(path.name + ".partial")
    with partial.open("xb") as out, urllib.request.urlopen(url, timeout=120) as response:
        received = 0
        while chunk := response.read(1024 * 1024):
            received += len(chunk)
            if received > maximum:
                raise ValueError("Dataset download exceeds its bound")
            out.write(chunk)
    os.link(partial, path, follow_symlinks=False)
    partial.unlink()


def prepare(work):
    annotation = work / "annotations_trainval2017.zip"
    fetch(BASE + "annotations/annotations_trainval2017.zip", annotation, ANNOTATION_BYTES)
    if annotation.stat().st_size != ANNOTATION_BYTES or sha(annotation) != ANNOTATION_SHA:
        raise ValueError("COCO annotation hash does not match the public TensorFlow Datasets checksum")
    with zipfile.ZipFile(annotation) as archive:
        name = "annotations/captions_val2017.json"
        if archive.getinfo(name).file_size > 32 * 1024 * 1024:
            raise ValueError("COCO caption metadata exceeds its bound")
        data = json.loads(archive.read(name))
    selected = random.Random(1729).sample(sorted(data["images"], key=lambda x: x["id"]), 100)
    selected.sort(key=lambda x: x["id"])
    ids = {x["id"] for x in selected}
    captions = sorted((x for x in data["annotations"] if x["image_id"] in ids), key=lambda x: (x["image_id"], x["id"]))
    images = work / "images"
    images.mkdir(exist_ok=True, mode=0o700)

    def download(image):
        name = image["file_name"]
        if name != f"{image['id']:012d}.jpg":
            raise ValueError("Unexpected COCO image name")
        fetch(BASE + "val2017/" + name, images / name, 20 * 1024 * 1024)

    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        list(executor.map(download, selected))
    selection = dict(seed=1729, images=selected, captions=captions, licenses=data["licenses"],
                     hashes={x["file_name"]: sha(images / x["file_name"]) for x in selected})
    (work / "selection.json").write_text(json.dumps(selection, indent=2) + "\n")
    (work / "fixture.json").write_text(json.dumps(dict(queries=[x["caption"] for x in captions],
                                                       images=[str((images / x["file_name"]).resolve()) for x in selected]), indent=2) + "\n")


def evaluate(args):
    import numpy as np
    import torch
    from PIL import Image
    from transformers import AutoModel, AutoProcessor
    work = args.work.resolve()
    fingerprints = dict(cli=sha(args.cli), harness=sha(Path(__file__)), selection=sha(work / "selection.json"))
    pinned_source = json.loads((Path(__file__).resolve().parent.parent / "models/siglip2-source.json").read_text())
    for file in pinned_source["files"]:
        path = args.source / file["path"]
        if path.is_symlink() or path.stat().st_size != file["bytes"] or sha(path) != file["sha256"]:
            raise ValueError("Original model source does not match pinned provenance: " + file["path"])
    selection = json.loads((work / "selection.json").read_text())
    fixture = json.loads((work / "fixture.json").read_text())
    expected_images = [str((work / "images" / x["file_name"]).resolve()) for x in selection["images"]]
    if fixture != dict(queries=[x["caption"] for x in selection["captions"]], images=expected_images):
        raise ValueError("Fixture differs from the frozen selection")
    # Detect local dataset changes before either implementation observes them.
    for name, expected in selection["hashes"].items():
        if sha(work / "images" / name) != expected:
            raise ValueError("COCO image changed: " + name)
    native_file = work / ("native-" + args.compute + ".json")
    if native_file.exists():
        raise ValueError("Native report exists; preserve it and choose a new work directory")
    unopened_library = work / "unused-library"
    if unopened_library.exists():
        raise ValueError("Qualification requires a nonexistent designated library path")
    pixel_directory = work / ("native-pixels-" + args.compute)
    command = ["/usr/bin/time", "-lp", str(args.cli.resolve()), "--data", str(unopened_library), "vision", "probe", str(work / "fixture.json"), "--model-dir", str(args.model_dir.resolve()), "--compute", args.compute, "--pixel-output", str(pixel_directory)]
    before = time.monotonic()
    with native_file.open("x") as out, native_file.with_suffix(".stderr").open("x") as error:
        process = subprocess.Popen(command, stdout=out, stderr=error, start_new_session=True)
        try:
            code = process.wait(timeout=1800)
            if code:
                raise subprocess.CalledProcessError(code, command)
        except BaseException:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            raise
    wall = time.monotonic() - before
    if unopened_library.exists():
        raise ValueError("Visual probe unexpectedly created a library")
    native = json.loads(native_file.read_text())
    peak = re.search(r"(\d+)\s+maximum resident set size", native_file.with_suffix(".stderr").read_text())
    torch.set_num_threads(4)
    model = AutoModel.from_pretrained(args.source, local_files_only=True, use_safetensors=True,
                                     torch_dtype=torch.float32, attn_implementation="eager").eval()
    processor = AutoProcessor.from_pretrained(args.source, local_files_only=True, use_fast=False)
    image_vectors, matched_image_vectors, text_vectors, token_ids = [], [], [], []
    with torch.inference_mode():
        for index, path in enumerate(fixture["images"]):
            with Image.open(path) as image:
                pixels = processor(images=image.convert("RGB"), return_tensors="pt")["pixel_values"]
            image_vectors.append(model.vision_model(pixel_values=pixels, return_dict=False)[1].numpy()[0])
            native_pixels = np.fromfile(pixel_directory / f"input-{index}.f32", dtype="<f4")
            if native_pixels.size != 3 * 224 * 224 or not np.isfinite(native_pixels).all() or np.max(np.abs(native_pixels)) > 1:
                raise ValueError("Invalid exported native tensor")
            matched = torch.from_numpy(native_pixels.reshape(1, 3, 224, 224))
            matched_image_vectors.append(model.vision_model(pixel_values=matched, return_dict=False)[1].numpy()[0])
        for query in fixture["queries"]:
            ids = processor(text=query, padding="max_length", max_length=64, truncation=True, return_tensors="pt")["input_ids"]
            token_ids.append(ids.numpy()[0].tolist())
            text_vectors.append(model.text_model(input_ids=ids, return_dict=False)[1].numpy()[0])

    def normalized(values):
        values = np.asarray(values, dtype=np.float64)
        if not np.isfinite(values).all() or np.any(np.linalg.norm(values, axis=-1) == 0):
            raise ValueError("Nonfinite or zero embedding")
        return values / np.linalg.norm(values, axis=-1, keepdims=True)

    reference_i, reference_t = normalized(image_vectors), normalized(text_vectors)
    matched_i = normalized(matched_image_vectors)
    native_i = normalized([x["vector"] for x in native["images"]])
    native_t = normalized([x["vector"] for x in native["text"]])
    expected = {x["id"]: i for i, x in enumerate(selection["images"])}
    targets = np.array([expected[x["image_id"]] for x in selection["captions"]])

    def quality(images, text):
        scores = np.einsum("qd,id->qi", text, images, optimize=False)
        if not np.isfinite(scores).all():
            raise ValueError("Nonfinite similarity")
        ordered = np.argsort(-scores, axis=1, kind="stable")
        inverse = np.argsort(-scores.T, axis=1, kind="stable")
        return dict(textToImage={f"recallAt{k}": float(np.mean(np.any(ordered[:, :k] == targets[:, None], axis=1))) for k in [1, 5, 10]},
                    imageToText={f"recallAt{k}": float(np.mean([np.any(targets[inverse[i, :k]] == i) for i in range(len(images))])) for k in [1, 5, 10]})

    def timing(rows):
        seconds = [x["seconds"] for x in rows]
        return dict(firstMilliseconds=seconds[0] * 1000, warmMedianMilliseconds=float(np.median(seconds[1:])) * 1000,
                    warmP95Milliseconds=float(np.percentile(seconds[1:], 95)) * 1000)

    parity = dict(tokenIDsExact=token_ids == native["queryTokens"],
                  minimumImageCosine=float(np.sum(matched_i * native_i, axis=-1).min()),
                  minimumTextCosine=float(np.sum(reference_t * native_t, axis=-1).min()))
    passed = parity["tokenIDsExact"] and min(parity["minimumImageCosine"], parity["minimumTextCosine"]) >= 0.999
    for file in pinned_source["files"]:
        if sha(args.source / file["path"]) != file["sha256"]:
            raise ValueError("Original model source changed during evaluation")
    for name, expected_hash in selection["hashes"].items():
        if sha(work / "images" / name) != expected_hash:
            raise ValueError("Dataset image changed during evaluation")
    if fingerprints != dict(cli=sha(args.cli), harness=sha(Path(__file__)), selection=sha(work / "selection.json")):
        raise ValueError("Runner, harness or selection changed during evaluation")
    np.savez(work / ("reference-" + args.compute + ".npz"), originalImages=reference_i, nativePixelImages=matched_i, text=reference_t)
    summary = dict(schema=2, state="passed" if passed else "failed", images=len(reference_i), queries=len(reference_t), seed=1729,
                   scope="Encoder agreement gate >=0.999 on IDENTICAL preprocessed tensors. Platform JPEG/ICC preprocessing differences are reported separately; full pipeline equivalence is not claimed.",
                   dataset="COCO 2017 validation, deterministic 100-image subset; NOT the standard 5k benchmark",
                   source="https://cocodataset.org/#download", annotationSHA256=ANNOTATION_SHA,
                   selectionSHA256=sha(work / "selection.json"), sourceRevision=pinned_source["revision"],
                   harnessSHA256=fingerprints["harness"], sourceStabilityVerified=True,
                   modelID=native["modelID"], cliSHA256=sha(args.cli), requestedCompute=args.compute,
                   host=dict(cpu=subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(), macOS=platform.mac_ver()[0]),
                   peakProcessResidentBytes=int(peak.group(1)) if peak else None,
                   designatedLibraryCreated=False,
                   parity=parity, native=quality(native_i, native_t), pytorch=quality(reference_i, reference_t),
                   pytorchNativePixels=quality(matched_i, reference_t),
                   originalImagePipelineAgreement=dict(minimumCosine=float(np.sum(reference_i * native_i, axis=-1).min()),
                                                        meetsOriginal0999Gate=bool(np.sum(reference_i * native_i, axis=-1).min() >= 0.999)),
                   timings=dict(image=timing(native["images"]), text=timing(native["text"]),
                                preparationAndFirstTextSeconds=native["preparationAndFirstTextSeconds"], processWallSeconds=wall),
                   limits=["Public natural photos/captions, not desktop screenshots, unseen training holdout, or competitor execution.",
                           "No claim of actual GPU placement from a requested compute policy; no power or 24h capture measurement.",
                           "Native image timing includes decode/resize/inference; text includes tokenization/inference. First text preparation includes bundle verification/loading.",
                           "No threshold tuned against these labels. Existing model and OS caches may be warm; concurrent host activity is uncontrolled."],
                   licenseCounts=dict(collections.Counter(str(x["license"]) for x in selection["images"])))
    (work / ("summary-" + args.compute + ".json")).write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    if not passed:
        raise SystemExit("Native/reference parity failed; retain report")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--prepare", action="store_true")
    parser.add_argument("--cli", type=Path)
    parser.add_argument("--model-dir", type=Path)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--compute", choices=["cpuAndGPU", "cpuOnly"], default="cpuAndGPU")
    args = parser.parse_args()
    if args.prepare:
        args.work.mkdir(parents=True, exist_ok=True, mode=0o700)
        prepare(args.work)
    if args.cli:
        if not args.model_dir or not args.source:
            parser.error("Evaluation requires --cli, --model-dir and the pinned original --source")
        evaluate(args)
    elif not args.prepare:
        parser.error("Use --prepare or --cli")


if __name__ == "__main__":
    main()
