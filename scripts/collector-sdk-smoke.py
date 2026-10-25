#!/usr/bin/env python3
"""Actual CLI/Python SDK round trips using a NEW owned synthetic library.

Optional --native-vault creates its own encrypted APFS image, independently
checks detachment and preserves fixtures. No normal library or real credentials.
"""
import argparse
import dataclasses
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import secrets
import signal
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'sdk/python'))
from oswind import Client, OSwindError
from oswind.collector import Batch, Record, submit

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('binary', type=Path)
parser.add_argument('--root', type=Path, required=True)
parser.add_argument('--native-vault', action='store_true')
args = parser.parse_args()
binary, root = args.binary.resolve(), args.root.resolve()
root.mkdir(mode=0o700, exist_ok=False)
library = root / 'library'
library.mkdir(mode=0o700)
report = dict(format='OSwind collector SDK process checks v1', state='running',
              binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),
              scope='Authored sources through actual local CLI stdin and SDK MCP; no normal history, capture, provider credentials, power or competitor claim.', checks=[])


def save():
    (root / 'report.json').write_text(json.dumps(report, indent=2) + '\n')


def check(name):
    report['checks'].append(name)
    save()


def run(*arguments, data=library, payload=None, ok=True):
    result = subprocess.run([str(binary), '--data', str(data), *map(str, arguments)],
                            input=payload, capture_output=True, timeout=90)
    assert (result.returncode == 0) == ok, (result.returncode, result.stderr.decode(errors='replace'))
    return result


record = Record('issue-123', datetime(2026, 10, 25, 12, 23, 45, 123456, timezone.utc),
                'Owned tickets', 'dev.example.tickets', 'Owned launch',
                'CollectorAuroraEvidence Maya owns the Aurora launch.', 'https://example.com/issues/123')
batch = Batch('dev.example.tickets', [record])
save()
try:
    first = submit(binary, library, batch)
    assert first['imported'] == 1 and first['excluded'] == 0
    assert submit(binary, library, batch) == first
    with Client(binary, library) as client:
        assert {tool['name'] for tool in client.tools()} == Client.READ_TOOLS
        assert client.stats()['count'] == 1
        saved = client.get(batch.ids[0])
        assert saved['text'] == record.text and saved['timestamp'] == '2026-10-25T12:23:45.123456Z'
        assert client.search('CollectorAuroraEvidence')['hits'][0]['memory']['id'] == batch.ids[0]
        assert client.activity('2026-10', tag=batch.tag)['totalSources'] == 1
        try:
            client.call('collect', records=[])
            raise AssertionError('Read client allowed mutation')
        except ValueError:
            pass
        try:
            client.get('owned-missing-source')
            raise AssertionError('Missing source unexpectedly found')
        except OSwindError:
            pass
        assert client.stats()['count'] == 1
    check('six read-only tools, exact fractional source, search/calendar and recoverable missing source; retry does not duplicate')

    # Simulate an explicit user curation through the existing JSON importer.
    saved.update(favorite=True, tags=['reviewed'])
    fixture = root / 'owned-curation.json'
    fixture.write_text(json.dumps([saved]))
    assert json.loads(run('import', fixture, '--json').stdout)['imported'] == 1
    changed = Batch(batch.collector_id, [dataclasses.replace(record, text='CollectorCedarEvidence revised launch.')])
    assert submit(binary, library, changed)['imported'] == 1
    with Client(binary, library) as client:
        updated = client.get(batch.ids[0])
        assert updated['text'] == changed.records[0].text and updated['favorite']
        assert set(updated['tags']) == {'reviewed', 'collector', batch.tag}
        assert client.stats()['count'] == 1 and not client.search('CollectorAuroraEvidence')['hits']
    check('stable update replaces searchable evidence while preserving favorite and user tags')

    invalid = json.loads(batch.encode())
    invalid['records'].append(dict(invalid['records'][0], key='bad-last', imagePath='unsupported.png'))
    run('collect', '--stdin', payload=json.dumps(invalid).encode(), ok=False)
    with Client(binary, library) as client:
        assert client.stats()['count'] == 1 and client.get(batch.ids[0])['text'] == changed.records[0].text
    check('unsupported last record refuses the whole batch before replacing an earlier source')

    privacy = Batch('dev.example.privacy', [
        dataclasses.replace(record, key='secret', text='password=hello123', title='password=hello123', url='https://example.com/?password=hello123'),
        dataclasses.replace(record, key='app', bundle_id='com.apple.Passwords'),
        dataclasses.replace(record, key='domain', url='https://sub.chase.com/fixture'),
        dataclasses.replace(record, key='context', bundle_id='com.google.Chrome', url=None),
    ])
    result = submit(binary, library, privacy)
    assert (result['requested'], result['imported'], result['excluded']) == (4, 1, 3)
    with Client(binary, library) as client:
        redacted = client.get(privacy.ids[0])
        assert all('hello123' not in redacted[key] for key in ('text', 'title', 'url'))
        assert client.stats()['count'] == 2
    blocked = Batch(batch.collector_id, [dataclasses.replace(record, bundle_id='com.apple.Passwords')])
    assert submit(binary, library, blocked)['excluded'] == 1
    with Client(binary, library) as client:
        assert client.get(batch.ids[0])['text'] == changed.records[0].text
    check('default app/domain/browser-context exclusions and secret redaction; excluded updates preserve previously admitted history')

    # Partial input stays unadmitted. Deliver actual SIGINT to the owned process,
    # keeping the stdin writer open to exercise cancellation during an idle pipe.
    child = subprocess.Popen([str(binary), '--data', str(library), 'collect', '--stdin'],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        child.stdin.write(b'{"format":"OSwind collector batch",'); child.stdin.flush()
        time.sleep(1)
        child.send_signal(signal.SIGINT)
        assert child.wait(timeout=10) == 130
        assert not child.stdout.read()
        assert b'Stopping collector admission' in child.stderr.read()
    finally:
        if child.poll() is None:
            child.terminate(); child.wait(timeout=10)
        for stream in (child.stdin, child.stdout, child.stderr):
            stream.close()
    with Client(binary, library) as client:
        assert client.stats()['count'] == 2
    check('SIGINT while partial stdin remains open exits without admission and subsequent SDK read succeeds')

    if args.native_vault:
        package = root / 'Collector.oswindvault'
        secret = secrets.token_urlsafe(32).encode()

        def vault(*arguments, password=False):
            result = subprocess.run([str(binary), 'vault', *map(str, arguments)],
                                    input=secret+b'\0' if password else b'', capture_output=True, timeout=120)
            assert secret not in result.stdout and secret not in result.stderr
            assert result.returncode == 0, result.stderr.decode(errors='replace')
            return json.loads(result.stdout)

        def attached():
            inventory = plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil', 'info', '-plist']))
            return [image for image in inventory.get('images', [])
                    if image.get('image-path', '').startswith(str(root)+'/')]

        try:
            assert vault('create', package, '--name', 'Owned collector SDK', '--capacity-gb', '1', '--passphrase-stdin', password=True)['state'] == 'locked'
            vault('unlock', package, '--passphrase-stdin', password=True)
            alias = package / 'Library'
            assert submit(binary, alias, batch)['imported'] == 1
            with Client(binary, alias) as client:
                assert client.get(batch.ids[0])['text'] == record.text
            assert vault('lock', package)['state'] == 'locked' and not attached()
            try:
                submit(binary, alias, batch)
                raise AssertionError('Locked vault accepted data')
            except (ValueError, OSwindError):
                pass
            # Normal lock replaces the symlink with a closed regular-file
            # marker. It must never become a plaintext library directory.
            run('collect', '--stdin', data=alias, payload=batch.encode(), ok=False)
            assert alias.is_file() and not alias.is_symlink() and not alias.is_dir()
            vault('unlock', package, '--passphrase-stdin', password=True)
            with Client(binary, alias) as client:
                assert client.get(batch.ids[0])['text'] == record.text and client.stats()['count'] == 1
            assert vault('lock', package)['state'] == 'locked' and not attached()
            check('actual SDK encrypted admission, reader close, lock refusal without plaintext fallback and exact remount history')
        finally:
            if attached():
                vault('lock', package)
            report['nativeCleanupDetached'] = not bool(attached())
            save()
    report['state'] = 'completed'
except BaseException:
    report['state'] = 'failed'
    raise
finally:
    save()
print(json.dumps(report, indent=2))
