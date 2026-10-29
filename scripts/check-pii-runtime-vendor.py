#!/usr/bin/env python3
"""Offline check of unmodified ONNX Runtime v1.24.2 headers and MIT license."""
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]/"Vendor/ONNXRuntime"
PINS={
    "vendor/onnxruntime_c_api.h":(373909,"09e5750c82f7b291cfad3e4a135d4ef78a4c54d7b3f86a5a178692279cf88334"),
    "vendor/onnxruntime_ep_c_api.h":(102495,"9f05feec0c200e418577425c7fbc56668d845bedfaf1b0447f95a7d6aad5180c"),
}

def check():
    provenance=json.loads((ROOT/"provenance.json").read_text())
    assert provenance["ref"]=="v1.24.2" and provenance["license"]=="MIT"
    assert provenance["repository"]=="https://github.com/microsoft/onnxruntime"
    assert len(provenance["headers"])==2
    for relative,(size,digest) in PINS.items():
        data=(ROOT/relative).read_bytes()
        assert len(data)==size and hashlib.sha256(data).hexdigest()==digest,relative
        row=next(v for v in provenance["headers"] if v["localPath"]==relative)
        assert row["bytes"]==size and row["sha256"]==digest
        assert row["url"]==f'https://raw.githubusercontent.com/microsoft/onnxruntime/v1.24.2/include/onnxruntime/core/session/{Path(relative).name}'
    digest=hashlib.sha256((ROOT/"LICENSE").read_bytes()).hexdigest()
    assert digest==provenance["licenseSHA256"]=="2f07c72751aed99790b8a4869cf2311df85a860b22ded05fa22803587a48922c"
    print("Pinned ONNX Runtime headers and MIT license verified offline")

if __name__=="__main__":check()
