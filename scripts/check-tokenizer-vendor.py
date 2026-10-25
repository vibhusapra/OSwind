#!/usr/bin/env python3
"""Verify the narrow Apache2 tokenizer copy and optional pinned source offline."""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import subprocess

root=Path(__file__).resolve().parents[1]
base=root/'Vendor/OSwindTokenizers'
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--upstream',type=Path)
args=parser.parse_args()
manifest=json.loads((base/'provenance.json').read_text())
assert manifest['revision']=='48473106a93b2d8dfb114b82f0628ebbb71734e7' and manifest['version']=='1.3.5'
assert manifest['repository']=='https://github.com/huggingface/swift-transformers' and manifest['license']=='Apache-2.0'
sha=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
assert sha(base/'LICENSE')==manifest['licenseSHA256']
assert (base/'LICENSE').read_bytes()==(root/'ThirdParty/VisualRuntime/swift-transformers/LICENSE').read_bytes()
assert len(manifest['files'])==12
assert {p.name for p in (base/'Sources').iterdir()}=={r['path'] for r in manifest['files']}
changed=[]
for row in manifest['files']:
    assert Path(row['path']).name==row['path'] and row['path'].endswith('.swift')
    assert sha(base/'Sources'/row['path'])==row['vendoredSHA256'],row['path']
    if row['vendoredSHA256']!=row['upstreamSHA256']:changed.append(row['path'])
assert set(changed)=={'BPETokenizer.swift','Normalizer.swift'}
if args.upstream:
    upstream=args.upstream.resolve(strict=True)
    assert subprocess.check_output(['git','-C',str(upstream),'rev-parse','HEAD'],text=True).strip()==manifest['revision']
    patch=''
    for row in manifest['files']:
        source=upstream/'Sources/Tokenizers'/row['path']
        assert sha(source)==row['upstreamSHA256'],row['path']
    for name in ['BPETokenizer.swift','Normalizer.swift']:
        old=(upstream/'Sources/Tokenizers'/name).read_text().splitlines(keepends=True)
        new=(base/'Sources'/name).read_text().splitlines(keepends=True)
        patch+=''.join(difflib.unified_diff(old,new,fromfile='upstream/'+name,tofile='Sources/'+name))
    assert patch==(base/'unicode-correctness.patch').read_text()
print(json.dumps(dict(files=12,modified=sorted(changed),licenseMatches=True,upstreamVerified=args.upstream is not None)))
