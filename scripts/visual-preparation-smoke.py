#!/usr/bin/env python3
"""Offline packaged-setup contracts on an explicit qualified public-model cache.

Requires a NEW artifact root. Copies the app and APFS-clones only the supplied
qualified container. Never downloads a model or opens normal desktop history.
Raw outputs stay in that root; stdout contains only aggregate checks.
"""
import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=pathlib.Path)
    parser.add_argument('--cache-root', required=True, type=pathlib.Path)
    parser.add_argument('--root', required=True, type=pathlib.Path)
    args = parser.parse_args()
    app, supplied, root = args.app.resolve(), args.cache_root.resolve(), args.root.resolve()
    containers = list(supplied.glob('siglip2-qualified-*'))
    assert len(containers) == 1, 'Supply a cache containing exactly one qualified container'
    container = containers[0]
    assert (container/'qualification.json').is_file() and (container/'model/OSWIND-VISION.json').is_file()
    root.mkdir(mode=0o700, parents=False, exist_ok=False)
    clone = root/'Relocated.app'
    subprocess.run(['ditto', str(app), str(clone)], check=True)
    binary = clone/'Contents/MacOS/oswindctl'
    assert hashlib.sha256(binary.read_bytes()).digest() == hashlib.sha256((app/'Contents/MacOS/oswindctl').read_bytes()).digest()
    cache = root/'cache'
    cache.mkdir(mode=0o700)
    subprocess.run(['/bin/cp', '-cR', str(container), str(cache/container.name)], check=True)
    copied = cache/container.name
    never = root/'never-history'
    checks = []

    def invoke(label, arguments=(), expected=0, data=never):
        result = subprocess.run([str(binary), '--data', str(data), 'vision', 'prepare', '--cache-root', str(cache), *arguments], cwd=root,
                                capture_output=True, timeout=120)
        (root/(label+'.stdout')).write_bytes(result.stdout)
        (root/(label+'.stderr')).write_bytes(result.stderr)
        assert result.returncode == expected, (label, result.returncode, result.stderr)
        checks.append({'case': label, 'passed': True})
        return json.loads(result.stdout) if result.returncode == 0 else None

    # Model publication can finish just before an abrupt owner death. A ready
    # container must not bypass cleanup of that owner's leftover scratch.
    dead = subprocess.Popen(['/usr/bin/true'])
    dead.wait(timeout=5)
    try:
        os.kill(dead.pid, 0)
        raise AssertionError('Fixture owner PID was reused')
    except ProcessLookupError:
        pass
    job = str(uuid.uuid4())
    scratch, control = cache/('.oswind-visual-prepare-'+job), cache/('.oswind-job-'+job)
    scratch.mkdir(mode=0o700)
    control.mkdir(mode=0o700)
    (scratch/'unfinished-public-conversion').write_bytes(b'Owned abandoned fixture')
    stamp = scratch.stat()
    marker = dict(format='OSwind unpublished workspace', version=1, jobID=job, label='oswind-visual-prepare',
                  workspaceName=scratch.name, device=stamp.st_dev, inode=stamp.st_ino, pid=dead.pid, createdAt=time.time())
    (control/'marker.json').write_text(json.dumps(marker))
    (control/'lease').touch(mode=0o600)
    reused = invoke('relocated bundled assets and qualified reuse')
    assert not scratch.exists() and not control.exists(), 'Ready-model reuse left abandoned conversion scratch'
    checks.append({'case': 'ready-model reuse cleans abandoned owned conversion scratch', 'passed': True})
    assert reused['reused'] and pathlib.Path(reused['directory']) == copied/'model'
    assert not never.exists()
    invoke('unknown option refuses before history', ['--unknown'], expected=1)
    invoke('duplicate enable flag refuses', ['--use-model', '--use-model'], expected=1)
    receipt = copied/'qualification.json'
    original = receipt.read_bytes()
    for label, change in [
        ('wrong receipt identity refuses', lambda value: value.update(modelID='wrong')),
        ('failed qualification refuses', lambda value: value['qualification']['measurements'][0].update(minimumCosine=.98)),
        ('duplicate qualification policy refuses', lambda value: value['qualification']['measurements'].__setitem__(0, value['qualification']['measurements'][1]))
    ]:
        value = json.loads(original)
        change(value)
        altered = json.dumps(value).encode()
        receipt.write_bytes(altered)
        invoke(label, expected=1)
        assert receipt.read_bytes() == altered
    receipt.write_bytes(original)
    assert invoke('restored receipt revalidates')['modelID'] == reused['modelID']
    script = clone/'Contents/Resources/scripts/convert-visual-model.py'
    script_bytes = script.read_bytes()
    script.write_bytes(script_bytes+b'\n# Owned integrity-test mutation\n')
    invoke('changed bundled script refuses before cache reuse', expected=1)
    script.write_bytes(script_bytes)
    guardian = clone/'Contents/MacOS/oswind-preparation-guardian'
    held = guardian.with_suffix('.held')
    guardian.rename(held)
    invoke('missing bundled guardian refuses', expected=1)
    held.rename(guardian)
    assert not never.exists()
    library = root/'owned-library'
    subprocess.run([str(binary), '--data', str(library), 'note', 'Owned setup contract memory'], check=True, capture_output=True)
    settings = library/'settings.json'
    before = settings.read_bytes() if settings.exists() else None
    invoke('prepare without use-model preserves existing settings', data=library)
    assert (settings.read_bytes() if settings.exists() else None) == before
    invoke('explicit use-model selects qualified model', ['--use-model'], data=library)
    saved = json.loads(settings.read_text())
    assert saved['search']['visual']['enabled'] and saved['search']['visual']['modelDirectory'] == str(copied/'model')
    assert settings.stat().st_mode & 0o777 == 0o600
    nested = library/'never-cache'
    result = subprocess.run([str(binary), '--data', str(never), 'vision', 'prepare', '--cache-root', str(nested)], capture_output=True, timeout=30)
    assert result.returncode == 1 and not nested.exists() and not never.exists()
    checks.append({'case': 'cache inside history refuses before creation', 'passed': True})
    found = subprocess.run([str(binary), '--data', str(library), 'search', '--mode', 'keyword', 'contract'], capture_output=True, check=True, timeout=30)
    assert 'Owned setup contract memory' in found.stdout.decode()
    checks.append({'case': 'explicit selection preserves source history and private settings', 'passed': True})
    report = {'scope': 'Offline explicit qualified public-model container; copied packaged app; no model download, normal history, capture or UI input',
              'binarySHA256': hashlib.sha256(binary.read_bytes()).hexdigest(), 'modelID': reused['modelID'], 'checks': checks, 'passed': True}
    (root/'report.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
