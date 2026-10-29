#!/usr/bin/env python3
"""Stage this authored experiment; downloads require --download-model.

No app installation, normal-history access, provider keys or inference. Existing
different files refuse replacement. Run the historical probes from repo root in
a fresh checkout: they retain their original fixed ignored paths.
"""
import argparse, hashlib, json, os, pathlib, tempfile, urllib.request

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[2]

def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()

def put(path, content):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.exists():
        if path.read_bytes() != content:
            raise ValueError('Existing preparation file differs: ' + path.name)
    else:
        with path.open('xb') as output:
            output.write(content)

def fetch(path, item, url, download):
    if path.exists():
        if path.stat().st_size != item['bytes'] or digest(path) != item['sha256']:
            raise ValueError('Existing model asset differs: ' + item['path'])
        return 'verified'
    if not download:
        return 'missing'
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.owned-download-', delete=False) as output:
            temporary = pathlib.Path(output.name)
            size = 0
            sha = hashlib.sha256()
            # No token or implicit Hub credentials; exact public revision only.
            with urllib.request.urlopen(url, timeout=60) as response:
                while chunk := response.read(1024 * 1024):
                    size += len(chunk)
                    if size > item['bytes']:
                        raise ValueError('Downloaded model asset exceeds pinned size')
                    sha.update(chunk)
                    output.write(chunk)
        if size != item['bytes'] or sha.hexdigest() != item['sha256']:
            raise ValueError('Downloaded model asset differs: ' + item['path'])
        # Exclusive final admission: never replace a concurrently created file.
        os.link(temporary, path)
        return 'downloaded'
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=pathlib.Path, default=ROOT/'.artifacts/pii-model-evaluation-v1')
    parser.add_argument('--download-model', action='store_true')
    parser.add_argument('--download-native-headers', action='store_true')
    args = parser.parse_args()
    plan = json.loads((HERE/'plan-v6.json').read_text())
    for name, expected in plan['codeSHA256'].items():
        if digest(ROOT/name) != expected:
            raise ValueError('Frozen harness differs: ' + name)
    manifest = json.loads((ROOT/'models/gliner-pii-edge-source.json').read_text())
    if manifest['modelRevision'] != plan['modelRevision'] or manifest['modelFiles'] != plan['modelFiles']:
        raise ValueError('Model manifest differs from frozen plan')
    # The public generator is the authority for corpus bytes, including metadata.
    import subprocess, sys
    with tempfile.TemporaryDirectory(prefix='oswind-owned-pii-') as temporary:
        corpus = pathlib.Path(temporary)/'authored.json'
        subprocess.run([sys.executable, str(ROOT/'scripts/prepare-pii-eval.py'), '--output', str(corpus)], check=True, stdout=subprocess.DEVNULL)
        if digest(corpus) != plan['corpusSHA256']:
            raise ValueError('Authored corpus differs')
        put(args.output/'authored-v1.json', corpus.read_bytes())
    # Aliases retain the historical probes' filenames; the new recipe is v6.
    for name in ('plan-v3.json', 'plan-v5.json', 'plan-v6.json'):
        put(args.output/name, (HERE/'plan-v6.json').read_bytes())
    for name in ('probe-compatibility-v3.py', 'probe-mps-v1.py'):
        put(args.output/name, (HERE/name).read_bytes())
    receipts = []
    for item in manifest['modelFiles']:
        relative = pathlib.Path(item['path'])
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('Model asset escapes output')
        url = f"https://huggingface.co/{manifest['modelRepository']}/resolve/{manifest['modelRevision']}/{item['path']}"
        receipts.append({'path': item['path'], 'state': fetch(args.output/'model'/relative, item, url, args.download_model)})
    headers = []
    for item in manifest['nativeRuntime']['headers']:
        relative = pathlib.Path(item['path'])
        if len(relative.parts) != 1:
            raise ValueError('Native header escapes output')
        headers.append({'path': item['path'], 'state': fetch(args.output/'native/include'/relative, item, item['url'], args.download_native_headers)})
    print(json.dumps({'modelFiles': receipts, 'nativeHeaders': headers, 'modelInference': False, 'applicationInstalled': False}))

if __name__ == '__main__':
    main()
