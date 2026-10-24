#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = ["coremltools==9.0", "torch==2.7.0", "transformers==4.57.1", "sentencepiece==0.2.1", "Pillow==11.3.0", "safetensors==0.6.2", "numpy==2.2.6"]
# ///
"""Offline-first SigLIP2 conversion. Explicit --download fetches pinned public
files without credentials. Never reads the OSwind library. Writes a NEW bundle.
Run with `uv run scripts/convert-visual-model.py --help` on Apple Silicon macOS.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import sys
import time
import urllib.request

RECIPE = "oswind-siglip2-fp32-image-fp16-text-v1"
ROOT = Path(__file__).resolve().parent.parent
SOURCE = json.loads((ROOT / "models/siglip2-source.json").read_text())


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def source_files(directory, download):
    if download:
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    for file in SOURCE["files"]:
        path = directory / file["path"]
        if not path.exists() and download:
            url = f"https://huggingface.co/{SOURCE['repository']}/resolve/{SOURCE['revision']}/{file['path']}"
            partial = path.with_name(path.name + ".partial")
            print("Downloading", file["path"], flush=True)
            # Refuse to truncate pre-existing partial files, links or destinations.
            with partial.open("xb") as out, urllib.request.urlopen(url, timeout=120) as response:
                received = 0
                while chunk := response.read(1024 * 1024):
                    received += len(chunk)
                    if received > file["bytes"]:
                        raise ValueError("Source exceeds pinned size: " + file["path"])
                    out.write(chunk)
            if partial.stat().st_size != file["bytes"] or digest(partial) != file["sha256"]:
                raise ValueError("Source download checksum mismatch: " + file["path"])
            os.link(partial, path, follow_symlinks=False)
            partial.unlink()
        if path.is_symlink() or not path.is_file() or path.stat().st_size != file["bytes"] or digest(path) != file["sha256"]:
            raise ValueError("Missing or changed source: " + str(path))


def convert(source, output):
    import coremltools as ct
    import numpy as np
    import torch
    from PIL import Image
    from transformers import AutoModel, AutoProcessor
    import transformers

    if (ct.__version__, torch.__version__.split("+")[0], transformers.__version__) != ("9.0", "2.7.0", "4.57.1"):
        raise ValueError("Use the pinned script environment; see PEP 723 header")
    output.mkdir(parents=False, exist_ok=False, mode=0o700)
    # Keep packages/proof in a sibling directory, never in the admitted bundle.
    work = output.with_name(output.name + ".conversion")
    work.mkdir(exist_ok=False, mode=0o700)
    torch.set_num_threads(4)
    torch.manual_seed(1729)
    torch.backends.mha.set_fastpath_enabled(False)
    model = AutoModel.from_pretrained(source, local_files_only=True, use_safetensors=True,
                                     attn_implementation="eager", torch_dtype=torch.float32).eval()
    processor = AutoProcessor.from_pretrained(source, local_files_only=True, use_fast=False)

    class ImageEncoder(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.encoder = model.vision_model

        def forward(self, pixel_values):
            return self.encoder(pixel_values=pixel_values, return_dict=False)[1]

    class TextEncoder(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.encoder = model.text_model

        def forward(self, input_ids):
            return self.encoder(input_ids=input_ids, return_dict=False)[1]

    # Seeded varied pixels, constants and high-frequency patterns exercise resize
    # and low-variance patches. Qualification, not a natural retrieval benchmark.
    rng = np.random.default_rng(1729)
    arrays = [rng.integers(0, 256, (h, w, 3), dtype=np.uint8) for h, w in
              [(224, 224), (113, 71), (337, 451), (96, 400), (255, 256)]]
    arrays += [np.full((240, 320, 3), c, np.uint8) for c in [0, 127, 255]]
    images = [Image.fromarray(a) for a in arrays]
    queries = ["a red car", "A RED CAR", "  a  red car  ", "a\tred\ncar", "café", "cafe\u0301",
               "猫が窓のそばに座っている", "👩🏽\u200d💻 wrote code", "<bos> hello <eos> <pad>",
               "x\x00y", "a\u00a0b", "one " * 100, "", "   ", "Code: FooBar HTTPServer.get(42)", "𓀀🦄\u0378"]
    ids = processor(text=queries, padding="max_length", max_length=64, truncation=True,
                    return_tensors="pt")["input_ids"].to(torch.int32)
    pixels = processor(images=images, return_tensors="pt")["pixel_values"]
    references = {}
    for name, wrapper, data, precision in [("image", ImageEncoder(), pixels, ct.precision.FLOAT32),
                                           ("text", TextEncoder(), ids, ct.precision.FLOAT16)]:
        before = time.monotonic()
        with torch.inference_mode():
            # Evaluate individually, matching static Core ML batch size.
            reference = np.concatenate([wrapper(row[None]).numpy() for row in data])
            traced = torch.jit.trace(wrapper.eval(), data[:1], strict=False)
        converted = ct.convert(traced, inputs=[ct.TensorType(
            name="pixel_values" if name == "image" else "input_ids", shape=data[:1].shape,
            dtype=np.float32 if name == "image" else np.int32)],
            outputs=[ct.TensorType(name="features", dtype=np.float32)],
            minimum_deployment_target=ct.target.macOS14, compute_precision=precision,
            convert_to="mlprogram", skip_model_load=True)
        converted.author = "Google; Core ML conversion by OSwind"
        converted.license = "Apache-2.0"
        converted.short_description = "SigLIP2 pooled " + name + " features; normalize before cosine retrieval"
        converted.user_defined_metadata.update({"source_repository": SOURCE["repository"],
                                                "source_revision": SOURCE["revision"], "recipe": RECIPE})
        package = work / (name + ".mlpackage")
        converted.save(str(package))
        compiled = Path(ct.models.utils.compile_model(str(package)))
        shutil.copytree(compiled, output / (name + ".mlmodelc"))
        shutil.rmtree(compiled)
        references[name] = reference
        print("Converted", name, "seconds", time.monotonic() - before, flush=True)

    measurements = []

    def unit(v):
        return v / np.linalg.norm(v, axis=-1, keepdims=True)

    for policy in [ct.ComputeUnit.CPU_ONLY, ct.ComputeUnit.CPU_AND_GPU]:
        for name, data in [("image", pixels.numpy()), ("text", ids.numpy())]:
            runtime = ct.models.CompiledMLModel(str(output / (name + ".mlmodelc")), compute_units=policy)
            predictions, durations = [], []
            for row in data:
                before = time.monotonic()
                predicted = runtime.predict({"pixel_values" if name == "image" else "input_ids": row[None]})["features"]
                durations.append(time.monotonic() - before)
                predictions.append(predicted[0])
            predicted = np.asarray(predictions)
            cosine = np.sum(unit(predicted) * unit(references[name]), axis=-1)
            passed = bool(np.isfinite(predicted).all() and cosine.min() >= 0.999)
            result = dict(encoder=name, requestedCompute=policy.name, minimumCosine=float(cosine.min()),
                          maximumNormalizedError=float(np.max(np.abs(unit(predicted) - unit(references[name])))),
                          predictionSeconds=durations, passed=passed)
            measurements.append(result)
            (work / "qualification.json").write_text(json.dumps(dict(recipe=RECIPE, measurements=measurements), indent=2) + "\n")
            if not passed:
                raise ValueError("Numerical qualification failed; no manifest published: " + str(result))
    for name in ["tokenizer.json", "tokenizer_config.json"]:
        shutil.copyfile(source / name, output / name)
    shutil.copyfile(ROOT / "ThirdParty/Apache-2.0.txt", output / "LICENSE.txt")
    # Store private reference images/tensors outside the distribution bundle.
    for i, image in enumerate(images):
        image.save(work / f"input-{i}.png")
    np.savez(work / "reference.npz", image=references["image"], text=references["text"], pixels=pixels.numpy(), ids=ids.numpy())
    (work / "fixture.json").write_text(json.dumps(dict(queries=queries, images=[str((work / f"input-{i}.png").resolve()) for i in range(len(images))]), ensure_ascii=False, indent=2) + "\n")
    files = [dict(path=str(p.relative_to(output)), bytes=p.stat().st_size, sha256=digest(p))
             for p in sorted(output.rglob("*")) if p.is_file()]
    manifest = dict(formatVersion=1, conversionRecipe=RECIPE,
                    sourceWeightsSHA256=next(f["sha256"] for f in SOURCE["files"] if f["path"] == "model.safetensors"),
                    model=dict(id="siglip2-base-patch16-224", publisher="Google",
                               repository=SOURCE["repository"], revision=SOURCE["revision"], license="Apache-2.0",
                               license_url=f"https://huggingface.co/{SOURCE['repository']}/blob/{SOURCE['revision']}/README.md",
                               attribution="Google SigLIP2, Apache-2.0. OSwind converts the pinned original weights locally with Core ML Tools. https://arxiv.org/abs/2502.14786", files=files))
    for p in output.rglob("*"):
        p.chmod(0o700 if p.is_dir() else 0o600)
    (output / "OSWIND-VISION.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print("Qualified bundle:", output, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True, help="Pinned Hugging Face source directory")
    parser.add_argument("--output", type=Path, required=True, help="NEW converted bundle directory")
    parser.add_argument("--download", action="store_true", help="Explicitly download missing public source files; no credentials")
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("Native conversion qualification requires Apple Silicon macOS")
    if args.output.exists() or args.output.with_name(args.output.name + ".conversion").exists():
        parser.error("Output or conversion workspace already exists; choose a new name")
    source_files(args.source, args.download)
    convert(args.source.resolve(), args.output.resolve())


if __name__ == "__main__":
    main()
